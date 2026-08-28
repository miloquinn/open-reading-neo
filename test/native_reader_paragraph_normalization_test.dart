import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_text_layout.dart';
import 'package:xxread/services/books/book_format_support.dart';

void main() {
  test('all readable flowing-text formats normalize paragraph boundaries', () {
    for (final format in <String>[
      'txt',
      'epub',
      'mobi',
      'azw',
      'azw3',
      'html',
      'htm',
      'xhtml',
      'fb2',
      'rtf',
      'docx',
      'md',
      'markdown',
    ]) {
      expect(
        BookFormatRegistry.normalizesParagraphBreaks(format),
        isTrue,
        reason: format,
      );
    }
  });

  test('dedicated and unsupported formats preserve their source breaks', () {
    for (final format in <String>['pdf', 'cbz', 'cbr', 'doc', 'unknown']) {
      expect(
        BookFormatRegistry.normalizesParagraphBreaks(format),
        isFalse,
        reason: format,
      );
    }
  });

  test('Kindle parser block gaps follow paragraph spacing 0, 1, and 2', () {
    const source = '第一段\n\n第二段';
    for (final entry in const <int, String>{
      0: '第一段\n第二段',
      1: '第一段\n\n第二段',
      2: '第一段\n\n\n第二段',
    }.entries) {
      final layout = ReaderTextLayout.build(
        source,
        paragraphSpacing: entry.key,
        normalizeParagraphBreaks: BookFormatRegistry.normalizesParagraphBreaks(
          'azw3',
        ),
      );

      expect(layout.text, entry.value);
      expect(layout.sourceOffsetForDisplayOffset(0), 0);
      expect(
        layout.sourceOffsetForDisplayOffset(layout.text.length),
        source.length,
      );
    }
  });
}
