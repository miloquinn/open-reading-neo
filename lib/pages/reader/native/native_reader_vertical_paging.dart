part of 'native_reader_page.dart';

extension _NativeReaderVerticalPaging on _NativeReaderPageState {
  ReaderViewportChromeMetrics get _verticalChrome =>
      ReaderViewportChromeMetrics(
        safeArea: _readerSafeArea,
        immersive: _topBarStyle == ReaderTopBarStyle.hidden,
        reservesTitle: _topBarStyle == ReaderTopBarStyle.reader,
      );

  double _verticalPageExtentFor(Size viewport) =>
      _verticalChrome.contentHeight(viewport.height);

  Widget _buildVerticalReadingWindow(Widget child) {
    final chrome = _verticalChrome;
    return Padding(
      key: const ValueKey('native-vertical-reading-window'),
      padding: EdgeInsets.only(
        top: chrome.contentTop,
        bottom: chrome.contentBottom,
      ),
      child: ClipRect(child: child),
    );
  }

  ReaderVisibleItemPosition _readerPosition(ItemPosition position) =>
      ReaderVisibleItemPosition(
        index: position.index,
        leadingEdge: position.itemLeadingEdge,
        trailingEdge: position.itemTrailingEdge,
      );

  GlobalKey _continuousPartKey(String chapterId, int partIndex) =>
      _continuousPartKeys.putIfAbsent('$chapterId:$partIndex', GlobalKey.new);

  void _onVerticalPagePositionsChanged() {
    if (!mounted ||
        _pageMode != NativePageMode.verticalScroll ||
        !_scrollByChapter ||
        _visibleContinuousParts.isEmpty) {
      return;
    }
    final primary = pickPrimaryReaderItem(
      _verticalPagePositionsListener.itemPositions.value.map(_readerPosition),
    );
    if (primary == null) return;
    final nextPage = primary.index.clamp(0, _visibleContinuousParts.length - 1);
    _verticalScrollProgress.value = _visibleContinuousParts.length <= 1
        ? 0
        : (nextPage / (_visibleContinuousParts.length - 1)).clamp(0.0, 1.0);
    if (nextPage != _pageIndex) {
      if (nextPage > _pageIndex) _sessionPagesRead++;
      _setReaderState(() => _pageIndex = nextPage);
    }
    final chapter = _visibleChapters[_chapterIndex];
    final part = _visibleContinuousParts[nextPage];
    final offset = _continuousOffsetAtViewportCenter(chapter, part, nextPage);
    _verticalCanonicalOffset = offset;
    _saveCanonicalProgress(
      chapter,
      _ReaderPageData(text: '', startOffset: offset, endOffset: offset),
      _chapterIndex,
    );
  }

  void _onVerticalChapterPositionsChanged() {
    if (!mounted ||
        !_initialPositionRestored ||
        _pageMode != NativePageMode.verticalScroll ||
        _scrollByChapter ||
        _visibleChapters.isEmpty ||
        _verticalViewportSize.isEmpty) {
      return;
    }
    final primary = pickPrimaryReaderItem(
      _verticalChapterPositionsListener.itemPositions.value.map(
        _readerPosition,
      ),
    );
    if (primary == null) return;
    final nextChapter = primary.index.clamp(0, _visibleChapters.length - 1);
    final parts = _continuousPartsFor(
      _visibleChapters[nextChapter],
      _verticalViewportSize,
    );
    var nextPage = readerPageIndexWithinItem(primary, parts.length);
    var closestDistance = double.infinity;
    final viewportCenter = MediaQuery.sizeOf(context).height / 2;
    for (var index = 0; index < parts.length; index++) {
      final renderObject = _continuousPartKey(
        _visibleChapters[nextChapter].id,
        index,
      ).currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      if (top <= viewportCenter && bottom > viewportCenter) {
        nextPage = index;
        break;
      }
      final distance = math.min(
        (top - viewportCenter).abs(),
        (bottom - viewportCenter).abs(),
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        nextPage = index;
      }
    }
    final movedForward =
        nextChapter > _chapterIndex ||
        (nextChapter == _chapterIndex && nextPage > _pageIndex);
    final chapterChanged = nextChapter != _chapterIndex;
    _verticalScrollProgress.value = parts.length <= 1
        ? 0
        : (nextPage / (parts.length - 1)).clamp(0.0, 1.0);
    if (chapterChanged || nextPage != _pageIndex) {
      if (movedForward) _sessionPagesRead++;
      _setReaderState(() {
        _chapterIndex = nextChapter;
        _pageIndex = nextPage;
        _visibleContinuousParts = parts;
        _visiblePages = parts
            .map((part) => part.content)
            .toList(growable: false);
      });
    }
    if (chapterChanged && widget.book.id != null) {
      unawaited(_queueBookProgress(widget.book.id!, nextChapter));
    }
    final offset = _continuousOffsetAtViewportCenter(
      _visibleChapters[nextChapter],
      parts[nextPage],
      nextPage,
    );
    _verticalCanonicalOffset = offset;
    _saveCanonicalProgress(
      _visibleChapters[nextChapter],
      _ReaderPageData(text: '', startOffset: offset, endOffset: offset),
      nextChapter,
    );
  }

