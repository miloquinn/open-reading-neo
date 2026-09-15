// Offline diagnostic, deliberately outside the regression test directory.
// Run: flutter test tool/source_compatibility_audit_probe.dart --reporter expanded
// A successful runner means observations were collected, NOT source parity.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  test(
    'collect offline runtime observations (not a parity assertion)',
    () async {
      final observations = <String, Object?>{};
      ReadingSourceConfig config([Map<String, Object?> extra = const {}]) =>
          ReadingSourceConfig.fromJson({
            'bookSourceName': 'Offline audit fixture',
            'bookSourceUrl': 'https://audit.test',
            'searchUrl': '/search',
            'ruleSearch': {
              'bookList': 'li',
              'name': 'a@text',
              'bookUrl': 'a@href',
            },
            'ruleToc': {
              'chapterList': 'a',
              'chapterName': 'text',
              'chapterUrl': 'href',
            },
            'ruleContent': {'content': 'body@text'},
            ...extra,
          });

      Future<void> observe(String name, Future<Object?> Function() run) async {
        try {
          observations[name] = await run();
        } catch (error) {
          observations[name] = {'error': '$error'};
        }
      }

      await observe('same_url_twice', () async {
        final evaluator = QuickJsSourceScriptEvaluator();
        try {
          var calls = 0;
          final result = await evaluator.evaluateAsync(
            "[java.ajax('/counter'), java.ajax('/counter')]",
            SourceScriptContext(
              source: config(),
              networkHandler: (request) async {
                calls++;
                return SourceScriptNetworkResult(
                  body: '$calls',
                  finalUrl: request.url,
                );
              },
            ),
          );
          return {'networkCalls': calls, 'result': result};
        } finally {
          evaluator.dispose();
        }
      });

      await observe('nonce_before_network', () async {
        final evaluator = QuickJsSourceScriptEvaluator();
        var calls = 0;
        try {
          try {
            final result = await evaluator.evaluateAsync(
              "java.ajax('/nonce?value=' + java.randomUUID())",
              SourceScriptContext(
                source: config(),
                networkHandler: (request) async {
                  calls++;
                  return SourceScriptNetworkResult(
                    body: 'ok',
                    finalUrl: request.url,
                  );
                },
              ),
            );
            return {'networkCalls': calls, 'result': result};
          } catch (error) {
            return {'networkCalls': calls, 'error': '$error'};
          }
        } finally {
          evaluator.dispose();
        }
      });

      await observe('cache_side_effect_before_network', () async {
        final evaluator = QuickJsSourceScriptEvaluator();
        try {
          return await evaluator.evaluateAsync(
            "cache.put('counter', Number(cache.get('counter') || 0) + 1); "
            "java.ajax('/once'); cache.get('counter')",
            SourceScriptContext(
              source: config(),
              networkHandler: (request) async =>
                  SourceScriptNetworkResult(body: 'ok', finalUrl: request.url),
            ),
          );
        } finally {
          evaluator.dispose();
        }
      });

      await observe('shared_library_state', () async {
        final evaluator = QuickJsSourceScriptEvaluator();
        try {
          final context = SourceScriptContext(
            source: config({
              'jsLib': 'var count = 0; function next(){ return ++count; }',
            }),
          );
          return [
            evaluator.evaluate('next()', context),
            evaluator.evaluate('next()', context),
          ];
        } finally {
          evaluator.dispose();
        }
      });

      await observe('login_api_shapes', () async {
        final evaluator = QuickJsSourceScriptEvaluator();
        try {
          return evaluator.evaluate(
            '[typeof source.login, typeof source.removeLoginInfo, '
            'typeof source.putVariable, typeof java.upLoginData, '
            'typeof java.reLoginView, typeof java.refreshBookToc, '
            'typeof isLongClick, java.refreshTocUrl()]',
            SourceScriptContext(source: config()),
          );
        } finally {
          evaluator.dispose();
        }
      });

      await observe('header_write_then_request', () async {
        final store = _MemoryStore();
        final transport = _RecordingTransport();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: store,
        );
        try {
          final source = config({
            'loginUrl': '''
          function login() {
            source.putLoginHeader(JSON.stringify({Authorization: 'fixture-token'}));
            java.ajax('/authenticated');
          }
        ''',
          }).toRegisteredSource(enabled: true);
          await runtime.login(source, const {});
          return {
            'requestHadAuthorization': transport.requests.single.headers
                .containsKey('Authorization'),
            'savedHeaderAfterScript': (await store.read(
              source.id,
            )).loginHeaders.containsKey('Authorization'),
          };
        } finally {
          runtime.close();
        }
      });

      await observe('button_action_preserves_existing_header', () async {
        final store = _MemoryStore();
        final source = config({
          'loginUrl': 'function settings() { true; }',
        }).toRegisteredSource(enabled: true);
        store.values[source.id] = const SourceLoginSession(
          loginHeaders: {'Authorization': 'fixture-old'},
        );
        final runtime = SourceRuntime(loginSessionStore: store);
        try {
          await runtime.login(source, const {}, action: 'settings()');
          return {
            'headerStillPresent': (await store.read(
              source.id,
            )).loginHeaders.containsKey('Authorization'),
          };
        } finally {
          runtime.close();
        }
      });

      await observe('missing_login_function', () async {
        final store = _MemoryStore();
        final runtime = SourceRuntime(loginSessionStore: store);
        try {
          await runtime.login(
            config({
              'loginUrl': 'var settings = 1;',
            }).toRegisteredSource(enabled: true),
            const {'user': 'fixture'},
          );
          return 'completed_without_error';
        } finally {
          runtime.close();
        }
      });

      await observe('source_value_survives_runtime_recreation', () async {
        final source = config();
        final first = QuickJsSourceScriptEvaluator();
        first.evaluate(
          "source.put('token', 'fixture')",
          SourceScriptContext(source: source),
        );
        first.dispose();
        final second = QuickJsSourceScriptEvaluator();
        try {
          return second.evaluate(
            "source.get('token')",
            SourceScriptContext(source: source),
          );
        } finally {
          second.dispose();
        }
      });

      await observe('unsupported_api_static_classification', () async {
        return const SourceCompatibilityScanner()
            .scan(
              config({
                'loginUrl': 'function login(){ java.reLoginView(); }',
                'ruleContent': {'content': '@js:java.queryTTF(result)'},
              }),
            )
            .level
            .name;
      });

      await observe('nested_request_with_scripted_header', () async {
        final transport = _RecordingTransport();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: _MemoryStore(),
        );
        try {
          final source = config({
            'header': '@js:JSON.stringify({"X-Fixture": "yes"})',
            'loginUrl': 'function login(){ java.ajax("/session"); }',
          }).toRegisteredSource(enabled: true);
          try {
            await runtime
                .login(source, const {})
                .timeout(const Duration(seconds: 2));
            return {
              'completed': true,
              'networkCalls': transport.requests.length,
            };
          } catch (error) {
            return {
              'error': '$error',
              'networkCalls': transport.requests.length,
            };
          }
        } finally {
          runtime.close();
        }
      });

      await observe('login_check_after_transport_failure', () async {
        final store = _MemoryStore();
        final source = config({
          'loginCheckJs': 'source.putLoginInfo({checked: "yes"}); result;',
        }).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(
          transport: _RecordingTransport(fail: true),
          loginSessionStore: store,
        );
        try {
          try {
            await runtime.search(source, 'fixture');
          } catch (_) {
            // Inspect whether error recovery had an opportunity to execute.
          }
          return {
            'checkRan':
                (await store.read(source.id)).loginInfo['checked'] == 'yes',
          };
        } finally {
          runtime.close();
        }
      });

      final output = const JsonEncoder.withIndent('  ').convert({
        'kind': 'offline_observations_not_compatibility_pass_rate',
        'platform': Platform.operatingSystem,
        'observations': observations,
      });
      // Only fixture values are used; no external requests or real credentials.
      // ignore: avoid_print -- This diagnostic's output is its JSON report.
      print(output);
      final outputPath = Platform.environment['SOURCE_AUDIT_OUTPUT'];
      if (outputPath != null) File(outputPath).writeAsStringSync('$output\n');
      expect(observations.length, 12);
    },
  );
}

class _RecordingTransport implements SourceTransport {
  _RecordingTransport({this.fail = false});
  final bool fail;
  final requests = <SourceRequestTemplate>[];
  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    if (fail) throw StateError('fixture transport failure');
    return SourceResponse(body: 'ok', finalUri: request.url);
  }
}

class _MemoryStore implements SourceLoginSessionStore {
  final values = <String, SourceLoginSession>{};
  @override
  Future<void> clear(String sourceId) async {
    values.remove(sourceId);
  }

  @override
  Future<SourceLoginSession> read(String sourceId) async =>
      values[sourceId] ?? const SourceLoginSession();
  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    values[sourceId] = session;
  }
}
