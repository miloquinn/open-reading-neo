part of 'native_reader_page.dart';

extension _NativeReaderRendering on _NativeReaderPageState {
  Widget _buildBookPageLeaf(
    List<_NativeChapter> chapters,
    _BookPageRef page, {
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    if (page.isBlank) {
      return _buildBlankPageLeaf(
        pageIdentity: 'chapter-${page.chapterIndex}-padding',
        layoutFingerprint: page.layoutFingerprint,
        topInformationLayout: topInformationLayout,
      );
    }
    return _buildPageLeaf(
      chapters[page.chapterIndex],
      page.content,
      chapterIndex: page.chapterIndex,
      pageIndex: page.pageIndex,
      pageCount: page.pageCount,
      layoutFingerprint: page.layoutFingerprint,
      pageNumberPlacement: pageNumberPlacement,
      topInformationLayout: topInformationLayout,
    );
  }

  ReaderPageSnapshot _buildCoverSpreadSnapshot(
    List<_NativeChapter> chapters,
    List<_BookPageRef> bookPages,
    int spreadStart,
  ) {
    final left = bookPages[spreadStart];
    final right = spreadStart + 1 < bookPages.length
        ? bookPages[spreadStart + 1]
        : null;
    return ReaderPageSnapshot(
      key: ReaderPageSnapshotKey(
        pageIdentity:
            'native:${widget.book.id ?? _bookCacheKey}:'
            'cover-spread:${left.chapterIndex}:${left.pageIndex}',
        layoutFingerprint: left.layoutFingerprint,
        themeId: _readerTheme.cacheKey,
      ),
      contentRevision: _leafContentRevision,
      child: _buildSpread(
        left: _buildBookPageLeaf(
          chapters,
          left,
          pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
          topInformationLayout: ReaderTopInformationLayout.spreadLeft,
        ),
        right: right == null
            ? null
            : _buildBookPageLeaf(
                chapters,
                right,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              ),
      ),
    );
  }

  ReaderPageSnapshot _buildBookPageSnapshot(
    List<_NativeChapter> chapters,
    _BookPageRef page, {
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    if (page.isBlank) {
      return _buildBlankPageSnapshot(
        pageIdentity: 'chapter-${page.chapterIndex}-padding',
        layoutFingerprint: page.layoutFingerprint,
        topInformationLayout: topInformationLayout,
      );
    }
    final metadata = _nativePageMetadata(
      chapters[page.chapterIndex],
      page.content,
      chapterIndex: page.chapterIndex,
      pageIndex: page.pageIndex,
      pageCount: page.pageCount,
      layoutFingerprint: page.layoutFingerprint,
    );
    return ReaderPageSnapshot(
      key: metadata.snapshotKey,
      contentRevision: _leafContentRevision,
      child: _buildBookPageLeaf(
        chapters,
        page,
        pageNumberPlacement: pageNumberPlacement,
        topInformationLayout: topInformationLayout,
      ),
    );
  }

  Widget _buildPageCurlSpread(
    BuildContext context,
    List<_NativeChapter> chapters,
    List<_BookPageRef> bookPages,
    int currentIndex,
  ) {
    final spreadStart = (currentIndex ~/ 2) * 2;
    final nextSpreadStart = spreadStart + 2;
    final hasPreviousSpread = spreadStart >= 2;
    final hasNextSpread = nextSpreadStart < bookPages.length;
    final currentLeft = bookPages[spreadStart];
    final currentRight = spreadStart + 1 < bookPages.length
        ? bookPages[spreadStart + 1]
        : null;
    final previousLeft = hasPreviousSpread ? bookPages[spreadStart - 2] : null;
    final previousRight = hasPreviousSpread ? bookPages[spreadStart - 1] : null;
    final nextLeft = hasNextSpread ? bookPages[nextSpreadStart] : null;
    final nextRight = nextSpreadStart + 1 < bookPages.length
        ? bookPages[nextSpreadStart + 1]
        : null;
    final pagesToPrepare = <_BookPageRef>[
      currentLeft,
      ?currentRight,
      ?previousLeft,
      ?previousRight,
      ?nextLeft,
      ?nextRight,
    ];

    final left = ReaderShaderPageCurl(
      key: ValueKey(
        'native-spread-curl-left:${widget.book.id ?? _bookCacheKey}',
      ),
      controller: _spreadBackwardPageCurlController,
      coordinator: _spreadPageCurlCoordinator,
      edgeDragOnly: true,
      bindingEdge: ReaderPageBindingEdge.right,
      currentPage: _buildBookPageSnapshot(
        chapters,
        currentLeft,
        pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
        topInformationLayout: ReaderTopInformationLayout.spreadLeft,
      ),
      backwardPage: previousLeft == null
          ? null
          : _buildBookPageSnapshot(
              chapters,
              previousLeft,
              pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
              topInformationLayout: ReaderTopInformationLayout.spreadLeft,
            ),
      outgoingBackPage: previousRight == null
          ? null
          : _buildBookPageSnapshot(
              chapters,
              previousRight,
              pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
              topInformationLayout: ReaderTopInformationLayout.spreadRight,
            ),
      preparePages: () =>
          _precacheBookPageImages(context, chapters, pagesToPrepare),
      onTurnForward: () {},
      onTurnBackward: () =>
          _onBookPageChanged(spreadStart - 2, bookPages, chapters),
      paperColor: _readerTheme.background,
    );

    final right = currentRight == null
        ? null
        : ReaderShaderPageCurl(
            key: ValueKey(
              'native-spread-curl-right:${widget.book.id ?? _bookCacheKey}',
            ),
            controller: _spreadForwardPageCurlController,
            coordinator: _spreadPageCurlCoordinator,
            edgeDragOnly: true,
            currentPage: _buildBookPageSnapshot(
              chapters,
              currentRight,
              pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
              topInformationLayout: ReaderTopInformationLayout.spreadRight,
            ),
            outgoingBackPage: nextLeft == null
                ? null
                : _buildBookPageSnapshot(
                    chapters,
                    nextLeft,
                    pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                    topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                  ),
            forwardPage: !hasNextSpread
                ? null
                : nextRight == null
                ? _buildBlankPageSnapshot(
                    pageIdentity: 'spread-$nextSpreadStart-right',
                    layoutFingerprint: nextLeft!.layoutFingerprint,
                    topInformationLayout:
                        ReaderTopInformationLayout.spreadRight,
                  )
                : _buildBookPageSnapshot(
                    chapters,
                    nextRight,
                    pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
                    topInformationLayout:
                        ReaderTopInformationLayout.spreadRight,
                  ),
            preparePages: () =>
                _precacheBookPageImages(context, chapters, pagesToPrepare),
            onTurnForward: () =>
                _onBookPageChanged(nextSpreadStart, bookPages, chapters),
            onTurnBackward: () {},
            paperColor: _readerTheme.background,
          );

    return ReaderPageCurlSpread(
      coordinator: _spreadPageCurlCoordinator,
      left: left,
      right: right,
      gutter: _buildSpreadGutter(),
    );
  }

  ReaderPageSnapshot _buildBlankPageSnapshot({
    required String pageIdentity,
    required String layoutFingerprint,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) => ReaderPageSnapshot(
    key: ReaderPageSnapshotKey(
      pageIdentity:
          'native:${widget.book.id ?? _bookCacheKey}:'
          '$pageIdentity',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
    ),
    contentRevision: _leafContentRevision,
    child: _buildBlankPageLeaf(
      pageIdentity: pageIdentity,
      layoutFingerprint: layoutFingerprint,
      topInformationLayout: topInformationLayout,
    ),
  );

  Widget _buildBlankPageLeaf({
    required String pageIdentity,
    required String layoutFingerprint,
    required ReaderTopInformationLayout topInformationLayout,
  }) => ReaderPaperPageLeaf(
    palette: _readerTheme,
    safeArea: _readerSafeArea,
    metadata: ReaderPaperPageMetadata(
      pageIdentity:
          'native:${widget.book.id ?? _bookCacheKey}:'
          'blank:$pageIdentity',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: '',
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
    child: const SizedBox.expand(),
  );

  ReaderPaperPageMetadata _nativePageMetadata(
    _NativeChapter chapter,
    _ReaderPageData page, {
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
  }) {
    final resolvedChapterTitle = chapter.title.isEmpty
        ? context.l10n.readerChapterFallback(chapterIndex + 1)
        : chapter.title;
    return ReaderPaperPageMetadata(
      pageIdentity:
          'native:${widget.book.id ?? _bookCacheKey}:'
          '${chapter.id}:$pageIndex:${page.startOffset}',
      layoutFingerprint: layoutFingerprint,
      themeId: _readerTheme.cacheKey,
      chapterTitle: resolvedChapterTitle,
      pageNumber: pageIndex + 1,
      pageCount: pageCount,
    );
  }

  Widget _buildPageLeaf(
    _NativeChapter chapter,
    _ReaderPageData page, {
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
    required String layoutFingerprint,
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    final metadata = _nativePageMetadata(
      chapter,
      page,
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      pageCount: pageCount,
      layoutFingerprint: layoutFingerprint,
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
          _effectiveTopMargin,
          _horizontalMargin,
          _effectiveBottomMargin,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: readerMaxTextContentWidth,
            ),
            child: SizedBox.expand(
              child: _buildPage(
                chapter,
                page,
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpread({required Widget left, Widget? right}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: left),
        _buildSpreadGutter(),
        Expanded(child: right ?? const SizedBox.expand()),
      ],
    );
  }

  Widget _buildSpreadGutter() {
    final colors = _readerThemeData.colorScheme;
    return SizedBox(
      width: _spreadGutter,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: colors.outlineVariant.withValues(alpha: 0.24),
      ),
    );
  }
}
