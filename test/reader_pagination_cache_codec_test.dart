import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/services/book_source_text_paginator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_pagination_cache_codec.dart';

void main() {
  testWidgets('online compact boundaries restore visible text and offsets', (
    tester,
  ) async {
    final text = List.filled(25, '第一段 abc def。\n\n第二段 内容。').join('\n');
    final pages = paginateBookSourceText(
      text,
      width: 180,
      firstPageHeight: 160,
      pageHeight: 160,
      style: const TextStyle(fontSize: 18),
      textDirection: TextDirection.ltr,
      firstLineIndent: 2,
      paragraphSpacing: 1,
    );
    final payload = ReaderPaginationCacheCodec.encodeTextPages(pages);
    final restored = ReaderPaginationCacheCodec.restoreTextPages(
      payload,
      text: text,
      firstLineIndent: 2,
      paragraphSpacing: 1,
    );
    expect(restored, isNotNull);
    expect(
      restored!
          .map(
            (p) => (
              p.text,
              p.startOffset,
              p.endOffset,
              p.displayStart,
              p.displayEnd,
              p.isChapterTitle,
            ),
          )
          .toList(),
      pages
          .map(
            (p) => (
              p.text,
              p.startOffset,
              p.endOffset,
              p.displayStart,
              p.displayEnd,
              p.isChapterTitle,
            ),
          )
          .toList(),
    );
    expect(
      ReaderPaginationCacheCodec.restoreTextPages(
        payload,
        text: 'short',
        firstLineIndent: 2,
        paragraphSpacing: 1,
      ),
      isNull,
    );
    expect(
      ReaderPaginationCacheCodec.restoreTextPages(
        Uint8List.fromList([1, 2]),
        text: text,
        firstLineIndent: 2,
        paragraphSpacing: 1,
      ),
      isNull,
    );
  });

  test('round-trips every native pagination boundary field', () {
    const pages = <ReaderPaginationCachePage>[
      ReaderPaginationCachePage(
        isChapterTitle: true,
        showsInlineChapterTitle: false,
        imageBlockIndex: null,
        layoutSourceStart: -1,
        layoutSourceEnd: -1,
        layoutStart: 0,
        layoutEnd: 0,
        displayStart: 0,
        displayEnd: 0,
        sourceStart: 0,
        sourceEnd: 0,
      ),
      ReaderPaginationCachePage(
        isChapterTitle: false,
        showsInlineChapterTitle: true,
        imageBlockIndex: 2,
        layoutSourceStart: 0,
        layoutSourceEnd: 240,
        layoutStart: 0,
        layoutEnd: 96,
        displayStart: 2,
        displayEnd: 95,
        sourceStart: 0,
        sourceEnd: 90,
      ),
      ReaderPaginationCachePage(
        isChapterTitle: false,
        showsInlineChapterTitle: false,
        imageBlockIndex: null,
        layoutSourceStart: 0,
        layoutSourceEnd: 240,
        layoutStart: 96,
        layoutEnd: 252,
        displayStart: 98,
        displayEnd: 252,
        sourceStart: 90,
        sourceEnd: 240,
      ),
    ];

    final restored = ReaderPaginationCacheCodec.decode(
      ReaderPaginationCacheCodec.encode(pages),
    );

    expect(restored, isNotNull);
    expect(restored, hasLength(pages.length));
    for (var index = 0; index < pages.length; index++) {
      final expected = pages[index];
      final actual = restored![index];
      expect(actual.isChapterTitle, expected.isChapterTitle);
      expect(actual.showsInlineChapterTitle, expected.showsInlineChapterTitle);
      expect(actual.imageBlockIndex, expected.imageBlockIndex);
      expect(actual.layoutSourceStart, expected.layoutSourceStart);
      expect(actual.layoutSourceEnd, expected.layoutSourceEnd);
      expect(actual.layoutStart, expected.layoutStart);
      expect(actual.layoutEnd, expected.layoutEnd);
      expect(actual.displayStart, expected.displayStart);
      expect(actual.displayEnd, expected.displayEnd);
      expect(actual.sourceStart, expected.sourceStart);
      expect(actual.sourceEnd, expected.sourceEnd);
    }
  });

  test('rejects truncated, unknown-version, and invalid-flag payloads', () {
    const page = ReaderPaginationCachePage(
      isChapterTitle: false,
      showsInlineChapterTitle: false,
      imageBlockIndex: null,
      layoutSourceStart: 0,
      layoutSourceEnd: 10,
      layoutStart: 0,
      layoutEnd: 10,
      displayStart: 0,
      displayEnd: 10,
      sourceStart: 0,
      sourceEnd: 10,
    );
    final valid = ReaderPaginationCacheCodec.encode(const [page]);

    expect(
      ReaderPaginationCacheCodec.decode(
        Uint8List.sublistView(valid, 0, valid.length - 1),
      ),
      isNull,
    );

    final unknownVersion = Uint8List.fromList(valid);
    ByteData.sublistView(unknownVersion).setUint32(4, 99, Endian.little);
    expect(ReaderPaginationCacheCodec.decode(unknownVersion), isNull);

    final invalidFlags = Uint8List.fromList(valid);
    ByteData.sublistView(invalidFlags).setInt32(12, 4, Endian.little);
    expect(ReaderPaginationCacheCodec.decode(invalidFlags), isNull);
  });
}
