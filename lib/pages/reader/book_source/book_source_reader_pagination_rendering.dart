part of 'book_source_reader_page.dart';

extension _BookSourceReaderPaginationRendering on _BookSourceReaderPageState {
  _BookSourcePagedLayoutInput _pagedLayoutInputFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    _checkOnlinePaginationEpoch();
    final text =
        _readableChapterText[chapterIndex] ??
        readableBookSourceChapterText(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final chapterTitle = _chapters[chapterIndex].title;
    final hasChapterTitle = chapterTitle.trim().isNotEmpty;
    final candidate = _persistedOnlinePagination[chapterIndex];
    final stored = candidate?.text == text ? candidate : null;
    final revision =
        stored?.revision ?? sha256.convert(utf8.encode(text)).toString();
    final top = _readerSafeArea.contentTop;
    final bottom = _readerSafeArea.contentBottom;
    final width = readerTextContentWidth(viewport.width, _horizontalMargin);
    final height = readerTextContentHeight(viewport.height, top, bottom);
    const textScaler = readerBodyTextScaler;
    final locale = Localizations.maybeLocaleOf(context);
    final fingerprint = ReaderLayoutFingerprint(
      contentKey: '${_chapters[chapterIndex].id}:$revision',
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
      extra:
          '${_readerSafeArea.paginationSignature}:'
          '${_readerFontProfile.cacheSignature}:'
          '${_replaceRules.rulesSignature}:'
          '$_chapterTitlePageEnabled:$chapterTitle',
    ).cacheKey('book-source-line-v7');
    final style = _bodyTextStyle;
    final textDirection = Directionality.of(context);
    return _BookSourcePagedLayoutInput(
      fingerprint: fingerprint,
      revision: revision,
      epoch: _paginationCacheEpoch,
      payload: stored?.layouts[fingerprint],
      text: text,
      width: width,
      height: height,
      style: style,
      flowStyle: NativeTextFlowStyle(
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
        strutStyle: readerStrutStyle(style),
        textHeightBehavior: readerTextHeightBehavior,
        textAlign: _bodyTextAlign,
      ),
      firstLineIndent: _firstLineIndent,
      paragraphSpacing: _paragraphSpacing,
      includeChapterTitlePage: hasChapterTitle && _chapterTitlePageEnabled,
      inlineChapterTitleExtent: hasChapterTitle && !_chapterTitlePageEnabled
          ? ReaderInlineChapterTitle.extentFor(
              title: chapterTitle,
              maxWidth: width,
              bodyStyle: style,
              textDirection: textDirection,
              textScaler: textScaler,
              locale: locale,
            )
          : null,
    );
  }

