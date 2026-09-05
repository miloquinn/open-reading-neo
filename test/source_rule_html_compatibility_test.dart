import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xxread/book_sources/source_engine/rules/source_rule_html.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_contract.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_engine.dart';

void main() {
  test(
    'joined attributes survive replacement, put rules and script stages',
    () async {
      final evaluator = _EchoEvaluator();
      final engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);
      final document = SourceRuleDocument.parse(
        '<div><img src="a.jpg"><img src="b.jpg"></div>',
        Uri.parse('https://books.test/chapter'),
        scriptContext: SourceScriptContext(
          source: ReadingSourceConfig.fromJson({
            'bookSourceName': 'fixture',
            'bookSourceUrl': 'https://books.test',
          }),
        ),
      );
      for (final rule in [
        'img@src##jpg##webp',
        'img@src@js:echo',
        '<js>html</js>img@src',
        'img@src@put:{"first":"img@src"}',
      ]) {
        final value = await engine.evaluateStringAsync(
          document,
          null,
          rule,
          joinSeparator: '\n',
        );
        expect(
          value,
          rule.contains('##') ? 'a.webp\nb.webp' : 'a.jpg\nb.jpg',
          reason: rule,
        );
      }
      expect(evaluator.inputs, ['a.jpg\nb.jpg', document.rawText]);
      expect(document.ruleState['first'], 'a.jpg');
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          'img@src',
          joinSeparator: '\n',
          resolveUrl: true,
        ),
        'https://books.test/a.jpg',
      );
    },
  );

  test('keeps @ inside quoted CSS attribute values when splitting a chain', () {
    final document = html_parser.parse(
      '<div class="item" data-url="https://a@b/img.jpg">ok</div>',
    );

    final result = evaluateSourceHtmlRule(
      [document.body!],
      'div.item[data-url="https://a@b/img.jpg"]@data-url',
      listMode: false,
    );

    expect(result, ['https://a@b/img.jpg']);
  });

  test('filters blank and duplicate attribute values in list mode', () {
    final document = html_parser.parse(
      '<div class="pages"><img src="a.jpg"><img src=""><img src="   "><img src="a.jpg"><img src="b.jpg"></div>',
    );

    final result = evaluateSourceHtmlRule(
      [document.body!],
      'div.pages@img@src',
      listMode: true,
    );

    expect(result, ['a.jpg', 'b.jpg']);
  });

  test('scalar attribute extraction keeps the first non-empty value', () {
    final document = html_parser.parse(
      '<div class="pages"><img src=""><img src="first.jpg"><img src="second.jpg"></div>',
    );

    final result = evaluateSourceHtmlRule(
      [document.body!],
      'div.pages@img@src',
      listMode: false,
    );

    expect(result, ['first.jpg']);
  });

  test(
    'async string join extracts all HTML attributes while sync stays scalar',
    () async {
      final document = SourceRuleDocument.parse(
        '<div class="pages"><img src="a.jpg"><img src="b.jpg"></div>',
        Uri.parse('https://example.test/'),
      );
      const engine = SourceRuleEngine();

      expect(
        engine.evaluateString(document, null, 'div.pages@img@src'),
        'a.jpg',
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          'div.pages@img@src',
          joinSeparator: '\n',
        ),
        'a.jpg\nb.jpg',
      );
    },
  );

  test('async join keeps non-terminal selectors as text', () async {
    final document = SourceRuleDocument.parse(
      '<div class="pages"><p>A</p><p>B</p></div>',
      Uri.parse('https://example.test/'),
    );
    const engine = SourceRuleEngine();

    expect(
      await engine.evaluateStringAsync(
        document,
        null,
        'div.pages@p',
        joinSeparator: '\n',
      ),
      'A\nB',
    );
  });

  test(
    'html removes nested script and style while keeping the outer element',
    () {
      final document = html_parser.parse(
        '<section><p>A</p><script>bad()</script><style>.x{}</style></section>',
      );
      final html =
          evaluateSourceHtmlRule(
                [document.body!],
                'section@html',
                listMode: false,
              ).single
              as String;

      expect(html, '<section><p>A</p></section>');
      expect(document.querySelector('script'), isNotNull);
      expect(document.querySelector('style'), isNotNull);
    },
  );

  test(
    'html cleans every selected node in sync and async paths, all keeps source',
    () async {
      final document = SourceRuleDocument.parse(
        '<main><article><b>A</b><script>x()</script></article><article><b>B</b><style>.x{}</style></article></main>',
        Uri.parse('https://example.test/'),
      );
      const engine = SourceRuleEngine();

      final sync = engine.evaluateString(document, null, 'main@article@html');
      final async = await engine.evaluateStringAsync(
        document,
        null,
        'main@article@html',
        joinSeparator: '\n',
      );
      final all = engine.evaluateString(document, null, 'main@article@all');

      expect(sync, '<article><b>A</b></article><article><b>B</b></article>');
      expect(async, '<article><b>A</b></article>\n<article><b>B</b></article>');
      expect(all, contains('<script>x()</script>'));
      expect(all, contains('<style>.x{}</style>'));
    },
  );

  test('html removes a selected script root without mutating its document', () {
    final document = html_parser.parse('<div><script>bad()</script></div>');
    final script = document.querySelector('script')!;
    final result = evaluateSourceHtmlRule([script], 'html', listMode: false);

    // Compatible element selection does not select the already-selected
    // script root itself.
    expect(result, ['<script>bad()</script>']);
    expect(document.querySelector('script')!.text, 'bad()');
  });
}

class _EchoEvaluator implements SourceScriptEvaluator {
  final inputs = <Object?>[];

  @override
  Object? evaluate(String script, SourceScriptContext context) {
    inputs.add(context.result);
    return context.result;
  }

  @override
  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  @override
  void dispose() {}
}
