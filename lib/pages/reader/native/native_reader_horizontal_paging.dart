part of 'native_reader_page.dart';

class _HorizontalPageIndexMap {
  static const _reserve = 1 << 16;
  static const _pagesPerChapterReserve = 64;

  int origin = 0;

  void reset(int chapterIndex) {
    origin = _reserve + chapterIndex * _pagesPerChapterReserve;
  }

  int controllerPageCount(int localPageCount, {int? originOverride}) =>
      (originOverride ?? origin) + localPageCount;

  int bookPageIndex(
    int controllerIndex, {
    required bool usesTwoPageLayout,
    int? originOverride,
  }) {
    final localControllerIndex = controllerIndex - (originOverride ?? origin);
    if (localControllerIndex < 0) return -1;
    return usesTwoPageLayout ? localControllerIndex * 2 : localControllerIndex;
  }
}

extension _NativeReaderHorizontalPaging on _NativeReaderPageState {
  void _resetHorizontalPagingWindow(int chapterIndex, {int? chapterCount}) {
    _horizontalFirstChapter = math.max(0, chapterIndex - 1);
    _horizontalLastChapter = chapterCount == null || chapterCount <= 0
        ? chapterIndex + 2
        : math.min(chapterCount - 1, chapterIndex + 2);
    _horizontalPageIndexMap.reset(chapterIndex);
    _horizontalBackwardExpansionPending = false;
    _horizontalBackwardExpansionWarmPending = false;
    _horizontalForwardExpansionPending = false;
    _horizontalForwardContractionPending = false;
    _horizontalPageTurnTracker.clear();
    _pendingHorizontalForwardBoundary = null;
  }

  List<_BookPageRef> _bookPagesFor(
    List<_NativeChapter> chapters,
    int firstChapter,
    int lastChapter,
    Size size,
    TextDirection direction,
    TextScaler textScaler, {
    required bool padOddChapters,
  }) {
    final result = <_BookPageRef>[];
    final safeFirst = firstChapter.clamp(0, chapters.length - 1);
    final safeLast = lastChapter.clamp(safeFirst, chapters.length - 1);
    var hasForwardBoundary = false;
    for (
      var chapterIndex = safeFirst;
      chapterIndex <= safeLast;
      chapterIndex++
    ) {
      final chapter = chapters[chapterIndex];
      final layoutFingerprint = _paginationFingerprintFor(
        chapterIndex,
        size,
        direction,
        textScaler,
      );
      // 打开动画播完前，相邻章节若未命中分页缓存，也转入预热队列，
      // 避免整章排版挤在飞行帧里同步执行。
      if (chapterIndex != _chapterIndex &&
          (!chapter.hasLoadedText ||
              (!_openingFlightSettledNow &&
                  !_pageCache.containsKey(layoutFingerprint)))) {
        _scheduleBookPaginationWarm(
          chapters,
          chapterIndex,
          size,
          direction,
          textScaler,
        );
        if (_pageMode == NativePageMode.horizontalSlide &&
            chapterIndex > _chapterIndex) {
          result.add(
            _BookPageRef.forwardBoundary(
              chapterIndex: chapterIndex,
              layoutFingerprint: layoutFingerprint,
            ),
          );
          hasForwardBoundary = true;
          break;
        }
        continue;
      }
      final chapterPages = _pagesFor(
        chapter,
        chapterIndex,
        size,
        direction,
        textScaler,
      );
      for (var pageIndex = 0; pageIndex < chapterPages.length; pageIndex++) {
        result.add(
          _BookPageRef(
            chapterIndex: chapterIndex,
            pageIndex: pageIndex,
            pageCount: chapterPages.length,
            layoutFingerprint: layoutFingerprint,
            content: chapterPages[pageIndex],
          ),
        );
      }
      if (padOddChapters && chapterPages.length.isOdd) {
        result.add(
          _BookPageRef(
            chapterIndex: chapterIndex,
            pageIndex: chapterPages.length,
            pageCount: chapterPages.length,
            layoutFingerprint: layoutFingerprint,
            content: chapterPages.last,
            isBlank: true,
          ),
        );
      }
    }
    if (_pageMode == NativePageMode.horizontalSlide &&
        !hasForwardBoundary &&
        safeLast < chapters.length - 1) {
      final boundaryChapterIndex = safeLast + 1;
      final boundaryFingerprint = _paginationFingerprintFor(
        boundaryChapterIndex,
        size,
        direction,
        textScaler,
      );
      _scheduleBookPaginationWarm(
        chapters,
        boundaryChapterIndex,
        size,
        direction,
        textScaler,
      );
      result.add(
        _BookPageRef.forwardBoundary(
          chapterIndex: boundaryChapterIndex,
          layoutFingerprint: boundaryFingerprint,
        ),
      );
    }
    return result;
  }

