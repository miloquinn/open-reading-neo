import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';

void main() {
  test(
    'time and random request parameters remain stable across network replay',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final requests = <String>[];
      final context = SourceScriptContext(
        source: ReadingSourceConfig.fromJson({
          'bookSourceName': 'Replay fixture',
          'bookSourceUrl': 'https://books.test',
        }),
        networkHandler: (request) async {
          requests.add(request.url);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return SourceScriptNetworkResult(body: 'ok', finalUrl: request.url);
        },
      );
      const script = '''
var first = Date.now();
var stamp = new Date().getTime();
var nonce = java.randomUUID() + ':' + Math.random();
java.ajax('/first?time=' + first + '&date=' + stamp + '&nonce=' + nonce);
var later = Date.now();
java.ajax('/second?time=' + later + '&nonce=' + nonce);
[later >= first, new Date(0).getTime(), Date.parse('1970-01-01T00:00:00Z'),
 Date.UTC(1970, 0, 1), new Date() instanceof Date, typeof Date(), nonce];
''';
      final first = await evaluator.evaluateAsync(script, context) as List;
      expect(first.take(6), [true, 0, 0, 0, true, 'string']);
      expect(requests, hasLength(2));
      final second = await evaluator.evaluateAsync(script, context) as List;
      expect(requests, hasLength(4));
      expect(
        first.last,
        isNot(second.last),
        reason: 'A new operation gets a new nonce.',
      );
    },
  );
}
