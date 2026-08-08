part of 'native_reader_page.dart';

extension _NativeReaderPersistentPaginationCache on _NativeReaderPageState {
  String get _paginationBookRevision =>
      sha1.convert(utf8.encode(_bookCacheKey)).toString();

  Future<void> _loadPersistedPaginationCache() async {
    final bookId = widget.book.id;
    if (bookId == null) return;
    try {
      final restored = await _paginationCacheDao.loadForBook(
        bookId,
        _paginationBookRevision,
      );
      _persistedPaginationPayloads
        ..clear()
        ..addAll(restored);
    } catch (error) {
      debugPrint('load pagination cache failed: $error');
      _persistedPaginationPayloads.clear();
    }
  }

  void _persistNativePagination({
    required String layoutFingerprint,
    required int chapterIndex,
    required List<_ReaderPageData> pages,
  }) {
    final bookId = widget.book.id;
    if (bookId == null || pages.isEmpty) return;
    try {
      final payload = _encodeNativePagination(pages);
      _persistedPaginationPayloads[layoutFingerprint] = payload;
      _paginationCacheWriteQueue = _paginationCacheWriteQueue
          .then(
            (_) => _paginationCacheDao.upsert(
              bookId: bookId,
              bookRevision: _paginationBookRevision,
              layoutFingerprint: layoutFingerprint,
              chapterIndex: chapterIndex,
              payload: payload,
            ),
          )
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('save pagination cache failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          });
    } catch (error, stackTrace) {
      debugPrint('encode pagination cache failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _clearPersistedPaginationCache() async {
    _persistedPaginationPayloads.clear();
    final bookId = widget.book.id;
    if (bookId == null) return;
    try {
      await _paginationCacheWriteQueue;
      await _paginationCacheDao.deleteForBook(bookId);
    } catch (error) {
      debugPrint('clear pagination cache failed: $error');
    }
  }
}

Uint8List _encodeNativePagination(List<_ReaderPageData> pages) {
  return ReaderPaginationCacheCodec.encode(
    pages
        .map((page) {
          final layout = page.layout;
          return ReaderPaginationCachePage(
            isChapterTitle: page.isChapterTitle,
            showsInlineChapterTitle: page.showsInlineChapterTitle,
            imageBlockIndex: page.imageBlockIndex,
            layoutSourceStart: layout?.sourceOffset ?? -1,
            layoutSourceEnd: layout == null
                ? -1
                : layout.sourceOffset + layout.sourceText.length,
            layoutStart: page.layoutStart,
            layoutEnd: page.layoutEnd,
            displayStart: page.displayStart,
            displayEnd: page.displayEnd,
            sourceStart: page.startOffset,
            sourceEnd: page.endOffset,
          );
        })
        .toList(growable: false),
  );
}

List<_ReaderPageData>? _restoreNativePagination({
  required Uint8List payload,
  required _NativeChapter chapter,
  required int firstLineIndent,
  required int paragraphSpacing,
  required bool normalizeParagraphBreaks,
}) {
  final cachedPages = ReaderPaginationCacheCodec.decode(payload);
  if (cachedPages == null || cachedPages.isEmpty) return null;
  final layouts = <(int, int), ReaderTextLayout>{};
  final pages = <_ReaderPageData>[];

  for (final cached in cachedPages) {
    if (cached.sourceStart < 0 ||
        cached.sourceEnd < cached.sourceStart ||
        cached.sourceEnd > chapter.plainText.length) {
      return null;
    }
    final imageBlockIndex = cached.imageBlockIndex;
    if (imageBlockIndex != null &&
        (imageBlockIndex < 0 || imageBlockIndex >= chapter.blocks.length)) {
      return null;
    }
    if (cached.isChapterTitle) {
      if (cached.sourceStart != cached.sourceEnd ||
          cached.layoutSourceStart != -1 ||
          cached.layoutSourceEnd != -1) {
        return null;
      }
      pages.add(const _ReaderPageData.chapterTitle());
      continue;
    }

    final hasLayout = cached.layoutSourceStart >= 0;
    if (!hasLayout) {
      if (cached.layoutSourceEnd != -1 ||
          cached.layoutStart != 0 ||
          cached.layoutEnd != 0 ||
          cached.displayStart != 0 ||
          cached.displayEnd != 0) {
        return null;
      }
      pages.add(
        _ReaderPageData(
          text: '',
          imageBlockIndex: imageBlockIndex,
          startOffset: cached.sourceStart,
          endOffset: cached.sourceEnd,
          showsInlineChapterTitle: cached.showsInlineChapterTitle,
        ),
      );
      continue;
    }
    if (cached.layoutSourceEnd < cached.layoutSourceStart ||
        cached.layoutSourceEnd > chapter.plainText.length) {
      return null;
    }
    final layoutKey = (cached.layoutSourceStart, cached.layoutSourceEnd);
    final layout = layouts.putIfAbsent(layoutKey, () {
      final sourceStart = cached.layoutSourceStart;
      final sourceEnd = cached.layoutSourceEnd;
      return ReaderTextLayout.build(
        chapter.plainText.substring(sourceStart, sourceEnd),
        sourceOffset: sourceStart,
        firstLineIndent: firstLineIndent,
        paragraphSpacing: paragraphSpacing,
        indentFirstParagraph:
            sourceStart == 0 ||
            isReaderLineBreakCodeUnit(
              chapter.plainText.codeUnitAt(sourceStart - 1),
            ),
        normalizeParagraphBreaks: normalizeParagraphBreaks,
      );
    });
    if (cached.layoutStart < 0 ||
        cached.layoutEnd < cached.layoutStart ||
        cached.layoutEnd > layout.text.length ||
        cached.displayStart < cached.layoutStart ||
        cached.displayEnd < cached.displayStart ||
        cached.displayEnd > cached.layoutEnd ||
        layout.sourceOffsetForDisplayOffset(cached.layoutStart) !=
            cached.sourceStart ||
        layout.sourceOffsetForDisplayOffset(cached.layoutEnd) !=
            cached.sourceEnd) {
      return null;
    }
    pages.add(
      _ReaderPageData(
        text: layout.text.substring(cached.layoutStart, cached.layoutEnd),
        imageBlockIndex: imageBlockIndex,
        startOffset: cached.sourceStart,
        endOffset: cached.sourceEnd,
        layout: layout,
        layoutStart: cached.layoutStart,
        layoutEnd: cached.layoutEnd,
        displayStart: cached.displayStart,
        displayEnd: cached.displayEnd,
        showsInlineChapterTitle: cached.showsInlineChapterTitle,
      ),
    );
  }

  if (pages.first.startOffset != 0 ||
      pages.last.endOffset != chapter.plainText.length) {
    return null;
  }
  for (var index = 1; index < pages.length; index++) {
    if (pages[index - 1].endOffset != pages[index].startOffset) return null;
  }
  return List<_ReaderPageData>.unmodifiable(pages);
}
