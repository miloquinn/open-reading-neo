import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';

void main() {
  const engine = SourceRuleEngine();
  // ruleExplore.bookUrl from 4020🎃#bybk.cc (shuyuan.json).
  const bookUrlRule = r'a.0@href##(\d+)##http://www.xwurexs.com/read/$1/###';

  test(
    'standalone replacement keeps raw text unless OnlyOne is explicit',
    () async {
      final document = SourceRuleDocument.parse(
        'before 12 after 34',
        Uri.parse('https://books.test/'),
      );
      for (final entry in {
        r'##(\d+)##id=$1': 'before id=12 after id=34',
        r'##(\d+)##id=$1###': 'id=12',
      }.entries) {
        expect(engine.evaluateString(document, null, entry.key), entry.value);
        expect(
          await engine.evaluateStringAsync(document, null, entry.key),
          entry.value,
        );
      }
    },
  );

  for (final href in [
    '/txt/123456.html',
    '/read/123456/',
    '/txt/123456.html?page=2',
    'http://www.xwurexs.com/txt/123456.html',
  ]) {
    test('OnlyOne extracts the book URL from $href', () async {
      final document = SourceRuleDocument.parse(
        '<a href="$href">Book</a>',
        Uri.parse('http://www.4020xs.com/new/'),
      );

      expect(
        engine.evaluateString(document, null, bookUrlRule, resolveUrl: true),
        'http://www.xwurexs.com/read/123456/',
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          bookUrlRule,
          resolveUrl: true,
        ),
        'http://www.xwurexs.com/read/123456/',
      );
    });
  }

  test(
    'OnlyOne drops unmatched text and differs from global replacement',
    () async {
      final document = SourceRuleDocument.parse(
        '<p>before 12 between 34 after</p>',
        Uri.parse('https://books.test/'),
      );
      for (final entry in {
        r'p@text##(\d+)##id=$1###': 'id=12',
        r'p@text##(\d+)##id=$1': 'before id=12 between id=34 after',
        r'p@text##before###': '# 12 between 34 after',
        r'p@text##(missing)##$1###': '',
      }.entries) {
        expect(engine.evaluateString(document, null, entry.key), entry.value);
        expect(
          await engine.evaluateStringAsync(document, null, entry.key),
          entry.value,
        );
      }
    },
  );
}
