import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_aloud_text.dart';

void main() {
  test('silences wrappers and decorations without changing source offsets', () {
    const source = '“【甲】”说：**你好**。';
    final speech = ReaderAloudText(source);

    expect(speech.text, '甲  说：  你好  。');
    expect(speech.leadingOffset, 2);
    expect(
      speech.text.indexOf('你') + speech.leadingOffset,
      source.indexOf('你'),
    );
  });

  test('turns ellipses and dashes into pauses of the same UTF-16 length', () {
    const source = '等等……他说——真的...是这样～好吧。';
    final speech = ReaderAloudText(source);

    expect(speech.text, '等等, 他说, 真的,  是这样,好吧。');
    expect(speech.text.length, source.length);
  });

  test('preserves sentence punctuation and meaningful numeric symbols', () {
    const source = "Don't re-enter：-3.14 + 2 = -1.14，50%，1/2，10:30，1,000！";
    expect(ReaderAloudText(source).text, source);
    expect(ReaderAloudText('2*3=6').text, '2*3=6');
  });

  test('skips punctuation-only text and blank input', () {
    for (final source in ['', '  \n', '……——***', '”！？。', '【】★☆※']) {
      expect(ReaderAloudText(source).text, isEmpty, reason: source);
    }
  });

  test('distinguishes single quotation marks from apostrophes', () {
    expect(
      ReaderAloudText("‘John’s book,’ she said.").text,
      "John's book,  she said.",
    );
    expect(ReaderAloudText("'你好'，‘世界’。").text, '你好 ， 世界 。');
    expect(ReaderAloudText('他说‘你好’然后离开。').text, '他说 你好 然后离开。');
  });

  test('preserves multilingual text and surrogate offsets', () {
    const source = '「你好😀，café，العربية，世界！」';
    final speech = ReaderAloudText(source);

    expect(speech.text, '你好😀，café，العربية，世界！');
    expect(speech.leadingOffset, 1);
    expect(speech.text.indexOf('世界') + 1, source.indexOf('世界'));
  });
}