  RenderParagraph? _continuousParagraph(String chapterId, int partIndex) {
    final root = _continuousPartKey(chapterId, partIndex).currentContext;
    if (root == null) return null;
    RenderParagraph? result;
    void visit(Element element) {
      if (result != null) return;
      final renderObject = element.renderObject;
      if (renderObject is RenderParagraph) {
        result = renderObject;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return result;
  }

  int _continuousOffsetAtViewportCenter(
    _NativeChapter chapter,
    _ContinuousReaderPart part,
    int partIndex,
  ) {
    final paragraph = _continuousParagraph(chapter.id, partIndex);
    if (paragraph == null || !paragraph.hasSize || part.content.text.isEmpty) {
      return part.content.startOffset;
    }
    final center = Offset(
      paragraph.size.width / 2,
      MediaQuery.sizeOf(context).height / 2 -
          paragraph.localToGlobal(Offset.zero).dy,
    );
    final textPosition = paragraph.getPositionForOffset(center);
    return part.content.sourceOffsetForTextOffset(textPosition.offset);
  }

  double? _continuousCaretOffset(
    _NativeChapter chapter,
    _ContinuousReaderPart part,
    int partIndex,
    int sourceOffset,
  ) {
    final paragraph = _continuousParagraph(chapter.id, partIndex);
    if (paragraph == null || !paragraph.hasSize || part.content.text.isEmpty) {
      return null;
    }
    final textOffset = part.content.textOffsetForSourceOffset(sourceOffset);
    return paragraph
        .getOffsetForCaret(TextPosition(offset: textOffset), Rect.zero)
        .dy;
  }

  Future<void> _scrollContinuousAnchorIntoView(
    _NativeChapter chapter,
    List<_ContinuousReaderPart> parts,
    int partIndex,
    int sourceOffset,
  ) async {
    final targetContext = _continuousPartKey(
      chapter.id,
      partIndex,
    ).currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0,
        duration: Duration.zero,
      );
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final caretOffset = _continuousCaretOffset(
      chapter,
      parts[partIndex],
      partIndex,
      sourceOffset,
    );
    if (caretOffset == null || caretOffset <= 0) return;
    if (_scrollByChapter) {
      final scrollable = Scrollable.maybeOf(
        _continuousPartKey(chapter.id, partIndex).currentContext!,
      );
      if (scrollable != null) {
        scrollable.position.jumpTo(
          (scrollable.position.pixels + caretOffset).clamp(
            scrollable.position.minScrollExtent,
            scrollable.position.maxScrollExtent,
          ),
        );
      }
      return;
    }
    await _verticalChapterOffsetController.animateScroll(
      offset: caretOffset,
      duration: const Duration(milliseconds: 1),
    );
  }

  List<_ContinuousReaderPart> _continuousPartsFor(
    _NativeChapter chapter,
    Size viewport,
  ) {
    final cacheKey =
        '${chapter.id}:$_layoutSignature:'
        '${viewport.width.toStringAsFixed(1)}:'
        '${Directionality.of(context).name}';
    final cached = _continuousPartCache[cacheKey];
    if (cached != null) return cached;
    if (_continuousPartCache.length >= 24) {
      _continuousPartCache.remove(_continuousPartCache.keys.first);
    }
    final maxWidth = readerTextContentWidth(viewport.width, _horizontalMargin);
    final flowStyle = _readerTextFlowStyle(
      direction: _verticalTextDirection,
      textScaler: _verticalTextScaler,
    );
    final imageOffsets = <(int, int)>[];
    var searchFrom = 0;
    for (var index = 0; index < chapter.blocks.length; index++) {
      final block = chapter.blocks[index];
      if (block.hasImage) {
        imageOffsets.add((
          block.startOffset >= 0
              ? block.startOffset.clamp(searchFrom, chapter.plainText.length)
              : searchFrom,
          index,
        ));
        continue;
      }
      final text = block.text;
      if (text == null || text.isEmpty) continue;
      if (block.startOffset >= searchFrom &&
          block.endOffset >= block.startOffset) {
        searchFrom = block.endOffset.clamp(
          searchFrom,
          chapter.plainText.length,
        );
      } else {
        final found = chapter.plainText.indexOf(text, searchFrom);
        if (found >= 0) searchFrom = found + text.length;
      }
    }

    final hasSplitChapterTitle =
        chapter.isNeedSplitTitle && chapter.title.trim().isNotEmpty;
    final showsDedicatedChapterTitle =
        hasSplitChapterTitle &&
        widget.book.format.toLowerCase() == 'txt' &&
        _txtChapterTitlePageEnabled;
    final parts = <_ContinuousReaderPart>[
      if (showsDedicatedChapterTitle)
        const _ContinuousReaderPart(_ReaderPageData.chapterTitle()),
    ];
    void addText(int start, int end) {
      if (start >= end) return;
      var chunkStart = start;
      while (chunkStart < end) {
        var chunkEnd = math.min(chunkStart + 1024, end);
        if (chunkEnd < end) {
          final searchLimit = math.min(chunkStart + 1536, end);
          final nextBreak = chapter.plainText.indexOf('\n', chunkEnd);
          if (nextBreak >= chunkEnd && nextBreak < searchLimit) {
            chunkEnd = nextBreak + 1;
          } else {
            final previousBreak = chapter.plainText.lastIndexOf('\n', chunkEnd);
            if (previousBreak > chunkStart + 512) {
              chunkEnd = previousBreak + 1;
            }
          }
        }
        if (chunkEnd < end &&
            chunkEnd > chunkStart &&
            chapter.plainText.codeUnitAt(chunkEnd) >= 0xDC00 &&
            chapter.plainText.codeUnitAt(chunkEnd) <= 0xDFFF) {
          chunkEnd--;
        }
        final page = paginateReaderText(
          text: chapter.plainText.substring(chunkStart, chunkEnd),
          maxWidth: maxWidth,
          maxHeight: 0,
          flowStyle: flowStyle,
          style: _readerTextStyle,
          sourceOffset: chunkStart,
          firstLineIndent: _firstLineIndent,
          paragraphSpacing: _paragraphSpacing,
          normalizeParagraphBreaks: _normalizesParagraphBreaks(
            widget.book.format,
          ),
          indentFirstParagraph:
              chunkStart == 0 ||
              isReaderLineBreakCodeUnit(
                chapter.plainText.codeUnitAt(chunkStart - 1),
              ),
          sourceSpanBuilder: (sourceStart, sourceEnd) => _styledSpanForRange(
            chapter,
            sourceStart,
            sourceEnd,
            _readerTextStyle,
          ),
        ).single;
        parts.add(_ContinuousReaderPart(_ReaderPageData.fromTextPage(page)));
        chunkStart = chunkEnd;
      }
    }

    var cursor = 0;
    for (var index = 0; index < imageOffsets.length; index++) {
      final offset = imageOffsets[index].$1.clamp(
        cursor,
        chapter.plainText.length,
      );
      addText(cursor, offset);
      parts.add(
        _ContinuousReaderPart(
          _ReaderPageData(text: '', startOffset: offset, endOffset: offset),
          imageBlockIndex: imageOffsets[index].$2,
        ),
      );
      cursor = offset;
    }
    addText(cursor, chapter.plainText.length);
    if (parts.isEmpty) {
      parts.add(
        _ContinuousReaderPart(
          _ReaderPageData(
            text: '',
            startOffset: 0,
            endOffset: chapter.plainText.length,
          ),
        ),
      );
    }
    _continuousPartCache[cacheKey] = parts;
    return parts;
  }

  Widget _buildContinuousPart(
    _NativeChapter chapter,
    _ContinuousReaderPart part, {
    required int chapterIndex,
    required int partIndex,
  }) {
    if (part.content.isChapterTitle) {
      return SizedBox(
        key: _continuousPartKey(chapter.id, partIndex),
        height: _verticalPageExtentFor(_verticalViewportSize),
        child: ReaderChapterTitlePage(
          title: chapter.title,
          bodyStyle: _readerTextStyle,
        ),
      );
    }
    final imageProvider = part.imageBlockIndex == null
        ? null
        : chapter.blocks[part.imageBlockIndex!].imageProvider;
    return Padding(
      key: _continuousPartKey(chapter.id, partIndex),
      padding: EdgeInsets.symmetric(horizontal: _horizontalMargin),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: readerMaxTextContentWidth,
          ),
          child: Column(
            key: ValueKey(
              'native-vertical-part:${chapter.id}:'
              '${part.content.startOffset}:$partIndex',
            ),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (partIndex == 0 &&
                  chapter.isNeedSplitTitle &&
                  chapter.title.trim().isNotEmpty &&
                  (widget.book.format.toLowerCase() != 'txt' ||
                      !_txtChapterTitlePageEnabled)) ...[
                ReaderInlineChapterTitle(
                  title: chapter.title,
                  bodyStyle: _readerTextStyle,
                ),
                const SizedBox(height: ReaderInlineChapterTitle.spacingAfter),
              ],
              if (imageProvider != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: Image(image: imageProvider, fit: BoxFit.contain),
                  ),
                ),
              if (part.content.text.isNotEmpty)
                _buildStyledReaderText(
                  chapter,
                  part.content,
                  chapterIndex: chapterIndex,
                  pageIndex: partIndex,
                  fillAvailableSpace: false,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalChapterItem(
    List<_NativeChapter> chapters,
    int chapterIndex,
    Size viewport,
  ) {
    final chapter = chapters[chapterIndex];
    if (!chapter.hasLoadedText) {
      return FutureBuilder<void>(
        future: _loadIndexedChapterWindow(chapters, chapterIndex),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              !snapshot.hasError) {
            return _buildVerticalChapterItem(chapters, chapterIndex, viewport);
          }
          return SizedBox(
            height: _verticalPageExtentFor(viewport),
            child: Center(
              child: snapshot.hasError
                  ? const Icon(Icons.error_outline_rounded)
                  : CircularProgressIndicator(color: _readerTheme.accent),
            ),
          );
        },
      );
    }
    final parts = _continuousPartsFor(chapter, viewport);
    return Column(
      children: [
        for (var partIndex = 0; partIndex < parts.length; partIndex++)
          _buildContinuousPart(
            chapter,
            parts[partIndex],
            chapterIndex: chapterIndex,
            partIndex: partIndex,
          ),
      ],
    );
  }

  Widget _buildVerticalPageList(
    _NativeChapter chapter,
    List<_ReaderPageData> pages,
    Size viewport,
  ) {
    final parts = _continuousPartsFor(chapter, viewport);
    _visibleContinuousParts = parts;
    _visiblePages = parts.map((part) => part.content).toList(growable: false);
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('native-reader-surface'),
      child: ScrollablePositionedList.builder(
        key: ValueKey('native-vertical-pages:$_chapterIndex:$_layoutSignature'),
        itemScrollController: _verticalPageScrollController,
        itemPositionsListener: _verticalPagePositionsListener,
        initialScrollIndex: _pageIndex.clamp(0, parts.length - 1),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: parts.length,
        itemBuilder: (context, index) => _buildContinuousPart(
          chapter,
          parts[index],
          chapterIndex: _chapterIndex,
          partIndex: index,
        ),
      ),
    );
  }

  Widget _buildVerticalBook(List<_NativeChapter> chapters, Size viewport) {
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('native-reader-surface'),
      child: ScrollablePositionedList.builder(
        key: ValueKey('native-vertical-book:$_layoutSignature'),
        itemScrollController: _verticalChapterScrollController,
        scrollOffsetController: _verticalChapterOffsetController,
        itemPositionsListener: _verticalChapterPositionsListener,
        initialScrollIndex: _chapterIndex.clamp(0, chapters.length - 1),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: chapters.length,
        itemBuilder: (context, index) =>
            _buildVerticalChapterItem(chapters, index, viewport),
      ),
    );
  }
}
