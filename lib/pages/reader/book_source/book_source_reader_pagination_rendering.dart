part of 'book_source_reader_page.dart';

extension _BookSourceReaderPaginationRendering on _BookSourceReaderPageState {
  _BookSourcePagedLayout _pagedLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final top = _readerSafeArea.contentTop;
    final bottom = _readerSafeArea.contentBottom;
    final width = readerTextContentWidth(viewport.width, _horizontalMargin);
    final height = readerTextContentHeight(viewport.height, top, bottom);
    const textScaler = readerBodyTextScaler;
    final locale = Localizations.maybeLocaleOf(context);
    final key = ReaderLayoutFingerprint(
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
      pageMode: _pageMode,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      textDirection: Directionality.of(context),
      extra: '${_readerSafeArea.paginationSignature}:${_readerFont.id}',
    ).cacheKey('book-source-line-v5');
    final cached = _pagedLayouts[chapterIndex];
    if (cached?.fingerprint == key) return cached!;
    final pages = paginateBookSourceText(
      _readableChapterText[chapterIndex] ??
          readableBookSourceChapterText(
            content,
            fallbackTitle: _chapters[chapterIndex].title,
          ),
      width: width,
      firstPageHeight: height,
      pageHeight: height,
      style: _bodyTextStyle,
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      textAlign: _bodyTextAlign,
      locale: locale,
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      includeChapterTitlePage: true,
    );
    final layout = _BookSourcePagedLayout(fingerprint: key, pages: pages);
    _pagedLayouts[chapterIndex] = layout;
    return layout;
  }

  void _ensurePagination(
    Size viewport, {
    required BookSourceChapterContent content,
  }) {
    final layout = _pagedLayoutFor(_chapterIndex, content, viewport);
    final key = layout.fingerprint;
    if (_paginationKey == key && _paginatedPages.isNotEmpty) return;
    final currentTextOffset = _paginatedPages.isEmpty
        ? null
        : _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
              .startOffset;
    final pages = layout.pages;
    _paginationKey = key;
    _paginatedPages = pages;
    _pageCount = pages.length;
    final restoredTarget = _restoreTextOffset != null
        ? bookSourcePageIndexForOffset(pages, _restoreTextOffset!)
        : _restorePagedPosition
        ? ((_pageCount - 1) * _restorePageProgress).round()
        : currentTextOffset != null
        ? bookSourcePageIndexForOffset(pages, currentTextOffset)
        : _pageIndex.clamp(0, _pageCount - 1);
    final target = _usesTwoPageLayout
        ? _spreadStartForPage(restoredTarget)
        : restoredTarget;
    _pageIndex = target.clamp(0, _pageCount - 1);
    _restorePagedPosition = false;
    _restoreTextOffset = null;
    final pageProgress = _pagedReadingProgress(_pageIndex, _pageCount);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollProgress.value = pageProgress;
      if (_pageMode == BookSourcePageMode.verticalScroll) {
        _verticalPageCount = _pageCount;
        _verticalPageIndex = (pageProgress * (_verticalPageCount - 1))
            .round()
            .clamp(0, _verticalPageCount - 1);
      }
      _updateReaderState(() {});
      if (_pageMode != BookSourcePageMode.horizontalSlide) return;
      _pageViewLeading = _slideLeadingPageCount(_chapterIndex);
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_pageIndex + _pageViewLeading);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreSlidePageChanges = false;
      });
    });
  }

  Widget _buildPageLeaf(
    BookSourceTextPage page, {
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
    int? chapterIndex,
    BookSourceChapterContent? chapterContent,
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    final resolvedIndex = chapterIndex ?? _chapterIndex;
    final resolvedContent = chapterContent ?? _content!;
    final chapterTitle = resolvedContent.title.isEmpty
        ? _chapters[resolvedIndex].title
        : _cleanChapterTitle(resolvedContent.title);
    final metadata = ReaderPaperPageMetadata(
      pageIdentity:
          'source:${widget.source.id}:${widget.book.id}:'
          '${_chapters[resolvedIndex].id}:$pageIndex:${page.startOffset}',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: chapterTitle,
      pageNumber: pageIndex + 1,
      pageCount: pageCount,
    );
    return ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: metadata,
      pageNumberPlacement: pageNumberPlacement,
      horizontalPadding: math.max(14, _horizontalMargin),
      pageNumberHorizontalPadding: math.max(24, _horizontalMargin),
      showTopInformation: _topBarStyle == ReaderTopBarStyle.reader,
      showFloatingStatus: _showLeafFloatingStatus,
      floatingStatusHorizontalPadding: _floatingStatusHorizontalPadding,
      topInformationLayout: topInformationLayout,
      status: _leafStatusController.value,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _horizontalMargin,
          _readerSafeArea.contentTop,
          _horizontalMargin,
          _readerSafeArea.contentBottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: readerMaxTextContentWidth,
            ),
            child: SizedBox.expand(
              child: _buildAnnotatedTextPage(
                page,
                chapterIndex: resolvedIndex,
                pageIndex: pageIndex,
                content: resolvedContent,
              ),
            ),
          ),
        ),
      ),
    );
  }

  ReaderPageSnapshot _buildPageSnapshot(
    BookSourceTextPage page, {
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
    int? chapterIndex,
    BookSourceChapterContent? chapterContent,
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    final resolvedIndex = chapterIndex ?? _chapterIndex;
    final metadata = ReaderPaperPageMetadata(
      pageIdentity:
          'source:${widget.source.id}:${widget.book.id}:'
          '${_chapters[resolvedIndex].id}:$pageIndex:${page.startOffset}',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: (chapterContent ?? _content!).title.isEmpty
          ? _chapters[resolvedIndex].title
          : (chapterContent ?? _content!).title,
      pageNumber: pageIndex + 1,
      pageCount: pageCount,
    );
    return ReaderPageSnapshot(
      key: metadata.snapshotKey,
      contentRevision: _leafContentRevision,
      child: _buildPageLeaf(
        page,
        pageIndex: pageIndex,
        pageCount: pageCount,
        layoutFingerprint: layoutFingerprint,
        chapterIndex: chapterIndex,
        chapterContent: chapterContent,
        pageNumberPlacement: pageNumberPlacement,
        topInformationLayout: topInformationLayout,
      ),
    );
  }

  ({
    BookSourceTextPage page,
    int pageIndex,
    int pageCount,
    String layoutFingerprint,
    BookSourceChapterContent content,
  })?
  _adjacentPageData(
    int chapterIndex,
    Size viewport, {
    required int Function(int pageCount) selectPageIndex,
  }) {
    final content = _prefetchedContent[chapterIndex];
    if (content == null) return null;
    final layout = _pagedLayoutFor(chapterIndex, content, viewport);
    final pages = layout.pages;
    final pageIndex = selectPageIndex(pages.length);
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    return (
      page: pages[pageIndex],
      pageIndex: pageIndex,
      pageCount: pages.length,
      layoutFingerprint: layout.fingerprint,
      content: content,
    );
  }

  Widget? _buildAdjacentPreview(
    int chapterIndex, {
    bool lastPage = false,
    int? pageIndex,
  }) {
    if (_prefetchedContent[chapterIndex] == null) return null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _adjacentPageData(
          chapterIndex,
          constraints.biggest,
          selectPageIndex: pageIndex != null
              ? (_) => pageIndex
              : lastPage
              ? (pageCount) => pageCount - 1
              : (_) => 0,
        );
        if (data == null) return const SizedBox.shrink();
        return _buildPageLeaf(
          data.page,
          pageIndex: data.pageIndex,
          pageCount: data.pageCount,
          layoutFingerprint: data.layoutFingerprint,
          chapterIndex: chapterIndex,
          chapterContent: data.content,
        );
      },
    );
  }

  Widget _buildBoundaryLeaf({
    required bool forward,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String slotIdentity = '',
  }) {
    final targetChapterIndex = _chapterIndex + (forward ? 1 : -1);
    final chapterTitle =
        targetChapterIndex >= 0 && targetChapterIndex < _chapters.length
        ? _chapters[targetChapterIndex].title
        : '';
    return ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: ReaderPaperPageMetadata(
        pageIdentity:
            'source:${widget.source.id}:${widget.book.id}:'
            'boundary:${forward ? 'forward' : 'backward'}'
            '${slotIdentity.isEmpty ? '' : ':$slotIdentity'}',
        layoutFingerprint: _paginationKey ?? 'unpaginated',
        themeId: _readerTheme.cacheKey,
        chapterTitle: chapterTitle,
        pageNumber: 0,
        pageCount: 0,
      ),
      horizontalPadding: math.max(14, _horizontalMargin),
      showTopInformation: _topBarStyle == ReaderTopBarStyle.reader,
      showFloatingStatus: _showLeafFloatingStatus,
      floatingStatusHorizontalPadding: _floatingStatusHorizontalPadding,
      topInformationLayout: topInformationLayout,
      showPageNumber: false,
      status: _leafStatusController.value,
      child: Center(
        child: Icon(
          forward
              ? Icons.arrow_forward_ios_rounded
              : Icons.arrow_back_ios_new_rounded,
          color: _readerTheme.secondaryText.withValues(alpha: 0.38),
        ),
      ),
    );
  }

  ReaderPageSnapshot _buildBoundarySnapshot({
    required bool forward,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String slotIdentity = '',
  }) => ReaderPageSnapshot(
    key: ReaderPageSnapshotKey(
      pageIdentity:
          'source:${widget.source.id}:${widget.book.id}:'
          'boundary:${forward ? 'forward' : 'backward'}'
          '${slotIdentity.isEmpty ? '' : ':$slotIdentity'}',
      layoutFingerprint: _paginationKey ?? 'unpaginated',
      themeId: _readerTheme.cacheKey,
    ),
    contentRevision: _leafContentRevision,
    child: _buildBoundaryLeaf(
      forward: forward,
      topInformationLayout: topInformationLayout,
      slotIdentity: slotIdentity,
    ),
  );
}
