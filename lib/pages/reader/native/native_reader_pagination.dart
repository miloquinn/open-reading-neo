part of 'native_reader_page.dart';

List<_ReaderPageData> _paginateChapter(
  _NativeChapter chapter, {
  required double maxWidth,
  required double maxHeight,
  required NativeTextFlowStyle flowStyle,
  required TextStyle style,
  required int firstLineIndent,
  required int paragraphSpacing,
  required bool normalizeParagraphBreaks,
  required bool showDedicatedChapterTitlePage,
}) {
  final imageOffsets = <(int, int)>[];
  var searchFrom = 0;
  for (var i = 0; i < chapter.blocks.length; i++) {
    final block = chapter.blocks[i];
    if (block.hasImage) {
      final offset = block.startOffset >= 0 ? block.startOffset : searchFrom;
      imageOffsets.add((offset.clamp(searchFrom, chapter.plainText.length), i));
      continue;
    }
    final text = block.text;
    if (text == null || text.isEmpty) continue;
    if (block.startOffset >= searchFrom &&
        block.endOffset >= block.startOffset) {
      searchFrom = block.endOffset.clamp(searchFrom, chapter.plainText.length);
      continue;
    }
    final found = chapter.plainText.indexOf(text, searchFrom);
    if (found >= 0) searchFrom = found + text.length;
  }

  final hasChapterTitle =
      chapter.isNeedSplitTitle && chapter.title.trim().isNotEmpty;
  final showInlineChapterTitle =
      hasChapterTitle && !showDedicatedChapterTitlePage;
  final inlineTitleExtent = showInlineChapterTitle
      ? ReaderInlineChapterTitle.extentFor(
          title: chapter.title,
          maxWidth: maxWidth,
          bodyStyle: style,
          textDirection: flowStyle.textDirection,
          textScaler: flowStyle.textScaler,
          locale: flowStyle.locale,
        )
      : 0.0;
  var inlineTitlePending = showInlineChapterTitle;
  final pages = <_ReaderPageData>[
    if (hasChapterTitle && showDedicatedChapterTitlePage)
      const _ReaderPageData.chapterTitle(),
  ];
  var cursor = 0;
  List<_ReaderPageData> paginateRange(
    String text, {
    required int sourceOffset,
    required double pageHeight,
    double? firstPageHeight,
  }) {
    if (text.isEmpty) return const <_ReaderPageData>[];
    final effectiveFirstPageHeight = inlineTitlePending
        ? ((firstPageHeight ?? pageHeight) - inlineTitleExtent).clamp(
            0.0,
            double.infinity,
          )
        : firstPageHeight;
    final textPages = paginateReaderText(
      text: text,
      maxWidth: maxWidth,
      maxHeight: pageHeight,
      firstPageHeight: effectiveFirstPageHeight,
      flowStyle: flowStyle,
      style: style,
      sourceOffset: sourceOffset,
      firstLineIndent: firstLineIndent,
      paragraphSpacing: paragraphSpacing,
      normalizeParagraphBreaks: normalizeParagraphBreaks,
      indentFirstParagraph:
          sourceOffset == 0 ||
          isReaderLineBreakCodeUnit(
            chapter.plainText.codeUnitAt(sourceOffset - 1),
          ),
      sourceSpanBuilder: (sourceStart, sourceEnd) =>
          _styledSpanForRange(chapter, sourceStart, sourceEnd, style),
    );
    final result = textPages
        .map(_ReaderPageData.fromTextPage)
        .toList(growable: false);
    if (inlineTitlePending && result.isNotEmpty) {
      result[0] = result[0].copyWith(showsInlineChapterTitle: true);
      inlineTitlePending = false;
    }
    return result;
  }

  for (var imageIndex = 0; imageIndex < imageOffsets.length; imageIndex++) {
    final image = imageOffsets[imageIndex];
    final offset = image.$1.clamp(cursor, chapter.plainText.length);
    final before = chapter.plainText.substring(cursor, offset);
    pages.addAll(
      paginateRange(before, sourceOffset: cursor, pageHeight: maxHeight),
    );

    final nextImageOffset = imageIndex + 1 < imageOffsets.length
        ? imageOffsets[imageIndex + 1].$1
        : chapter.plainText.length;
    final available = chapter.plainText.substring(offset, nextImageOffset);
    final hasImage = chapter.blocks[image.$2].hasImage;
    final inlineTextHeight = hasImage
        ? ((maxHeight - _imagePageGap).clamp(0, double.infinity) *
              _imagePageTextFlex /
              (_imagePageImageFlex + _imagePageTextFlex))
        : maxHeight;
    final inlineChunks = paginateRange(
      available,
      sourceOffset: offset,
      pageHeight: maxHeight,
      firstPageHeight: inlineTextHeight,
    );
    assert(inlineChunks.isEmpty || inlineChunks.first.startOffset == offset);
    assert(
      inlineChunks.isEmpty || inlineChunks.last.endOffset == nextImageOffset,
    );
    final inlinePage = inlineChunks.isEmpty
        ? _ReaderPageData(
            text: '',
            imageBlockIndex: image.$2,
            startOffset: offset,
            endOffset: nextImageOffset,
          )
        : inlineChunks.first.copyWith(imageBlockIndex: image.$2);
    pages.add(inlinePage);
    // The shared projection keeps canonical/display offsets continuous. Only
    // the image-bearing first page uses the reduced text area; continuing text
    // pages return to the full page height.
    pages.addAll(inlineChunks.skip(1));
    cursor = nextImageOffset;
  }

  if (cursor < chapter.plainText.length || pages.isEmpty) {
    pages.addAll(
      paginateRange(
        chapter.plainText.substring(cursor),
        sourceOffset: cursor,
        pageHeight: maxHeight,
      ),
    );
  }
  if (pages.isEmpty) {
    pages.add(
      _ReaderPageData(
        text: '',
        startOffset: 0,
        endOffset: chapter.plainText.length,
        showsInlineChapterTitle: showInlineChapterTitle,
      ),
    );
  }
  assert(pages.isNotEmpty);
  assert(pages.first.startOffset == 0);
  assert(pages.last.endOffset == chapter.plainText.length);
  for (var index = 1; index < pages.length; index++) {
    assert(pages[index - 1].endOffset == pages[index].startOffset);
  }
  return pages;
}

bool _normalizesParagraphBreaks(String format) {
  final normalized = format.toLowerCase();
  return normalized == 'txt' || normalized == 'epub';
}
