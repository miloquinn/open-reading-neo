import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_text_normalizer.dart';

void main() {
  test('normalizes reading source-style description markup for display', () {
    const input =
        '【热血战争】&nbsp;第一段<br><br>正文……\\n下一段&lt;br&gt;末尾  <div>新段落</div>\n\n\n';

    final output = normalizeBookSourceDescription(input);

    expect(output, '【热血战争】 第一段\n\n正文……\n下一段\n末尾 新段落');
    expect(output, isNot(contains('<br')));
    expect(output, isNot(contains(r'\n')));
    expect(output, isNot(contains('&nbsp;')));
  });

  test(
    'preserves meaningful punctuation while removing invisible artifacts',
    () {
      expect(
        normalizeBookSourceDescription('  【标签】A\u200b　B &amp; C  '),
        '【标签】A　B & C',
      );
    },
  );

  test('decodes escaped Unicode markup and removes control characters', () {
    expect(
      normalizeBookSourceDescription(
        r'First\u003cbr\u003eSecond\u0026amp;Third\u0000',
      ),
      'First\nSecond&Third',
    );
  });
}
