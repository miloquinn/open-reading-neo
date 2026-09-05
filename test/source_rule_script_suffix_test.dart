import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_engine.dart';

void main() {
  test('script list extraction uses OnlyOne for each selected item', () async {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final context = SourceScriptContext(
      source: ReadingSourceConfig.fromJson(const {
        'bookSourceName': 'Script list regression',
        'bookSourceUrl': 'https://books.test',
      }),
      result: '<a href="/down/12.html">one</a><a href="/down/34.html">two</a>',
    );
    const script = r'''java.getStringList('a@href##([0-9]+)##/read/$1/###')''';
    expect(evaluator.evaluate(script, context), ['/read/12/', '/read/34/']);
    expect(await evaluator.evaluateAsync(script, context), [
      '/read/12/',
      '/read/34/',
    ]);
  });

  for (final entry in <String, String>{
    r'p@text@js:result##(\d+)##id=$1###': 'id=12',
    r'p@text@js:##(\d+)##id=$1###': 'id=12',
    r'p@text@js:result##(\d+)##id=$1': 'before id=12 between id=34 after',
    'p@text@js:result\n##(\\d+)##id=\$1###': 'id=12',
    r'p@text<js>result</js>##(\d+)##id=$1': 'before id=12 between id=34 after',
    r'''p@text@js:result.replace('before', '##')##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:result.replace(/##/, '')##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:result.replace(/[)#]+/, '')##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:if (true) /##/.test(result); result##(\d+)##id=$1###''':
        'id=12',
    r'''p@text@js:if (true) {} /##/.test(result); result##(\d+)##id=$1###''':
        'id=12',
    r'''p@text@js:var n=12; n++ / 2; result##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:var n={} / 2; result##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:(12 / 2) + ':' + result##(\d+)##id=$1###''': 'id=6',
    'p@text@js:/* ## ignored */ result // ## ignored\n##(\\d+)##id=\$1###':
        'id=12',
    r'''p@text@js:`## ${result}`##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:`${`## ${result}`}`##(\d+)##id=$1###''': 'id=12',
    r'''p@text@js:result + '##literal' ''':
        'before 12 between 34 after##literal',
    r'''p@text@js:result.replace(/##/, '')''': 'before 12 between 34 after',
  }.entries) {
    test('script suffix keeps JS and regex distinct: ${entry.key}', () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);
      final source = ReadingSourceConfig.fromJson(const {
        'bookSourceName': 'Script regression',
        'bookSourceUrl': 'https://books.test',
      });
      final document = SourceRuleDocument.parse(
        '<p>before 12 between 34 after</p>',
        source.baseUri,
        scriptContext: SourceScriptContext(source: source),
      );

      expect(engine.evaluateString(document, null, entry.key), entry.value);
      expect(
        await engine.evaluateStringAsync(document, null, entry.key),
        entry.value,
      );
    });
  }
}
