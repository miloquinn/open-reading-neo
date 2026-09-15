import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
  test(
    'opaque data labels remain local payloads instead of disappearing',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);
      final source = ReadingSourceConfig.fromJson(const {
        'bookSourceName': 'Local payload contract',
        'bookSourceUrl': 'https://books.test',
      });
      final document = SourceRuleDocument.fromValue(
        {'name': 'Book'},
        source.baseUri,
        scriptContext: SourceScriptContext(source: source),
      );
      const target = 'data:bookPayload;base64,SGVsbG8=,{"type":"local"}';
      final rule = '@js:\'$target\'';
      expect(
        engine.evaluateString(document, null, rule, resolveUrl: true),
        target,
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          rule,
          resolveUrl: true,
        ),
        target,
      );
      expect(resolveSourceRequestUrl(source.baseUri, target), target);
      final chapter = {'url': target};
      expect(
        engine.evaluateString(document, chapter, 'url', resolveUrl: true),
        target,
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          chapter,
          'url',
          resolveUrl: true,
        ),
        target,
      );
      final request = SourceRequestTemplate.parse(
        target,
        baseUri: source.baseUri,
      );
      expect(request.syntheticBody, '48656c6c6f');
      expect(request.url.toString(), 'data:bookPayload;base64,SGVsbG8=');
      final transport = SourceHttpTransport();
      addTearDown(transport.close);
      final response = await transport.send(request);
      expect(response.body, '48656c6c6f');
      expect(response.finalUri, request.url);
    },
  );
  test(
    'fetched JSON is raw for root scripts and structured for selectors',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);
      final source = ReadingSourceConfig.fromJson(const {
        'bookSourceName': 'Raw JSON contract',
        'bookSourceUrl': 'https://books.test',
      });
      final document = SourceRuleDocument.parse(
        '{"data":[{"name":"Book"}]}',
        source.baseUri,
        scriptContext: SourceScriptContext(source: source),
      );
      const rule = r'<js>JSON.parse(result)</js>$.data[*]';
      for (final items in [
        engine.evaluateList(document, null, rule),
        await engine.evaluateListAsync(document, null, rule),
        engine.evaluateList(document, null, r'$.data[*]'),
      ]) {
        expect(items, [
          {'name': 'Book'},
        ]);
        expect(
          engine.evaluateString(document, items.single, '@js:result.name'),
          'Book',
        );
      }
      final transformed = SourceRuleDocument.fromValue(
        {'name': 'Transformed'},
        source.baseUri,
        scriptContext: SourceScriptContext(source: source),
      );
      expect(
        engine.evaluateString(transformed, null, '@js:result.name'),
        'Transformed',
      );
    },
  );
}