  int _horizontalControllerPageCount(
    List<_BookPageRef> bookPages, {
    required bool usesTwoPageLayout,
    int? controllerOrigin,
  }) {
    final localPageCount = usesTwoPageLayout
        ? (bookPages.length + 1) ~/ 2
        : bookPages.length;
    return _horizontalPageIndexMap.controllerPageCount(
      localPageCount,
      originOverride: controllerOrigin,
    );
  }

  int _horizontalBookPageIndex(
    int controllerIndex, {
    required bool usesTwoPageLayout,
    int? controllerOrigin,
  }) {
    return _horizontalPageIndexMap.bookPageIndex(
      controllerIndex,
      usesTwoPageLayout: usesTwoPageLayout,
      originOverride: controllerOrigin,
    );
  }

  Widget _buildHorizontalVirtualPage(
    List<_BookPageRef> bookPages,
    int controllerIndex, {
    required bool usesTwoPageLayout,
  }) {
    final layoutFingerprint = bookPages.isEmpty
        ? _layoutSignature
        : bookPages.first.layoutFingerprint;
    final blank = _buildBlankPageLeaf(
      pageIdentity: 'horizontal-virtual-$controllerIndex',
      layoutFingerprint: layoutFingerprint,
      topInformationLayout: ReaderTopInformationLayout.full,
    );
    if (!usesTwoPageLayout) return blank;
    return _buildSpread(
      left: blank,
      right: _buildBlankPageLeaf(
        pageIdentity: 'horizontal-virtual-$controllerIndex-right',
        layoutFingerprint: layoutFingerprint,
        topInformationLayout: ReaderTopInformationLayout.full,
      ),
    );
  }

  Widget _buildHorizontalPageLeaf(
    List<_NativeChapter> chapters,
    _BookPageRef page, {
    ReaderPageNumberPlacement pageNumberPlacement =
        ReaderPageNumberPlacement.bottomRight,
    ReaderTopInformationLayout topInformationLayout =
        ReaderTopInformationLayout.full,
  }) {
    if (page.isForwardBoundary) {
      return _buildBlankPageLeaf(
        pageIdentity: 'horizontal-forward-boundary-${page.chapterIndex}',
        layoutFingerprint: page.layoutFingerprint,
        topInformationLayout: topInformationLayout,
      );
    }
    return _buildBookPageLeaf(
      chapters,
      page,
      pageNumberPlacement: pageNumberPlacement,
      topInformationLayout: topInformationLayout,
    );
  }

  Future<void> _precacheBookPageImages(
    BuildContext context,
    List<_NativeChapter> chapters,
    Iterable<_BookPageRef> pages,
  ) async {
    final images = <ImageProvider>{};
    for (final page in pages) {
      if (page.isBlank || page.isForwardBoundary) continue;
      final imageIndex = page.content.imageBlockIndex;
      if (imageIndex == null) continue;
      final image =
          chapters[page.chapterIndex].blocks[imageIndex].imageProvider;
      if (image != null) images.add(image);
    }
    await Future.wait(
      images.map((image) {
        final testPrecacher = widget.imagePrecacher;
        return testPrecacher == null
            ? precacheImage(image, context)
            : testPrecacher(image);
      }),
    );
  }

  void _scheduleNearbyBookPageImages(
    List<_NativeChapter> chapters,
    List<_BookPageRef> bookPages, {
    required bool usesTwoPageLayout,
  }) {
    if (bookPages.isEmpty) return;
    final currentIndex = bookPages.indexWhere(
      (page) =>
          !page.isBlank &&
          !page.isForwardBoundary &&
          page.chapterIndex == _chapterIndex &&
          page.pageIndex == _pageIndex,
    );
    if (currentIndex < 0) return;

    final currentStart = usesTwoPageLayout
        ? _spreadStartForPage(currentIndex)
        : currentIndex;
    final first = math.max(0, currentStart - (usesTwoPageLayout ? 2 : 1));
    final last = math.min(
      bookPages.length,
      currentStart + (usesTwoPageLayout ? 4 : 3),
    );
    final imagePages = bookPages
        .getRange(first, last)
        .where((page) {
          if (page.isBlank || page.isForwardBoundary) return false;
          return page.content.imageBlockIndex != null;
        })
        .toList(growable: false);
    _scheduleBookPageImageBatch(chapters, imagePages);
  }

