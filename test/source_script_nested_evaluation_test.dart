import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  test(
    'source catches optional HTTP failures without repeating the request',
    () async {
      final engine = QuickJsSourceScriptEvaluator();
      addTearDown(engine.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceUrl': 'https://books.test',
        'bookSourceName': 'Optional account',
      });
      var calls = 0;
      final context = SourceScriptContext(
        source: source,
        networkHandler: (_) async {
          calls++;
          throw const BookSourceProtocolException(
            'HTTP 400: optional account missing',
          );
        },
      );
      expect(
        await engine.evaluateAsync(
          'try { java.ajax("https://books.test/optional"); } catch(e) {} "catalog still available";',
          context,
        ),
        'catalog still available',
      );
      expect(calls, 1);
      await expectLater(
        engine.evaluateAsync(
          'java.ajax("https://books.test/required")',
          context,
        ),
        throwsA(predicate((e) => '$e'.contains('optional account missing'))),
      );
      await expectLater(
        engine.evaluateAsync(
          'try { java.ajax("https://books.test/optional"); } catch(e) {}',
          SourceScriptContext(
            source: source,
            networkHandler: (_) async =>
                throw const BookDownloadCancelledException(),
          ),
        ),
        throwsA(isA<BookDownloadCancelledException>()),
      );
    },
  );
  test('nested headers complete while unrelated sources stay queued', () async {
    final engine = QuickJsSourceScriptEvaluator();
    addTearDown(engine.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceUrl': 'https://books.test',
      'bookSourceName': 'Source with dynamic headers',
    });
    final other = ReadingSourceConfig.fromJson({
      'bookSourceUrl': 'https://other.test',
      'bookSourceName': 'Other source',
    });
    final entered = Completer<void>();
    final release = Completer<void>();
    var otherFinished = false;
    var calls = 0;
    final first = engine.evaluateAsync(
      'java.ajax("https://books.test/login")',
      SourceScriptContext(
        source: source,
        networkHandler: (request) async {
          calls++;
          entered.complete();
          await release.future;
          final headers = await engine.evaluateAsync(
            'JSON.stringify({"X-Test":"header"})',
            SourceScriptContext(source: source),
          );
          expect(headers, '{"X-Test":"header"}');
          expect(otherFinished, isFalse);
          return const SourceScriptNetworkResult(
            body: 'ok',
            finalUrl: 'https://books.test/login',
          );
        },
      ),
    );
    await entered.future;
    final second = engine
        .evaluateAsync('"other"', SourceScriptContext(source: other))
        .then((value) {
          otherFinished = true;
          return value;
        });
    release.complete();
    expect(await first.timeout(const Duration(seconds: 3)), 'ok');
    expect(await second.timeout(const Duration(seconds: 3)), 'other');
    expect(calls, 1);
  });

  test('nested failure releases the queue for later sources', () async {
    final engine = QuickJsSourceScriptEvaluator();
    addTearDown(engine.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceUrl': 'https://books.test',
      'bookSourceName': 'Failure recovery',
    });
    await expectLater(
      engine
          .evaluateAsync(
            'java.ajax("https://books.test/login")',
            SourceScriptContext(
              source: source,
              networkHandler: (_) async {
                await engine.evaluateAsync(
                  'throw new Error("header failed")',
                  SourceScriptContext(source: source),
                );
                throw StateError('unreachable');
              },
            ),
          )
          .timeout(const Duration(seconds: 3)),
      throwsA(predicate((error) => '$error'.contains('header failed'))),
    );
    expect(
      await engine
          .evaluateAsync('42', SourceScriptContext(source: source))
          .timeout(const Duration(seconds: 3)),
      42,
    );
  });
}
