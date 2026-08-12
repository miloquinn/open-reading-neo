part of 'native_reader_page.dart';

extension _NativeReaderShell on _NativeReaderPageState {
  Widget _buildPage(
    _NativeChapter chapter,
    _ReaderPageData page, {
    required int chapterIndex,
    required int pageIndex,
  }) {
    final imageIndex = page.imageBlockIndex;
    if (imageIndex == null) {
      final body = _buildStyledReaderText(
        chapter,
        page,
        chapterIndex: chapterIndex,
        pageIndex: pageIndex,
      );
      if (!page.showsInlineChapterTitle) return body;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReaderInlineChapterTitle(
            title: chapter.title,
            bodyStyle: _readerTextStyle,
          ),
          const SizedBox(height: ReaderInlineChapterTitle.spacingAfter),
          Expanded(child: body),
        ],
      );
    }
    final imageBlock = chapter.blocks[imageIndex];
    final imageProvider = imageBlock.imageProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (imageProvider != null)
          Expanded(
            flex: _imagePageImageFlex,
            child: Image(
              image: imageProvider,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
        if (imageProvider != null && page.text.isNotEmpty)
          const SizedBox(height: _imagePageGap),
        if (page.text.isNotEmpty)
          Expanded(
            flex: _imagePageTextFlex,
            child: _buildStyledReaderText(
              chapter,
              page,
              chapterIndex: chapterIndex,
              pageIndex: pageIndex,
            ),
          ),
      ],
    );
  }

  Widget _buildReaderContent(
    List<_NativeChapter> chapters,
    _NativeChapter chapter,
    List<_ReaderPageData> pages,
    List<_BookPageRef> bookPages,
    bool usesTwoPageLayout,
    String layoutFingerprint,
    Size viewport,
  ) {
    if (_pageMode == NativePageMode.verticalScroll) {
      _visibleChapters = chapters;
      _verticalViewportSize = viewport;
      _verticalTextDirection = Directionality.of(context);
      _verticalTextScaler = readerBodyTextScaler;
      if (!_scrollByChapter) {
        return _buildVerticalReadingWindow(
          _buildVerticalBook(chapters, viewport),
        );
      }
      return _buildVerticalReadingWindow(
        _buildVerticalPageList(chapter, pages, viewport),
      );
    }
    if (_pageMode == NativePageMode.instantPage) {
      _scheduleNearbyChapterPageImages(
        chapters,
        pages,
        layoutFingerprint: layoutFingerprint,
      );
    } else {
      _scheduleNearbyBookPageImages(
        chapters,
        bookPages,
        usesTwoPageLayout: usesTwoPageLayout,
      );
    }
    if (_pageMode == NativePageMode.horizontalSlide) {
      return _buildHorizontalSlideSurface(
        chapters,
        bookPages,
        viewport,
        usesTwoPageLayout: usesTwoPageLayout,
      );
    }
    if (_pageMode == NativePageMode.coverSlide) {
      final currentIndex = bookPages.indexWhere(
        (page) =>
            page.chapterIndex == _chapterIndex && page.pageIndex == _pageIndex,
      );
      if (currentIndex < 0) {
        return _buildPageLeaf(
          chapter,
          pages[_pageIndex],
          chapterIndex: _chapterIndex,
          pageIndex: _pageIndex,
          pageCount: pages.length,
          layoutFingerprint: layoutFingerprint,
        );
      }
      final paginationSize = _paginationSize(viewport, usesTwoPageLayout);
      final textDirection = Directionality.of(context);
      void commitTurn(int targetIndex) {
        _onBookPageChanged(targetIndex, bookPages, chapters);
        _commitHorizontalBackwardExpansion(
          chapters,
          paginationSize,
          textDirection,
          readerBodyTextScaler,
          usesTwoPageLayout: usesTwoPageLayout,
        );
      }

      final coverKey = ValueKey(
        'native-cover:${widget.book.id ?? _bookCacheKey}',
      );
      if (usesTwoPageLayout) {
        final spreadStart = _spreadStartForPage(currentIndex);
        final hasForward = spreadStart + 2 < bookPages.length;
        final hasBackward = spreadStart >= 2;
        return ReaderCoverPageTurn(
          key: coverKey,
          controller: _coverPageTurnController,
          currentPage: _buildCoverSpreadSnapshot(
            chapters,
            bookPages,
            spreadStart,
          ),
          forwardPage: hasForward
              ? _buildCoverSpreadSnapshot(chapters, bookPages, spreadStart + 2)
              : null,
          backwardPage: hasBackward
              ? _buildCoverSpreadSnapshot(chapters, bookPages, spreadStart - 2)
              : null,
          onTurnForward: () => commitTurn(spreadStart + 2),
          onTurnBackward: () => commitTurn(spreadStart - 2),
          paperColor: _readerTheme.background,
        );
      }
      final current = bookPages[currentIndex];
      final forward = currentIndex + 1 < bookPages.length
          ? bookPages[currentIndex + 1]
          : null;
      final backward = currentIndex > 0 ? bookPages[currentIndex - 1] : null;
      return ReaderCoverPageTurn(
        key: coverKey,
        controller: _coverPageTurnController,
        currentPage: _buildBookPageSnapshot(chapters, current),
        forwardPage: forward != null
            ? _buildBookPageSnapshot(chapters, forward)
            : null,
        backwardPage: backward != null
            ? _buildBookPageSnapshot(chapters, backward)
            : null,
        onTurnForward: () => commitTurn(currentIndex + 1),
        onTurnBackward: () => commitTurn(currentIndex - 1),
        paperColor: _readerTheme.background,
      );
    }
    if (_pageMode == NativePageMode.pageCurl) {
      final currentIndex = bookPages.indexWhere(
        (page) =>
            page.chapterIndex == _chapterIndex && page.pageIndex == _pageIndex,
      );
      if (currentIndex < 0) {
        return _buildPageLeaf(
          chapter,
          pages[_pageIndex],
          chapterIndex: _chapterIndex,
          pageIndex: _pageIndex,
          pageCount: pages.length,
          layoutFingerprint: layoutFingerprint,
        );
      }
      if (usesTwoPageLayout) {
        return _buildPageCurlSpread(context, chapters, bookPages, currentIndex);
      }
      final current = bookPages[currentIndex];
      final forward = currentIndex + 1 < bookPages.length
          ? bookPages[currentIndex + 1]
          : null;
      final backward = currentIndex > 0 ? bookPages[currentIndex - 1] : null;
      final expandsEpubWindowAfterCurl =
          widget.book.format.toLowerCase() == 'epub';
      void commitCurlTurn(int targetIndex) {
        _onBookPageChanged(targetIndex, bookPages, chapters);
        _commitHorizontalBackwardExpansion(
          chapters,
          _paginationSize(viewport, usesTwoPageLayout),
          Directionality.of(context),
          readerBodyTextScaler,
          usesTwoPageLayout: usesTwoPageLayout,
        );
      }

      return ReaderShaderPageCurl(
        key: ValueKey('native-curl:${widget.book.id ?? _bookCacheKey}'),
        controller: _pageCurlController,
        currentPage: _buildBookPageSnapshot(chapters, current),
        forwardPage: forward != null
            ? _buildBookPageSnapshot(chapters, forward)
            : null,
        backwardPage: backward != null
            ? _buildBookPageSnapshot(chapters, backward)
            : null,
        preparePages: () => _precacheBookPageImages(context, chapters, [
          current,
          ?forward,
          ?backward,
        ]),
        onTurnForward: () => expandsEpubWindowAfterCurl
            ? commitCurlTurn(currentIndex + 1)
            : _onBookPageChanged(currentIndex + 1, bookPages, chapters),
        onTurnBackward: () => expandsEpubWindowAfterCurl
            ? commitCurlTurn(currentIndex - 1)
            : _onBookPageChanged(currentIndex - 1, bookPages, chapters),
        paperColor: _readerTheme.background,
      );
    }
    if (usesTwoPageLayout) {
      final spreadStart = _spreadStartForPage(_pageIndex);
      return _buildSpread(
        left: _buildPageLeaf(
          chapter,
          pages[spreadStart],
          chapterIndex: _chapterIndex,
          pageIndex: spreadStart,
          pageCount: pages.length,
          layoutFingerprint: layoutFingerprint,
          pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
          topInformationLayout: ReaderTopInformationLayout.spreadLeft,
        ),
        right: spreadStart + 1 < pages.length
            ? _buildPageLeaf(
                chapter,
                pages[spreadStart + 1],
                chapterIndex: _chapterIndex,
                pageIndex: spreadStart + 1,
                pageCount: pages.length,
                layoutFingerprint: layoutFingerprint,
                pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
                topInformationLayout: ReaderTopInformationLayout.spreadRight,
              )
            : null,
      );
    }
    return _buildPageLeaf(
      chapter,
      pages[_pageIndex],
      chapterIndex: _chapterIndex,
      pageIndex: _pageIndex,
      pageCount: pages.length,
      layoutFingerprint: layoutFingerprint,
    );
  }

  String _readerStatus(List<_ReaderPageData> pages, int chapterCount) {
    final statusPages =
        _pageMode == NativePageMode.verticalScroll &&
            _visibleContinuousParts.isNotEmpty
        ? _visibleContinuousParts.length
        : pages.length;
    final page = _pageIndex + 1;
    return context.l10n.readerStatusPaged(
      _chapterIndex + 1,
      chapterCount,
      page.clamp(1, statusPages),
      statusPages,
    );
  }

  Widget _buildReaderStatusText({
    required List<_ReaderPageData> pages,
    required int chapterCount,
    required TextStyle? style,
    Key? key,
  }) {
    return ValueListenableBuilder<double>(
      valueListenable: _verticalScrollProgress,
      builder: (context, _, _) => Text(
        _readerStatus(pages, chapterCount),
        key: key,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }

  Widget _buildOpeningScaffold({required Key key, required bool showLoader}) {
    return Scaffold(
      key: key,
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: ReaderThemeBackground(
        palette: _readerTheme,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: showLoader
                    ? ReaderOpeningLoader(palette: _readerTheme)
                    : const SizedBox.expand(),
              ),
            ),
            ReaderChromeOverlay(
              palette: _readerTheme,
              visible: _controlsVisible,
              title: widget.book.title,
              statusBottom: _readerSafeArea.pageNumberBottom,
              showViewportStatus: false,
              statusBuilder: (_, _, _) => const SizedBox.shrink(),
              onBack: () => unawaited(_exitReader()),
              onBookmark: null,
              onTableOfContents: null,
              onSettings: _readerSettingsLoaded ? _showReadingSettings : () {},
              backTooltip: MaterialLocalizations.of(context).backButtonTooltip,
              bookmarkTooltip: context.l10n.readerAddBookmark,
              tableOfContentsTooltip: context.l10n.readerToolbarTOC,
              settingsTooltip: context.l10n.readingSettings,
              bookmarked: false,
              showSettingsAction: false,
              topKey: const ValueKey('native-reader-opening-top-controls'),
              bottomKey: const ValueKey(
                'native-reader-opening-bottom-controls',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReaderMessageScaffold({
    required Key key,
    required String message,
    bool showAppBar = false,
  }) {
    return Scaffold(
      key: key,
      backgroundColor: Colors.transparent,
      body: ReaderThemeBackground(
        palette: _readerTheme,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showAppBar) ...[
                        Text(
                          widget.book.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _readerTheme.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _readerTheme.text, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
              if (showAppBar)
                Positioned(
                  left: 20,
                  top: 10,
                  child: Material(
                    color: _readerTheme.surface.withValues(alpha: 0.88),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => unawaited(_exitReader()),
                      icon: Icon(
                        Icons.arrow_back_rounded,
                        color: _readerTheme.text,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _scheduleOpeningContentReady() {
    if (_openingContentReadyScheduled) return;
    _openingContentReadyScheduled = true;
    _openingLoaderTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) BookOpenTransition.markReaderContentReady(context);
    });
  }
}