  _BookSourcePagedLayout? _cachedPagedLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final input = _pagedLayoutInputFor(chapterIndex, content, viewport);
    final cached = _pagedLayouts[chapterIndex];
    return cached?.fingerprint == input.fingerprint ? cached : null;
  }

  _BookSourcePagedLayout _publishPagedLayout(
    int chapterIndex,
    _BookSourcePagedLayoutInput input,
    List<ReaderTextPage> pages, {
    required bool persist,
  }) {
    if (persist) {
      _persistOnlinePagination(
        chapterIndex,
        input.revision,
        input.fingerprint,
        pages,
      );
    }
    final layout = _BookSourcePagedLayout(
      fingerprint: input.fingerprint,
      pages: pages,
    );
    _pagedLayouts[chapterIndex] = layout;
    return layout;
  }

  _BookSourcePagedLayout _pagedLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport,
  ) {
    final input = _pagedLayoutInputFor(chapterIndex, content, viewport);
    final cached = _pagedLayouts[chapterIndex];
    if (cached?.fingerprint == input.fingerprint) return cached!;
    final restored = input.restorePages();
    if (restored == null) widget.onPaginationCacheMiss?.call(chapterIndex);
    return _publishPagedLayout(
      chapterIndex,
      input,
      restored ?? input.paginate(),
      persist: restored == null,
    );
  }

  Future<_BookSourcePagedLayout?> _preparePagedLayoutFor(
    int chapterIndex,
    BookSourceChapterContent content,
    Size viewport, {
    required Future<void> Function() yieldBetweenPages,
    required bool Function() isCurrent,
  }) async {
    if (!mounted || !isCurrent()) return null;
    final input = _pagedLayoutInputFor(chapterIndex, content, viewport);
    // Compare the source and scalar settings while yielding; hashing all
    // chapter text and measuring its title again on every page would undo
    // the benefit of incremental pagination.
    Object validityToken() => (
      _readableChapterText[chapterIndex],
      _chapters[chapterIndex].title,
      _readerFont,
      _fontSize,
      _fontWeight,
      _lineHeight,
      _letterSpacing,
      _textAlignment,
      _horizontalMargin,
      _topMargin,
      _bottomMargin,
      _topBarStyle,
      _pageMode,
      _firstLineIndent,
      _paragraphSpacing,
      _chapterTitlePageEnabled,
      _replaceRules.rulesSignature,
      MediaQuery.viewPaddingOf(context),
      MediaQuery.sizeOf(context),
      Localizations.maybeLocaleOf(context),
      Directionality.of(context),
      PaginationCacheDao.epoch,
    );
    final token = validityToken();
    bool stillCurrent() => mounted && isCurrent() && validityToken() == token;

    final cached = _pagedLayouts[chapterIndex];
    if (cached?.fingerprint == input.fingerprint) return cached;
    // Cache decoding also stays behind the caller's interaction-aware yield.
    await yieldBetweenPages();
    if (!stillCurrent()) return null;
    final restored = input.restorePages();
    if (restored != null) {
      return _publishPagedLayout(chapterIndex, input, restored, persist: false);
    }
    widget.onPaginationCacheMiss?.call(chapterIndex);
    try {
      final pages = await input.paginateIncrementally(() async {
        await yieldBetweenPages();
        if (!stillCurrent()) throw const _ObsoletePagedLayout();
      });
      if (!stillCurrent()) return null;
      final current = _pagedLayoutInputFor(chapterIndex, content, viewport);
      if (current.epoch != input.epoch ||
          current.fingerprint != input.fingerprint) {
        return null;
      }
      return _publishPagedLayout(chapterIndex, input, pages, persist: true);
    } on _ObsoletePagedLayout {
      return null;
    }
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
    final chapterTitle = _chapters[resolvedIndex].title;
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
      chapterProgressLabel: formatReaderChapterProgress(
        context,
        style: _chapterProgressStyle,
        chapterIndex: resolvedIndex,
        chapterCount: _chapters.length,
      ),
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
      chapterTitle: _chapters[resolvedIndex].title,
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
    final layout = _cachedPagedLayoutFor(chapterIndex, content, viewport);
    if (layout == null) {
      _schedulePagedLayoutWarm(chapterIndex);
      return null;
    }
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
        if (data == null) {
          return _buildBoundaryLeaf(forward: chapterIndex > _chapterIndex);
        }
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

class _ObsoletePagedLayout implements Exception {
  const _ObsoletePagedLayout();
}

class _BookSourcePagedLayoutInput {
  const _BookSourcePagedLayoutInput({
    required this.fingerprint,
    required this.revision,
    required this.epoch,
    required this.payload,
    required this.text,
    required this.width,
    required this.height,
    required this.style,
    required this.flowStyle,
    required this.firstLineIndent,
    required this.paragraphSpacing,
    required this.includeChapterTitlePage,
    required this.inlineChapterTitleExtent,
  });

  final String fingerprint;
  final String revision;
  final int epoch;
  final Uint8List? payload;
  final String text;
  final double width;
  final double height;
  final TextStyle style;
  final NativeTextFlowStyle flowStyle;
  final int firstLineIndent;
  final int paragraphSpacing;
  final bool includeChapterTitlePage;
  final double? inlineChapterTitleExtent;

  List<ReaderTextPage>? restorePages() => payload == null
      ? null
      : ReaderPaginationCacheCodec.restoreTextPages(
          payload!,
          text: text,
          firstLineIndent: firstLineIndent,
          paragraphSpacing: paragraphSpacing,
        );

  List<ReaderTextPage> paginate() => paginateReaderText(
    text: text,
    maxWidth: width,
    maxHeight: height,
    firstPageHeight: height,
    flowStyle: flowStyle,
    style: style,
    firstLineIndent: firstLineIndent,
    paragraphSpacing: paragraphSpacing,
    normalizeParagraphBreaks: true,
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
  );

  Future<List<ReaderTextPage>> paginateIncrementally(
    Future<void> Function() yieldBetweenPages,
  ) => paginateReaderTextIncrementally(
    text: text,
    maxWidth: width,
    maxHeight: height,
    firstPageHeight: height,
    flowStyle: flowStyle,
    style: style,
    firstLineIndent: firstLineIndent,
    paragraphSpacing: paragraphSpacing,
    normalizeParagraphBreaks: true,
    includeChapterTitlePage: includeChapterTitlePage,
    inlineChapterTitleExtent: inlineChapterTitleExtent,
    yieldBetweenPages: yieldBetweenPages,
  );
}
