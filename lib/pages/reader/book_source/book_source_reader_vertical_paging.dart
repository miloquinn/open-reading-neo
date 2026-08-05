part of 'book_source_reader_page.dart';

extension _BookSourceReaderVerticalPaging on _BookSourceReaderPageState {
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
      key: const ValueKey('book-source-vertical-reading-window'),
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

  GlobalKey _verticalPartKey(int chapterIndex, int partIndex) =>
      _verticalPartKeys.putIfAbsent('$chapterIndex:$partIndex', GlobalKey.new);

  RenderParagraph? _verticalParagraph(int chapterIndex, int partIndex) {
    final root = _verticalPartKey(chapterIndex, partIndex).currentContext;
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

  int _verticalOffsetAtViewportCenter(
    int chapterIndex,
    int partIndex,
    BookSourceTextPage page,
  ) {
    final paragraph = _verticalParagraph(chapterIndex, partIndex);
    if (paragraph == null || !paragraph.hasSize || page.text.isEmpty) {
      return page.startOffset;
    }
    final center = Offset(
      paragraph.size.width / 2,
      MediaQuery.sizeOf(context).height / 2 -
          paragraph.localToGlobal(Offset.zero).dy,
    );
    return page.sourceOffsetForTextOffset(
      paragraph.getPositionForOffset(center).offset,
    );
  }

  double? _verticalCaretOffset(
    int chapterIndex,
    int partIndex,
    BookSourceTextPage page,
    int sourceOffset,
  ) {
    final paragraph = _verticalParagraph(chapterIndex, partIndex);
    if (paragraph == null || !paragraph.hasSize || page.text.isEmpty) {
      return null;
    }
    return paragraph
        .getOffsetForCaret(
          TextPosition(offset: page.textOffsetForSourceOffset(sourceOffset)),
          Rect.zero,
        )
        .dy;
  }

  List<BookSourceTextPage> _continuousTextParts(
    String text, {
    required double width,
    required TextDirection direction,
    required Locale? locale,
  }) {
    if (text.isEmpty) {
      return const [BookSourceTextPage(text: '')];
    }
    return paginateBookSourceText(
      text,
      width: width,
      firstPageHeight: 0,
      pageHeight: 0,
      style: _bodyTextStyle,
      textDirection: direction,
      textScaler: readerBodyTextScaler,
      textAlign: _bodyTextAlign,
      locale: locale,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      includeChapterTitlePage: false,
    );
  }

  _BookSourceVerticalLayout _verticalLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final chrome = _verticalChrome;
    final width = readerTextContentWidth(viewport.width, _horizontalMargin);
    final height = _verticalPageExtentFor(viewport);
    const textScaler = readerBodyTextScaler;
    final locale = Localizations.maybeLocaleOf(context);
    final direction = Directionality.of(context);
    final fingerprint = ReaderLayoutFingerprint(
      contentKey: _chapters[chapterIndex].id,
      viewport: Size(width, height),
      fontSize: _fontSize,
      fontWeight: _fontWeight,
      lineHeight: _lineHeight,
      letterSpacing: _letterSpacing,
      textAlign: _bodyTextAlign,
      horizontalMargin: _horizontalMargin,
      verticalMargin: _topMargin + _bottomMargin,
      textScaler: textScaler,
      locale: locale,
      pageMode: BookSourcePageMode.verticalScroll,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      textDirection: direction,
      extra: '${chrome.paginationSignature}:${_readerFont.id}',
    ).cacheKey('book-source-vertical-v2');
    final cached = _verticalLayouts[chapterIndex];
    if (cached?.fingerprint == fingerprint) return cached!;
    final text =
        _readableChapterText[chapterIndex] ??
        readableBookSourceChapterText(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final pages = _continuousTextParts(
      text,
      width: width,
      direction: direction,
      locale: locale,
    );
    final layout = _BookSourceVerticalLayout(
      fingerprint: fingerprint,
      pages: pages,
    );
    _verticalLayouts[chapterIndex] = layout;
    return layout;
  }

  void _restoreVerticalPosition(
    _BookSourceVerticalLayout layout, {
    required bool wholeBook,
  }) {
    if (!_restorePagedPosition) return;
    final restoreOffset = _restoreTextOffset;
    final target = restoreOffset != null
        ? bookSourcePageIndexForOffset(layout.pages, restoreOffset)
        : ((layout.pages.length - 1) * _restorePageProgress).round();
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = target.clamp(0, layout.pages.length - 1);
    _pageIndex = _verticalPageIndex;
    _restorePagedPosition = false;
    _restoreTextOffset = null;
    final textLength = _readableChapterText[_chapterIndex]?.length ?? 0;
    final restoredProgress = restoreOffset != null && textLength > 0
        ? (restoreOffset / textLength).clamp(0.0, 1.0)
        : _restorePageProgress;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollProgress.value = restoredProgress;
      if (!wholeBook && _verticalPageScrollController.isAttached) {
        _verticalPageScrollController.jumpTo(index: _verticalPageIndex);
      } else if (_verticalChapterScrollController.isAttached) {
        _verticalChapterScrollController.jumpTo(index: _chapterIndex);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final targetContext = _verticalPartKey(
          _chapterIndex,
          _verticalPageIndex,
        ).currentContext;
        if (targetContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            targetContext,
            alignment: 0,
            duration: Duration.zero,
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final sourceOffset =
              restoreOffset ?? (restoredProgress * textLength).round();
          final caretOffset = _verticalCaretOffset(
            _chapterIndex,
            _verticalPageIndex,
            layout.pages[_verticalPageIndex],
            sourceOffset,
          );
          final currentTarget = _verticalPartKey(
            _chapterIndex,
            _verticalPageIndex,
          ).currentContext;
          final scrollable = currentTarget == null
              ? null
              : Scrollable.maybeOf(currentTarget);
          if (caretOffset != null && scrollable != null) {
            scrollable.position.jumpTo(
              (scrollable.position.pixels + caretOffset).clamp(
                scrollable.position.minScrollExtent,
                scrollable.position.maxScrollExtent,
              ),
            );
          }
        });
      });
    });
  }

  void _onVerticalPagePositionsChanged() {
    if (!mounted ||
        _pageMode != BookSourcePageMode.verticalScroll ||
        !_scrollByChapter) {
      return;
    }
    final layout = _verticalLayouts[_chapterIndex];
    if (layout == null || layout.pages.isEmpty) return;
    final primary = pickPrimaryReaderItem(
      _verticalPagePositionsListener.itemPositions.value.map(_readerPosition),
    );
    if (primary == null) return;
    final nextPage = primary.index.clamp(0, layout.pages.length - 1);
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = nextPage;
    final textLength = _readableChapterText[_chapterIndex]?.length ?? 0;
    final offset = _verticalOffsetAtViewportCenter(
      _chapterIndex,
      nextPage,
      layout.pages[nextPage],
    );
    _verticalCanonicalOffset = offset;
    _scrollProgress.value = textLength == 0
        ? 0
        : (offset / textLength).clamp(0.0, 1.0);
    if (nextPage != _pageIndex) {
      if (nextPage > _pageIndex) _sessionPagesRead++;
      _updateReaderState(() => _pageIndex = nextPage);
    }
    _scheduleProgressSave();
  }

  void _onVerticalChapterPositionsChanged() {
    if (!mounted ||
        _pageMode != BookSourcePageMode.verticalScroll ||
        _scrollByChapter ||
        _chapters.isEmpty ||
        _verticalViewportSize.isEmpty) {
      return;
    }
    final primary = pickPrimaryReaderItem(
      _verticalChapterPositionsListener.itemPositions.value.map(
        _readerPosition,
      ),
    );
    if (primary == null) return;
    final nextChapter = primary.index.clamp(0, _chapters.length - 1);
    final content = _prefetchedContent[nextChapter];
    if (content == null) {
      unawaited(_continuousContentFor(nextChapter));
      return;
    }
    final layout = _verticalLayoutFor(
      nextChapter,
      content,
      _verticalViewportSize,
    );
    var nextPage = readerPageIndexWithinItem(primary, layout.pages.length);
    var closestDistance = double.infinity;
    final viewportCenter = MediaQuery.sizeOf(context).height / 2;
    for (var index = 0; index < layout.pages.length; index++) {
      final renderObject = _verticalPartKey(
        nextChapter,
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
        (nextChapter == _chapterIndex && nextPage > _verticalPageIndex);
    final chapterChanged = nextChapter != _chapterIndex;
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = nextPage;
    final textLength = _readableChapterText[nextChapter]?.length ?? 0;
    final offset = _verticalOffsetAtViewportCenter(
      nextChapter,
      nextPage,
      layout.pages[nextPage],
    );
    _verticalCanonicalOffset = offset;
    _scrollProgress.value = textLength == 0
        ? 0
        : (offset / textLength).clamp(0.0, 1.0);
    if (chapterChanged || nextPage != _pageIndex || _content != content) {
      if (movedForward) _sessionPagesRead++;
      _updateReaderState(() {
        _chapterIndex = nextChapter;
        _content = content;
        _pageIndex = nextPage;
      });
    }
    if (chapterChanged) unawaited(_preloadAround(nextChapter));
    _scheduleProgressSave();
  }

  Widget _buildAnnotatedTextPage(
    BookSourceTextPage page, {
    required int chapterIndex,
    required int pageIndex,
    required BookSourceChapterContent content,
    bool fillAvailableSpace = true,
  }) {
    final chapterTitle = content.title.isEmpty
        ? _chapters[chapterIndex].title
        : _cleanChapterTitle(content.title);
    final sourceText =
        _readableChapterText[chapterIndex] ??
        readableBookSourceChapterText(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    return ReaderAnnotatedTextPage(
      key: ValueKey(
        'source-annotated-page:${_chapters[chapterIndex].id}:$pageIndex:'
        '${page.startOffset}:${page.endOffset}',
      ),
      page: page,
      sourceText: sourceText,
      chapterId: _chapters[chapterIndex].id,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      bookId: _shelfBookId,
      format: content.contentType == 'text/html'
          ? BookFormat.html
          : BookFormat.txt,
      renderer: ReaderRendererType.flutterNative,
      palette: _readerTheme,
      bodyStyle: _bodyTextStyle,
      flowStyle: _bodyTextFlowStyle(),
      annotations: _annotations,
      spokenHighlight: _readerAloudHighlight,
      onSaveTextAnnotation: _saveTextAnnotation,
      onAnnotationUnavailable: () => _ensureAnnotationBook(),
      onAskAiSelection: _askAiAboutSelection,
      fillAvailableSpace: fillAvailableSpace,
      onInteractionChanged: (active) {
        if (!mounted || _annotationInteractionActive == active) return;
        _updateReaderState(() => _annotationInteractionActive = active);
      },
    );
  }

  Widget _buildVerticalPageCell(
    BookSourceTextPage page,
    Size viewport, {
    required int chapterIndex,
    required int pageIndex,
    required BookSourceChapterContent content,
  }) {
    return Padding(
      key: _verticalPartKey(chapterIndex, pageIndex),
      padding: EdgeInsets.symmetric(horizontal: _horizontalMargin),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: readerMaxTextContentWidth,
          ),
          child: Column(
            key: ValueKey(
              'book-source-vertical-part:${_chapters[chapterIndex].id}:'
              '${page.startOffset}:$pageIndex',
            ),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pageIndex == 0) ...[
                ReaderInlineChapterTitle(
                  title: content.title.isEmpty
                      ? _chapters[chapterIndex].title
                      : _cleanChapterTitle(content.title),
                  bodyStyle: _bodyTextStyle,
                ),
                const SizedBox(height: ReaderInlineChapterTitle.spacingAfter),
              ],
              _buildAnnotatedTextPage(
                page,
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                content: content,
                fillAvailableSpace: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalChapter(int chapterIndex, Size viewport) {
    final cached = _prefetchedContent[chapterIndex];
    Widget buildContent(BookSourceChapterContent content) {
      final layout = _verticalLayoutFor(chapterIndex, content, viewport);
      return Column(
        children: [
          for (var pageIndex = 0; pageIndex < layout.pages.length; pageIndex++)
            _buildVerticalPageCell(
              layout.pages[pageIndex],
              viewport,
              chapterIndex: chapterIndex,
              pageIndex: pageIndex,
              content: content,
            ),
        ],
      );
    }

    if (cached != null && _readableChapterText.containsKey(chapterIndex)) {
      return buildContent(cached);
    }
    return FutureBuilder<BookSourceChapterContent>(
      future: _continuousContentFor(chapterIndex),
      builder: (context, snapshot) {
        final content = snapshot.data;
        if (content != null) return buildContent(content);
        if (snapshot.hasError) {
          return SizedBox(
            height: _verticalPageExtentFor(viewport),
            child: Center(
              child: TextButton.icon(
                onPressed: () {
                  _updateReaderState(
                    () => _continuousContentLoads.remove(chapterIndex),
                  );
                },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retry),
              ),
            ),
          );
        }
        return SizedBox(
          height: _verticalPageExtentFor(viewport),
          child: Center(
            child: CircularProgressIndicator(color: _readerTheme.accent),
          ),
        );
      },
    );
  }

  Widget _buildVerticalPageList(
    _BookSourceVerticalLayout layout,
    Size viewport,
  ) {
    final layoutStateChanged =
        _verticalPageCount != layout.pages.length ||
        _verticalPageIndex >= layout.pages.length;
    _verticalPageCount = layout.pages.length;
    _verticalPageIndex = _verticalPageIndex.clamp(0, layout.pages.length - 1);
    _pageIndex = _verticalPageIndex;
    if (layoutStateChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateReaderState(() {});
      });
    }
    _restoreVerticalPosition(layout, wholeBook: false);
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('book-source-reader-surface'),
      onHorizontalDragEnd: _handleHorizontalSwipe,
      child: ScrollablePositionedList.builder(
        key: ValueKey(
          'source-vertical-pages:$_chapterIndex:${layout.fingerprint}',
        ),
        itemScrollController: _verticalPageScrollController,
        itemPositionsListener: _verticalPagePositionsListener,
        initialScrollIndex: _verticalPageIndex.clamp(
          0,
          layout.pages.length - 1,
        ),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: layout.pages.length,
        itemBuilder: (context, index) => _buildVerticalPageCell(
          layout.pages[index],
          viewport,
          chapterIndex: _chapterIndex,
          pageIndex: index,
          content: _content!,
        ),
      ),
    );
  }

  Widget _buildVerticalBook(Size viewport) {
    final content = _prefetchedContent[_chapterIndex] ?? _content!;
    final currentLayout = _verticalLayoutFor(_chapterIndex, content, viewport);
    final layoutStateChanged =
        _verticalPageCount != currentLayout.pages.length ||
        _verticalPageIndex >= currentLayout.pages.length;
    _verticalPageCount = currentLayout.pages.length;
    _verticalPageIndex = _verticalPageIndex.clamp(
      0,
      currentLayout.pages.length - 1,
    );
    _pageIndex = _verticalPageIndex;
    if (layoutStateChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateReaderState(() {});
      });
    }
    _restoreVerticalPosition(currentLayout, wholeBook: true);
    return ReaderVerticalPagingSurface(
      surfaceKey: const ValueKey('book-source-reader-surface'),
      child: ScrollablePositionedList.builder(
        key: ValueKey(
          'source-vertical-book:${viewport.width.toStringAsFixed(1)}:'
          '${viewport.height.toStringAsFixed(1)}:'
          '${_fontSize.toStringAsFixed(1)}:$_fontWeight:'
          '${_lineHeight.toStringAsFixed(2)}:'
          '${_letterSpacing.toStringAsFixed(1)}:${_textAlignment.name}:'
          '$_firstLineIndent:$_paragraphSpacing:${_readerFont.id}:'
          '${_verticalChrome.paginationSignature}',
        ),
        itemScrollController: _verticalChapterScrollController,
        scrollOffsetController: _verticalChapterOffsetController,
        itemPositionsListener: _verticalChapterPositionsListener,
        initialScrollIndex: _chapterIndex.clamp(0, _chapters.length - 1),
        minCacheExtent: _verticalPageExtentFor(viewport),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: _chapters.length,
        itemBuilder: (context, index) => _buildVerticalChapter(index, viewport),
      ),
    );
  }
}
