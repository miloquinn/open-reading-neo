import 'package:flutter/foundation.dart';

import 'reader_text_layout.dart';
import 'reader_text_pagination.dart';

@immutable
class ReaderPaginationCachePage {
  const ReaderPaginationCachePage({
    required this.isChapterTitle,
    required this.showsInlineChapterTitle,
    required this.imageBlockIndex,
    required this.layoutSourceStart,
    required this.layoutSourceEnd,
    required this.layoutStart,
    required this.layoutEnd,
    required this.displayStart,
    required this.displayEnd,
    required this.sourceStart,
    required this.sourceEnd,
  });

  final bool isChapterTitle;
  final bool showsInlineChapterTitle;
  final int? imageBlockIndex;
  final int layoutSourceStart;
  final int layoutSourceEnd;
  final int layoutStart;
  final int layoutEnd;
  final int displayStart;
  final int displayEnd;
  final int sourceStart;
  final int sourceEnd;
}

abstract final class ReaderPaginationCacheCodec {
  static const int _magic = 0x4350524f; // "ORPC" in little-endian bytes.
  static const int _version = 1;
  static const int _headerBytes = 12;
  static const int _integersPerPage = 10;
  static const int _recordBytes = _integersPerPage * 4;
  static const int _maxPageCount = 100000;

  static Uint8List encodeTextPages(List<ReaderTextPage> pages) => encode([
    for (final page in pages)
      ReaderPaginationCachePage(
        isChapterTitle: page.isChapterTitle,
        showsInlineChapterTitle: false,
        imageBlockIndex: null,
        layoutSourceStart: page.layout?.sourceOffset ?? -1,
        layoutSourceEnd: page.layout == null
            ? -1
            : page.layout!.sourceOffset + page.layout!.sourceText.length,
        layoutStart: page.layoutStart,
        layoutEnd: page.layoutEnd,
        displayStart: page.displayStart,
        displayEnd: page.displayEnd,
        sourceStart: page.startOffset,
        sourceEnd: page.endOffset,
      ),
  ]);

  /// Reconstructs the cheap text mapping, without running line measurement.
  /// The caller must verify the text revision and the full layout fingerprint.
  static List<ReaderTextPage>? restoreTextPages(
    Uint8List payload, {
    required String text,
    required int firstLineIndent,
    required int paragraphSpacing,
  }) {
    final boundaries = decode(payload);
    if (boundaries == null || boundaries.isEmpty) return null;
    final layout = ReaderTextLayout.build(
      text,
      firstLineIndent: firstLineIndent,
      paragraphSpacing: paragraphSpacing,
      normalizeParagraphBreaks: true,
    );
    final pages = <ReaderTextPage>[];
    var sourceEnd = 0;
    var layoutEnd = 0;
    for (final page in boundaries) {
      if (page.imageBlockIndex != null ||
          page.showsInlineChapterTitle ||
          page.sourceStart != sourceEnd ||
          page.sourceEnd < sourceEnd ||
          page.sourceEnd > text.length) {
        return null;
      }
      if (page.isChapterTitle) {
        if (pages.isNotEmpty ||
            page.sourceEnd != 0 ||
            page.layoutSourceStart != -1 ||
            page.layoutSourceEnd != -1 ||
            page.layoutStart != 0 ||
            page.layoutEnd != 0 ||
            page.displayStart != 0 ||
            page.displayEnd != 0) {
          return null;
        }
        pages.add(const ReaderTextPage.chapterTitle());
        continue;
      }
      if (page.layoutSourceStart != 0 ||
          page.layoutSourceEnd != text.length ||
          page.layoutStart != layoutEnd ||
          page.layoutEnd < page.layoutStart ||
          page.layoutEnd > layout.text.length ||
          page.displayStart < page.layoutStart ||
          page.displayEnd < page.displayStart ||
          page.displayEnd > page.layoutEnd ||
          layout.sourceOffsetForDisplayOffset(page.layoutStart) !=
              page.sourceStart ||
          layout.sourceOffsetForDisplayOffset(page.layoutEnd) !=
              page.sourceEnd) {
        return null;
      }
      pages.add(
        ReaderTextPage(
          text: layout.text.substring(page.layoutStart, page.layoutEnd),
          startOffset: page.sourceStart,
          endOffset: page.sourceEnd,
          layout: layout,
          layoutStart: page.layoutStart,
          layoutEnd: page.layoutEnd,
          displayStart: page.displayStart,
          displayEnd: page.displayEnd,
        ),
      );
      sourceEnd = page.sourceEnd;
      layoutEnd = page.layoutEnd;
    }
    if (sourceEnd != text.length || layoutEnd != layout.text.length) {
      return null;
    }
    return List<ReaderTextPage>.unmodifiable(pages);
  }

  static Uint8List encode(List<ReaderPaginationCachePage> pages) {
    final data = ByteData(_headerBytes + pages.length * _recordBytes);
    data.setUint32(0, _magic, Endian.little);
    data.setUint32(4, _version, Endian.little);
    data.setUint32(8, pages.length, Endian.little);
    var offset = _headerBytes;
    for (final page in pages) {
      final flags =
          (page.isChapterTitle ? 1 : 0) |
          (page.showsInlineChapterTitle ? 2 : 0);
      final values = <int>[
        flags,
        page.imageBlockIndex ?? -1,
        page.layoutSourceStart,
        page.layoutSourceEnd,
        page.layoutStart,
        page.layoutEnd,
        page.displayStart,
        page.displayEnd,
        page.sourceStart,
        page.sourceEnd,
      ];
      for (final value in values) {
        data.setInt32(offset, value, Endian.little);
        offset += 4;
      }
    }
    return data.buffer.asUint8List();
  }

  static List<ReaderPaginationCachePage>? decode(Uint8List payload) {
    if (payload.lengthInBytes < _headerBytes) return null;
    final data = ByteData.sublistView(payload);
    if (data.getUint32(0, Endian.little) != _magic ||
        data.getUint32(4, Endian.little) != _version) {
      return null;
    }
    final pageCount = data.getUint32(8, Endian.little);
    if (pageCount == 0 || pageCount > _maxPageCount) return null;
    final expectedBytes = _headerBytes + pageCount * _recordBytes;
    if (payload.lengthInBytes != expectedBytes) return null;

    final pages = <ReaderPaginationCachePage>[];
    var offset = _headerBytes;
    for (var index = 0; index < pageCount; index++) {
      final values = List<int>.generate(_integersPerPage, (_) {
        final value = data.getInt32(offset, Endian.little);
        offset += 4;
        return value;
      }, growable: false);
      final flags = values[0];
      if ((flags & ~3) != 0 || values[1] < -1) return null;
      pages.add(
        ReaderPaginationCachePage(
          isChapterTitle: (flags & 1) != 0,
          showsInlineChapterTitle: (flags & 2) != 0,
          imageBlockIndex: values[1] < 0 ? null : values[1],
          layoutSourceStart: values[2],
          layoutSourceEnd: values[3],
          layoutStart: values[4],
          layoutEnd: values[5],
          displayStart: values[6],
          displayEnd: values[7],
          sourceStart: values[8],
          sourceEnd: values[9],
        ),
      );
    }
    return List<ReaderPaginationCachePage>.unmodifiable(pages);
  }
}
