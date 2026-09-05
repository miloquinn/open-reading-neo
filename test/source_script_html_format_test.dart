import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_html_formatter.dart';

void main() {
  test(
    'htmlFormat retains paragraphs and normalizes images without a base URL',
    () {
      expect(
        sourceScriptFormatKeepImg(
          '<p>第一段</p><div>第二段<img data-original="../a,b.jpg"></div>',
        ),
        '　　第一段\n　　第二段<img src="../a,b.jpg">',
      );
      expect(
        sourceScriptFormatKeepImg('<img data-lazyload="../comic.jpg">'),
        '<img src="../comic.jpg">',
      );
    },
  );
  test('htmlFormat preserves nested image options and text entities', () {
    const image =
        '''<img src="/1.jpg,{headers:{Referer:'https://reader.test/'}}">''';
    expect(sourceScriptFormatKeepImg(image), image);
    expect(
      sourceScriptFormatKeepImg(
        '<p>A&nbsp;&nbsp;B &amp; C</p><!-- comment -->',
      ),
      '　　A B &amp; C',
    );
  });
  test('native scripts keep images while Jsoup.text remains plain text', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final context = SourceScriptContext(
      source: ReadingSourceConfig.fromJson({
        'bookSourceName': 'HTML fixture',
        'bookSourceUrl': 'https://books.test',
      }),
      result: '<p>text</p><img data-src="/a.jpg">',
    );
    expect(
      evaluator.evaluate('java.htmlFormat(result)', context),
      '　　text\n　　<img src="/a.jpg">',
    );
    expect(
      evaluator.evaluate(
        'Packages.org.jsoup.Jsoup.parse(result).text()',
        context,
      ),
      'text',
    );
  });
}
