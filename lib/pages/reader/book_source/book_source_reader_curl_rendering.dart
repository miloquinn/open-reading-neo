part of 'book_source_reader_page.dart';

extension _BookSourceReaderCurlRendering on _BookSourceReaderPageState {
  Widget _buildCurlReader({required bool usesTwoPageLayout}) =>
      usesTwoPageLayout ? _buildCurlSpreadReader() : _buildSingleCurlReader();

  ({
    ReaderPageSnapshot current,
    ReaderPageSnapshot? forward,
    ReaderPageSnapshot? backward,
  })
  _singlePageTurnSnapshots(Size viewport) {
    final hasForward =
        _pageIndex + 1 < _pageCount || _chapterIndex + 1 < _chapters.length;
    final hasBackward = _pageIndex > 0 || _chapterIndex > 0;
    final forwardData = _pageIndex + 1 < _pageCount
        ? null
        : _chapterIndex + 1 < _chapters.length
        ? _adjacentPageData(
            _chapterIndex + 1,
            viewport,
            selectPageIndex: (_) => 0,
          )
        : null;
    final backwardData = _pageIndex > 0
        ? null
        : _chapterIndex > 0
        ? _adjacentPageData(
            _chapterIndex - 1,
            viewport,
            selectPageIndex: (pageCount) => pageCount - 1,
          )
        : null;
    final currentSnapshot = _buildPageSnapshot(
      _paginatedPages[_pageIndex],
      pageIndex: _pageIndex,
      pageCount: _pageCount,
      layoutFingerprint: _paginationKey!,
    );
    final forwardSnapshot = !hasForward
        ? null
        : _pageIndex + 1 < _pageCount
        ? _buildPageSnapshot(
            _paginatedPages[_pageIndex + 1],
            pageIndex: _pageIndex + 1,
            pageCount: _pageCount,
            layoutFingerprint: _paginationKey!,
          )
        : forwardData == null
        ? _buildBoundarySnapshot(forward: true)
        : _buildPageSnapshot(
            forwardData.page,
            pageIndex: forwardData.pageIndex,
            pageCount: forwardData.pageCount,
            layoutFingerprint: forwardData.layoutFingerprint,
            chapterIndex: _chapterIndex + 1,
            chapterContent: forwardData.content,
          );
    final backwardSnapshot = !hasBackward
        ? null
        : _pageIndex > 0
        ? _buildPageSnapshot(
            _paginatedPages[_pageIndex - 1],
            pageIndex: _pageIndex - 1,
            pageCount: _pageCount,
            layoutFingerprint: _paginationKey!,
          )
        : backwardData == null
        ? _buildBoundarySnapshot(forward: false)
        : _buildPageSnapshot(
            backwardData.page,
            pageIndex: backwardData.pageIndex,
            pageCount: backwardData.pageCount,
            layoutFingerprint: backwardData.layoutFingerprint,
            chapterIndex: _chapterIndex - 1,
            chapterContent: backwardData.content,
          );
    return (
      current: currentSnapshot,
      forward: forwardSnapshot,
      backward: backwardSnapshot,
    );
  }