  void _scheduleNearbyChapterPageImages(
    List<_NativeChapter> chapters,
    List<_ReaderPageData> pages, {
    required String layoutFingerprint,
  }) {
    final first = math.max(0, _pageIndex - 1);
    final last = math.min(pages.length, _pageIndex + 3);
    final imagePages = <_BookPageRef>[
      for (var pageIndex = first; pageIndex < last; pageIndex++)
        if (pages[pageIndex].imageBlockIndex != null)
          _BookPageRef(
            chapterIndex: _chapterIndex,
            pageIndex: pageIndex,
            pageCount: pages.length,
            layoutFingerprint: layoutFingerprint,
            content: pages[pageIndex],
          ),
    ];
    _scheduleBookPageImageBatch(chapters, imagePages);
  }

  void _scheduleBookPageImageBatch(
    List<_NativeChapter> chapters,
    List<_BookPageRef> imagePages,
  ) {
    if (imagePages.isEmpty) return;

    final key = imagePages
        .map(
          (page) =>
              '${page.layoutFingerprint}:${page.chapterIndex}:'
              '${page.pageIndex}:${page.content.imageBlockIndex}',
        )
        .join('|');
    if (_scheduledImagePrecacheKey == key) return;
    _scheduledImagePrecacheKey = key;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledImagePrecacheKey != key) return;
      unawaited(
        _precacheBookPageImages(context, chapters, imagePages).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint('precache native reader image failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }),
      );
    });
  }

  Widget _buildHorizontalSlideSurface(
    List<_NativeChapter> chapters,
    List<_BookPageRef> bookPages,
    Size viewport, {
    required bool usesTwoPageLayout,
  }) {
    // A window update mutates the shared origin before Flutter rebuilds the
    // PageView. Keep every callback in this delegate paired with the origin
    // and page list from the same build so an in-flight gesture cannot map an
    // old child list through a newer origin.
    final controllerOrigin = _horizontalPageIndexMap.origin;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        _commitHorizontalWindowMaintenanceWhenIdle(
          bookPages,
          chapters,
          _paginationSize(viewport, usesTwoPageLayout),
          Directionality.of(context),
          readerBodyTextScaler,
          usesTwoPageLayout: usesTwoPageLayout,
        );
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        physics: _annotationInteractionActive
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: _horizontalControllerPageCount(
          bookPages,
          usesTwoPageLayout: usesTwoPageLayout,
          controllerOrigin: controllerOrigin,
        ),
        onPageChanged: (index) {
          final bookPageIndex = _horizontalBookPageIndex(
            index,
            usesTwoPageLayout: usesTwoPageLayout,
            controllerOrigin: controllerOrigin,
          );
          if (bookPageIndex < 0 || bookPageIndex >= bookPages.length) {
            debugPrint(
              '[reader-horizontal] ignore virtual pageChanged '
              'index=$index origin=${_horizontalPageIndexMap.origin}',
            );
            return;
          }
          final page = bookPages[bookPageIndex];
          if (page.isForwardBoundary) {
            _onHorizontalForwardBoundaryChanged(index, page);
            return;
          }
          _pendingHorizontalForwardBoundary = null;
          _onBookPageChanged(bookPageIndex, bookPages, chapters);
        },
        itemBuilder: (context, index) {
          final bookPageIndex = _horizontalBookPageIndex(
            index,
            usesTwoPageLayout: usesTwoPageLayout,
            controllerOrigin: controllerOrigin,
          );
          if (bookPageIndex < 0 || bookPageIndex >= bookPages.length) {
            return _buildHorizontalVirtualPage(
              bookPages,
              index,
              usesTwoPageLayout: usesTwoPageLayout,
            );
          }
          if (!usesTwoPageLayout) {
            return _buildHorizontalPageLeaf(chapters, bookPages[bookPageIndex]);
          }
          return _buildSpread(
            left: _buildHorizontalPageLeaf(
              chapters,
              bookPages[bookPageIndex],
              pageNumberPlacement: ReaderPageNumberPlacement.bottomLeft,
              topInformationLayout: ReaderTopInformationLayout.spreadLeft,
            ),
            right: bookPageIndex + 1 < bookPages.length
                ? _buildHorizontalPageLeaf(
                    chapters,
                    bookPages[bookPageIndex + 1],
                    pageNumberPlacement: ReaderPageNumberPlacement.bottomRight,
                    topInformationLayout:
                        ReaderTopInformationLayout.spreadRight,
                  )
                : null,
          );
        },
      ),
    );
  }
}
