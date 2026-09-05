import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_content_images.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_text_replacement.dart';

void main() {
  const engine = SourceRuleEngine();
  final pages = <SourceContentImagePage>[
    (content: 'first 12', baseUri: Uri.parse('https://one.test/a/')),
    (content: 'second 34', baseUri: Uri.parse('https://two.test/b/')),
  ];

  test('matches engine replacement content with capture groups', () {
    const rule = r'(\d+)##[$1]';
    final replacement = replaceTextPages(pages, rule);

    expect(
      replacement.content,
      engine.applyReplaceRule('first 12\n\nsecond 34', rule),
    );
    expect(
      replacement.pages.map((page) => page.content).join(),
      replacement.content,
    );
  });

  test('matches engine replacement content for zero-width patterns', () {
    const rule = r'^##>';
    final replacement = replaceTextPages(pages, rule);

    expect(
      replacement.content,
      engine.applyReplaceRule('first 12\n\nsecond 34', rule),
    );
    expect(
      replacement.pages.map((page) => page.content).join(),
      replacement.content,
    );
  });
}