  Widget _buildSingleCurlReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final snapshots = _singlePageTurnSnapshots(constraints.biggest);
        return ReaderShaderPageCurl(
          key: ValueKey('source-curl:${widget.source.id}:${widget.book.id}'),
          controller: _pageCurlController,
          paperColor: _readerTheme.background,
          currentPage: snapshots.current,
          forwardPage: snapshots.forward,
          backwardPage: snapshots.backward,
          onTurnForward: _turnForward,
          onTurnBackward: _turnBackward,
        );
      },
    );
  }

  Widget _buildCoverReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final snapshots = _singlePageTurnSnapshots(constraints.biggest);
        return ReaderCoverPageTurn(
          key: ValueKey('source-cover:${widget.source.id}:${widget.book.id}'),
          controller: _coverPageTurnController,
          paperColor: _readerTheme.background,
          currentPage: snapshots.current,
          forwardPage: snapshots.forward,
          backwardPage: snapshots.backward,
          onTurnForward: _turnForward,
          onTurnBackward: _turnBackward,
        );
      },
    );
  }

  Widget _buildCurlSpreadReader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spreadStart = _spreadStartForPage(_pageIndex);
        final nextSpreadStart = spreadStart + 2;
        final hasPrevious = spreadStart >= 2 || _chapterIndex > 0;
        final hasNext =
            nextSpreadStart < _pageCount ||
            _chapterIndex + 1 < _chapters.length;
        final adjacentViewport = _paginationViewport(constraints.biggest, true);
        final previousChapterIndex = _chapterIndex - 1;
        final nextChapterIndex = _chapterIndex + 1;
        final usesPreviousChapter =
            spreadStart == 0 && previousChapterIndex >= 0;
        final usesNextChapter =
            nextSpreadStart >= _pageCount &&
            nextChapterIndex < _chapters.length;
        final previousChapterCached =
            usesPreviousChapter &&
            _prefetchedContent[previousChapterIndex] != null;
        final nextChapterCached =
            usesNextChapter && _prefetchedContent[nextChapterIndex] != null;
        final previousChapterLeftData = previousChapterCached
            ? _adjacentPageData(
                previousChapterIndex,
                adjacentViewport,
                selectPageIndex: (pageCount) =>
                    _spreadStartForPage(pageCount - 1),
              )
            : null;
        final previousChapterRightData = previousChapterCached
            ? _adjacentPageData(
                previousChapterIndex,
                adjacentViewport,
                selectPageIndex: (pageCount) =>
                    _spreadStartForPage(pageCount - 1) + 1,
              )
            : null;
        final nextChapterLeftData = nextChapterCached
            ? _adjacentPageData(
                nextChapterIndex,
                adjacentViewport,
                selectPageIndex: (_) => 0,
              )
            : null;
        final nextChapterRightData = nextChapterCached
            ? _adjacentPageData(
                nextChapterIndex,
                adjacentViewport,
                selectPageIndex: (_) => 1,
              )
            : null;

        final currentLeft = _buildPageSnapshot(
          _paginatedPages[spreadStart],
          pageIndex: spreadStart,
          pageCount: _pageCount,
          layoutFingerprint: _paginationKey!,
          pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
          topInformationLayout: ReaderTopInformationLayout.spreadLeft,
        );
        final currentRight = spreadStart + 1 < _pageCount
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart + 1],
                pageIndex: spreadStart + 1,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : _buildBlankSourceSnapshot(
                'current-$spreadStart-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );

        final previousLeft = !hasPrevious
            ? null
            : spreadStart >= 2
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart - 2],
                pageIndex: spreadStart - 2,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              )
            : !previousChapterCached
            ? _buildBoundarySnapshot(
                forward: false,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                slotIdentity: 'spread-left',
              )
            : previousChapterLeftData == null
            ? _buildBlankSourceSnapshot(
                'previous-chapter-$previousChapterIndex-left',
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                chapterTitle: _chapters[previousChapterIndex].title,
              )
            : _buildPageSnapshot(
                previousChapterLeftData.page,
                pageIndex: previousChapterLeftData.pageIndex,
                pageCount: previousChapterLeftData.pageCount,
                layoutFingerprint: previousChapterLeftData.layoutFingerprint,
                chapterIndex: previousChapterIndex,
                chapterContent: previousChapterLeftData.content,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              );
        final previousRight = !hasPrevious
            ? null
            : spreadStart >= 2
            ? _buildPageSnapshot(
                _paginatedPages[spreadStart - 1],
                pageIndex: spreadStart - 1,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : !previousChapterCached
            ? _buildBoundarySnapshot(
                forward: false,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                slotIdentity: 'spread-right',
              )
            : previousChapterRightData == null
            ? _buildBlankSourceSnapshot(
                'previous-chapter-$previousChapterIndex-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                chapterTitle: _chapters[previousChapterIndex].title,
              )
            : _buildPageSnapshot(
                previousChapterRightData.page,
                pageIndex: previousChapterRightData.pageIndex,
                pageCount: previousChapterRightData.pageCount,
                layoutFingerprint: previousChapterRightData.layoutFingerprint,
                chapterIndex: previousChapterIndex,
                chapterContent: previousChapterRightData.content,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );
        final nextLeft = !hasNext
            ? null
            : nextSpreadStart < _pageCount
            ? _buildPageSnapshot(
                _paginatedPages[nextSpreadStart],
                pageIndex: nextSpreadStart,
                pageCount: _pageCount,
                layoutFingerprint: _paginationKey!,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              )
            : !nextChapterCached
            ? _buildBoundarySnapshot(
                forward: true,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                slotIdentity: 'spread-left',
              )
            : nextChapterLeftData == null
            ? _buildBlankSourceSnapshot(
                'next-chapter-$nextChapterIndex-left',
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
                chapterTitle: _chapters[nextChapterIndex].title,
              )
            : _buildPageSnapshot(
                nextChapterLeftData.page,
                pageIndex: nextChapterLeftData.pageIndex,
                pageCount: nextChapterLeftData.pageCount,
                layoutFingerprint: nextChapterLeftData.layoutFingerprint,
                chapterIndex: nextChapterIndex,
                chapterContent: nextChapterLeftData.content,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
                topInformationLayout: ReaderTopInformationLayout.spreadLeft,
              );
        final nextRight = !hasNext
            ? null
            : nextSpreadStart < _pageCount
            ? nextSpreadStart + 1 < _pageCount
                  ? _buildPageSnapshot(
                      _paginatedPages[nextSpreadStart + 1],
                      pageIndex: nextSpreadStart + 1,
                      pageCount: _pageCount,
                      layoutFingerprint: _paginationKey!,
                      topInformationLayout:
                          ReaderTopInformationLayout.spreadRight,
                    )
                  : _buildBlankSourceSnapshot(
                      'next-$nextSpreadStart-right',
                      topInformationLayout:
                          ReaderTopInformationLayout.spreadRight,
                    )
            : !nextChapterCached
            ? _buildBoundarySnapshot(
                forward: true,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
                slotIdentity: 'spread-right',
              )
            : nextChapterRightData == null
            ? _buildBlankSourceSnapshot(
                'next-chapter-$nextChapterIndex-right',
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : _buildPageSnapshot(
                nextChapterRightData.page,
                pageIndex: nextChapterRightData.pageIndex,
                pageCount: nextChapterRightData.pageCount,
                layoutFingerprint: nextChapterRightData.layoutFingerprint,
                chapterIndex: nextChapterIndex,
                chapterContent: nextChapterRightData.content,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              );

        final left = ReaderShaderPageCurl(
          key: ValueKey(
            'source-spread-curl-left:${widget.source.id}:${widget.book.id}',
          ),
          controller: _spreadBackwardPageCurlController,
          coordinator: _spreadPageCurlCoordinator,
          edgeDragOnly: true,
          bindingEdge: ReaderPageBindingEdge.right,
          paperColor: _readerTheme.background,
          currentPage: currentLeft,
          backwardPage: previousLeft,
          outgoingBackPage: previousRight,
          onTurnForward: () {},
          onTurnBackward: _turnBackward,
        );
        final right = ReaderShaderPageCurl(
          key: ValueKey(
            'source-spread-curl-right:${widget.source.id}:${widget.book.id}',
          ),
          controller: _spreadForwardPageCurlController,
          coordinator: _spreadPageCurlCoordinator,
          edgeDragOnly: true,
          bindingEdge: ReaderPageBindingEdge.left,
          paperColor: _readerTheme.background,
          currentPage: currentRight,
          forwardPage: nextRight,
          outgoingBackPage: nextLeft,
          onTurnForward: _turnForward,
          onTurnBackward: () {},
        );

        return _buildSourceSpread(left: left, right: right);
      },
    );
  }

  ReaderPageSnapshot _buildBlankSourceSnapshot(
    String pageIdentity, {
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
    String chapterTitle = '',
  }) => ReaderPageSnapshot(
    key: ReaderPageSnapshotKey(
      pageIdentity:
          'source:${widget.source.id}:${widget.book.id}:'
          'blank:$pageIdentity',
      layoutFingerprint: _paginationKey ?? 'unpaginated',
      themeId: _readerTheme.cacheKey,
    ),
    contentRevision: _leafContentRevision,
    child: ReaderPaperPageLeaf(
      palette: _readerTheme,
      safeArea: _readerSafeArea,
      metadata: ReaderPaperPageMetadata(
        pageIdentity:
            'source:${widget.source.id}:${widget.book.id}:'
            'blank:$pageIdentity',
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
      child: const SizedBox.expand(),
    ),
  );

  Widget _buildSourceSpread({required Widget left, required Widget right}) {
    return ReaderPageCurlSpread(
      coordinator: _spreadPageCurlCoordinator,
      left: left,
      right: right,
      gutter: _buildSourceSpreadGutter(),
    );
  }

  Widget _buildSourceSpreadGutter() {
    final colors = _readerThemeData.colorScheme;
    return SizedBox(
      width: _bookSourceSpreadGutter,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: colors.outlineVariant.withValues(alpha: 0.24),
      ),
    );
  }
}
