import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_concurrency_limiter.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_interaction_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_dependencies.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_login.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_requests.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_rules.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_state.dart';
import 'package:xxread/book_sources/source_engine/source_script_contract.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';

void main() {
  test(
    'SourceRuntime composes an injected coordinator with custom capabilities',
    () async {
      final transport = _CapabilityTransport(
        responses: {
          'https://books.test/search?q=needle': SourceResponse(
            body: '''
            <div class="book">
              <a href="/book/1"><span class="name">Found</span></a>
            </div>
          ''',
            finalUri: Uri.parse('https://books.test/search?q=needle'),
          ),
        },
      );
      final coordinator = _Coordinator(
        result: const SourceScriptInteractionResult(
          value: '7391',
          finalUrl: 'https://books.test/captcha',
        ),
      );
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: _MemoryLoginSessionStore(),
        interactionCoordinator: coordinator,
      );
      addTearDown(runtime.close);
      final source = ReadingSourceConfig.fromJson(const {
        'bookSourceName': 'Books',
        'bookSourceUrl': 'https://books.test',
        'searchUrl':
            "@js:java.getVerificationCode('/captcha') === '7391' ? '/search?q=' + key : '/blocked'",
        'ruleSearch': {
          'bookList': 'class.book',
          'name': 'class.name@text',
          'bookUrl': 'tag.a@href',
        },
      }).toRegisteredSource(enabled: true);

      final page = await runtime.search(source, 'needle');

      expect(page.items.single.title, 'Found');
      expect(coordinator.requests.single.imageBytes, isNotEmpty);
      expect(transport.fetchedUris, [Uri.parse('https://books.test/captcha')]);
    },
  );

  test(
    'verification fails cleanly when a custom transport has no capability',
    () async {
      final transport = _PlainTransport();
      final coordinator = _Coordinator();
      final harness = _Harness(transport: transport, coordinator: coordinator);
      final result = await harness.interact(
        const SourceScriptInteractionRequest(
          signature: 'verify',
          kind: SourceScriptInteractionKind.verificationCode,
          url: '/captcha',
        ),
      );

      expect(result.error, contains('network transport'));
      expect(coordinator.requests, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'interaction capability validates URIs, fetches images, and syncs cookies',
    () async {
      final transport = _CapabilityTransport();
      final coordinator = _Coordinator(
        result: const SourceScriptInteractionResult(
          value: '7391',
          finalUrl: 'https://books.test/verified',
          cookieHeader: 'verified=yes',
        ),
      );
      final harness = _Harness(transport: transport, coordinator: coordinator);
      await harness.sessions.ensure(harness.source);
      harness.sessions.updateHeaders(harness.source, const {
        'Authorization': 'Bearer token',
      });
      harness.sessions.setCookies(
        harness.source,
        harness.source.baseUri,
        'session=abc',
      );

      final result = await harness.interact(
        const SourceScriptInteractionRequest(
          signature: 'verify',
          kind: SourceScriptInteractionKind.verificationCode,
          url: '/captcha',
        ),
      );

      expect(result.value, '7391');
      expect(transport.validatedUris, [
        Uri.parse('https://books.test/captcha'),
        Uri.parse('https://books.test/verified'),
      ]);
      expect(transport.fetchedUris, [Uri.parse('https://books.test/captcha')]);
      expect(coordinator.requests.single.headers, {
        'Authorization': 'Bearer token',
        'Cookie': 'session=abc',
      });
      expect(
        coordinator.requests.single.imageBytes,
        Uint8List.fromList([7, 3, 9, 1]),
      );
      expect(
        transport.scriptCookieHeader(
          harness.source.stableId,
          Uri.parse('https://books.test/verified'),
        ),
        'verified=yes',
      );
      expect(
        harness.sessions.current(harness.source).loginHeaders['Cookie'],
        'verified=yes',
      );
    },
  );

  test(
    'browser-await refetch uses the generic transport after coordination',
    () async {
      final transport = _PlainTransport(
        responses: {
          'https://books.test/after': SourceResponse(
            body: 'refetched body',
            finalUri: _afterUri,
            statusCode: 200,
          ),
        },
      );
      final coordinator = _Coordinator(
        result: const SourceScriptInteractionResult(
          finalUrl: 'https://books.test/after',
          cookieHeader: 'verified=yes',
        ),
      );
      final harness = _Harness(transport: transport, coordinator: coordinator);

      final result = await harness.interact(
        const SourceScriptInteractionRequest(
          signature: 'browser',
          kind: SourceScriptInteractionKind.browserAwait,
          url: '/gate',
          refetchAfterSuccess: true,
        ),
      );

      expect(result.body, 'refetched body');
      expect(result.finalUrl, 'https://books.test/after');
      expect(transport.requests.single.url, _afterUri);
      expect(transport.requests.single.headers['Cookie'], 'verified=yes');
    },
  );
}

final _afterUri = Uri.parse('https://books.test/after');

class _Harness {
  _Harness({
    required SourceTransport transport,
    required SourceInteractionCoordinatorPort coordinator,
  }) : source = ReadingSourceConfig.fromJson(const {
         'bookSourceName': 'Books',
         'bookSourceUrl': 'https://books.test',
         'enabledCookieJar': true,
       }),
       sessions = SourceRuntimeSessionManager(
         _MemoryLoginSessionStore(),
         switch (transport) {
           final SourceCookieTransport value => value,
           _ => null,
         },
       ) {
    requests = SourceRuntimeRequests(
      transport: transport,
      limiter: SourceConcurrencyLimiter(),
      sessions: sessions,
      rules: SourceRuntimeRules(const SourceRuleEngine()),
      state: SourceRuntimeState(),
      trace: SourceRuntimeTrace(),
      scripts: () => _UnusedScriptEvaluator(),
      interactionCoordinator: coordinator,
      interactionTransport: switch (transport) {
        final SourceInteractionTransport value => value,
        _ => null,
      },
    );
  }

  final ReadingSourceConfig source;
  final SourceRuntimeSessionManager sessions;
  late final SourceRuntimeRequests requests;

  Future<SourceScriptInteractionResult> interact(
    SourceScriptInteractionRequest interaction,
  ) async {
    final handler = requests.scriptContext(source).interactionHandler;
    return handler!(interaction);
  }
}

class _Coordinator implements SourceInteractionCoordinatorPort {
  _Coordinator({this.result = const SourceScriptInteractionResult()});

  final SourceScriptInteractionResult result;
  final List<SourceScriptInteractionRequest> requests = [];

  @override
  Future<SourceScriptInteractionResult> request({
    required String sourceId,
    required String sourceName,
    required SourceScriptInteractionRequest interaction,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    requests.add(interaction);
    return result;
  }
}

class _PlainTransport implements SourceTransport {
  _PlainTransport({this.responses = const {}});

  final Map<String, SourceResponse> responses;
  final List<SourceRequestTemplate> requests = [];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    return responses[request.url.toString()] ??
        SourceResponse(body: '', finalUri: request.url);
  }
}

class _CapabilityTransport extends _PlainTransport
    implements SourceInteractionTransport, SourceCookieTransport {
  _CapabilityTransport({super.responses});

  final List<Uri> validatedUris = [];
  final List<Uri> fetchedUris = [];
  final Map<String, String> _cookies = {};

  @override
  Future<void> validateInteractionUri(Uri uri) async {
    validatedUris.add(uri);
  }

  @override
  Future<Uint8List> fetchInteractionBytes({
    required Uri uri,
    required Map<String, String> headers,
    String? cookieJarKey,
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    fetchedUris.add(uri);
    return Uint8List.fromList([7, 3, 9, 1]);
  }

  @override
  String scriptCookieHeader(String jarKey, Uri uri) => _cookies[jarKey] ?? '';

  @override
  void setScriptCookies(String jarKey, Uri uri, String cookieHeader) {
    _cookies[jarKey] = cookieHeader;
  }

  @override
  void removeScriptCookies(String jarKey, Uri uri) {
    _cookies.remove(jarKey);
  }
}

class _MemoryLoginSessionStore implements SourceLoginSessionStore {
  SourceLoginSession session = const SourceLoginSession();

  @override
  Future<void> clear(String sourceId) async {
    session = const SourceLoginSession();
  }

  @override
  Future<SourceLoginSession> read(String sourceId) async => session;

  @override
  Future<void> write(String sourceId, SourceLoginSession value) async {
    session = value;
  }
}

class _UnusedScriptEvaluator implements SourceScriptEvaluator {
  @override
  Object? evaluate(String script, SourceScriptContext context) =>
      throw UnimplementedError();

  @override
  Future<Object?> evaluateAsync(String script, SourceScriptContext context) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}
