part of 'native_reader_page.dart';

extension _NativeReaderHorizontalWindowMaintenance on _NativeReaderPageState {
  void _onHorizontalForwardBoundaryChanged(
    int controllerPage,
    _BookPageRef boundary,
  ) {
    _horizontalPageTurnTracker.clear();
    _pendingHorizontalForwardBoundary = _PendingHorizontalForwardBoundary(
      controllerPage: controllerPage,
      chapterIndex: boundary.chapterIndex,
    );
    if (boundary.chapterIndex > _horizontalLastChapter) {
      _horizontalForwardExpansionPending = true;
    }
    debugPrint(
      '[reader-horizontal] hold forward boundary '
      'controller=$controllerPage target=${boundary.chapterIndex}:0 '
      'window=$_horizontalFirstChapter..$_horizontalLastChapter '
      'generation=$_pageControllerGeneration',
    );
  }

  void _schedulePendingHorizontalForwardBoundaryCommit(
    List<_BookPageRef> bookPages,
    List<_NativeChapter> chapters, {
    required bool usesTwoPageLayout,
  }) {
    final pending = _pendingHorizontalForwardBoundary;
    if (pending == null) return;
    final bookPageIndex = _horizontalBookPageIndex(
      pending.controllerPage,
      usesTwoPageLayout: usesTwoPageLayout,
    );
    if (bookPageIndex < 0 || bookPageIndex >= bookPages.length) return;
    final page = bookPages[bookPageIndex];
    if (page.isForwardBoundary ||
        page.isBlank ||
        page.chapterIndex != pending.chapterIndex) {
      return;
    }

    final pageController = _pageController;
    final controllerGeneration = _pageControllerGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runWhenHorizontalControllerIsIdle(
        pageController,
        controllerGeneration,
        () {
          if (!mounted ||
              !identical(_pendingHorizontalForwardBoundary, pending) ||
              pageController == null ||
              !pageController.hasClients ||
              pageController.page?.round() != pending.controllerPage) {
            return;
          }
          _pendingHorizontalForwardBoundary = null;
          debugPrint(
            '[reader-horizontal] publish forward boundary '
            'controller=${pending.controllerPage} '
            'target=${page.chapterIndex}:${page.pageIndex} '
            'generation=$controllerGeneration',
          );
          _publishBookPageChanged(page, chapters);
          _commitHorizontalWindowMaintenanceWhenIdle(
            bookPages,
            chapters,
            _lastPaginationSize,
            Directionality.of(context),
            readerBodyTextScaler,
            usesTwoPageLayout: usesTwoPageLayout,
          );
        },
      );
    });
  }

  void _onBookPageChanged(
    int index,
    List<_BookPageRef> bookPages,
    List<_NativeChapter> chapters,
  ) {
    final page = bookPages[index];
    debugPrint(
      '[reader-horizontal] pageChanged index=$index '
      'target=${page.chapterIndex}:${page.pageIndex} '
      'controller=${_pageController?.page?.toStringAsFixed(2)} '
      'generation=$_pageControllerGeneration '
      'window=$_horizontalFirstChapter..$_horizontalLastChapter '
      'items=${bookPages.length}',
    );
    if (page.isBlank) return;
    final pageController = _pageController;
    final isActiveHorizontalTurn =
        _pageMode == NativePageMode.horizontalSlide &&
        pageController?.hasClients == true &&
        pageController!.position.isScrollingNotifier.value;
    if (isActiveHorizontalTurn) {
      _horizontalPageTurnTracker.record(
        page: page,
        position: ReaderPagePosition(
          chapterIndex: page.chapterIndex,
          pageIndex: page.pageIndex,
        ),
        committedPosition: ReaderPagePosition(
          chapterIndex: _chapterIndex,
          pageIndex: _pageIndex,
        ),
      );
      debugPrint(
        '[reader-horizontal] defer page state until idle '
        'target=${page.chapterIndex}:${page.pageIndex}',
      );
      return;
    }
    _publishBookPageChanged(page, chapters);
  }

  void _publishBookPageChanged(
    _BookPageRef page,
    List<_NativeChapter> chapters, {
    int pagesReadDelta = 0,
  }) {
    final movedForward =
        page.chapterIndex > _chapterIndex ||
        (page.chapterIndex == _chapterIndex && page.pageIndex > _pageIndex);
    final chapterChanged = page.chapterIndex != _chapterIndex;
    _sessionPagesRead += pagesReadDelta > 0
        ? pagesReadDelta
        : movedForward
        ? 1
        : 0;
    _setReaderState(() {
      _chapterIndex = page.chapterIndex;
      _pageIndex = page.pageIndex;
      _horizontalBackwardExpansionPending =
          page.chapterIndex <= _horizontalFirstChapter &&
          _horizontalFirstChapter > 0;
      if (page.chapterIndex > _horizontalFirstChapter + 1) {
        if (_pageMode == NativePageMode.horizontalSlide) {
          _horizontalForwardContractionPending = true;
        } else {
          _horizontalFirstChapter = page.chapterIndex - 1;
        }
      } else if (_pageMode == NativePageMode.horizontalSlide) {
        _horizontalForwardContractionPending = false;
      }
      final needsForwardExpansion =
          page.chapterIndex >= _horizontalLastChapter - 1 &&
          _horizontalLastChapter < chapters.length - 1;
      if (_pageMode == NativePageMode.horizontalSlide) {
        _horizontalForwardExpansionPending = needsForwardExpansion;
      } else if (needsForwardExpansion) {
        _horizontalLastChapter++;
      }
    });
    if (chapterChanged && widget.book.id != null) {
      unawaited(_queueBookProgress(widget.book.id!, page.chapterIndex));
    }
    _saveCanonicalProgress(
      chapters[page.chapterIndex],
      page.content,
      page.chapterIndex,
    );
  }

  void _publishPendingHorizontalPage(List<_NativeChapter> chapters) {
    final pending = _horizontalPageTurnTracker.take();
    if (pending == null) return;
    _publishBookPageChanged(
      pending.page,
      chapters,
      pagesReadDelta: pending.pagesReadDelta,
    );
  }

  int? _takeHorizontalForwardExpansion(List<_NativeChapter> chapters) {
    if (!_horizontalForwardExpansionPending) return null;
    _horizontalForwardExpansionPending = false;
    if (_horizontalLastChapter >= chapters.length - 1) return null;
    return _horizontalLastChapter + 1;
  }

  bool _commitHorizontalForwardExpansion(List<_NativeChapter> chapters) {
    final nextLastChapter = _takeHorizontalForwardExpansion(chapters);
    if (nextLastChapter == null) return false;
    final boundedLastChapter = math.min(nextLastChapter, _chapterIndex + 2);
    debugPrint(
      '[reader-horizontal] commit forward expansion '
      'window=$_horizontalFirstChapter..$boundedLastChapter '
      'controller=${_pageController?.page?.toStringAsFixed(2)}',
    );
    _setReaderState(() => _horizontalLastChapter = boundedLastChapter);
    return true;
  }

  bool _commitHorizontalForwardContraction(
    List<_BookPageRef> bookPages,
    List<_NativeChapter> chapters, {
    required bool usesTwoPageLayout,
  }) {
    if (!_horizontalForwardContractionPending ||
        _pageMode != NativePageMode.horizontalSlide) {
      return false;
    }
    final nextFirstChapter = math.max(0, _chapterIndex - 1);
    if (nextFirstChapter <= _horizontalFirstChapter) {
      _horizontalForwardContractionPending = false;
      return false;
    }
    final targetPage = bookPages.indexWhere(
      (page) =>
          !page.isBlank &&
          page.chapterIndex == _chapterIndex &&
          page.pageIndex == _pageIndex,
    );
    if (targetPage < 0) return false;
    final removedBookPages = bookPages
        .takeWhile((page) => page.chapterIndex < nextFirstChapter)
        .length;
    final localTargetPage = targetPage - removedBookPages;
    final removedControllerPages = usesTwoPageLayout
        ? removedBookPages ~/ 2
        : removedBookPages;
    final nextControllerPage = usesTwoPageLayout
        ? localTargetPage ~/ 2
        : localTargetPage;
    final previousControllerOrigin = _horizontalPageIndexMap.origin;
    final nextControllerOrigin =
        previousControllerOrigin + removedControllerPages;
    debugPrint(
      '[reader-horizontal] commit forward contraction '
      'target=$_chapterIndex:$_pageIndex '
      'window=$_horizontalFirstChapter..$_horizontalLastChapter '
      'nextFirst=$nextFirstChapter targetPage=$targetPage '
      'nextControllerPage=${nextControllerOrigin + nextControllerPage} '
      'origin=$previousControllerOrigin->$nextControllerOrigin '
      'items=${bookPages.length}',
    );
    _horizontalForwardContractionPending = false;
    final expandedLastChapter =
        _takeHorizontalForwardExpansion(chapters) ?? _horizontalLastChapter;
    final nextLastChapter = math.min(expandedLastChapter, _chapterIndex + 2);
    _setReaderState(() {
      _horizontalPageIndexMap.origin = nextControllerOrigin;
      _horizontalFirstChapter = nextFirstChapter;
      _horizontalLastChapter = math.max(nextFirstChapter, nextLastChapter);
    });
    return true;
  }

  bool _commitHorizontalBackwardExpansion(
    List<_NativeChapter> chapters,
    Size size,
    TextDirection direction,
    TextScaler textScaler, {
    required bool usesTwoPageLayout,
  }) {
    if (!_horizontalBackwardExpansionPending ||
        _horizontalFirstChapter <= 0 ||
        size.isEmpty) {
      return false;
    }
    final nextFirstChapter = _horizontalFirstChapter - 1;
    final chapter = chapters[nextFirstChapter];
    final layoutFingerprint = _paginationFingerprintFor(
      nextFirstChapter,
      size,
      direction,
      textScaler,
    );
    if (!chapter.hasLoadedText || !_pageCache.containsKey(layoutFingerprint)) {
      if (!_horizontalBackwardExpansionWarmPending) {
        _horizontalBackwardExpansionWarmPending = true;
        unawaited(
          _prepareHorizontalBackwardExpansion(
            chapters,
            nextFirstChapter,
            size,
            direction,
            textScaler,
            usesTwoPageLayout: usesTwoPageLayout,
          ),
        );
      }
      return false;
    }
    debugPrint(
      '[reader-horizontal] commit backward expansion '
      'target=$_chapterIndex:$_pageIndex '
      'window=$_horizontalFirstChapter..$_horizontalLastChapter '
      'nextFirst=$nextFirstChapter controller=${_pageController?.page?.toStringAsFixed(2)}',
    );
    _horizontalBackwardExpansionPending = false;
    _horizontalBackwardExpansionWarmPending = false;
    if (_pageMode != NativePageMode.horizontalSlide) {
      // Cover mode locates the current page by identity on every build, so
      // the window can grow without preserving a scroll position.
      _setReaderState(() => _horizontalFirstChapter = nextFirstChapter);
      return true;
    }
    final addedPages = _pagesFor(
      chapter,
      nextFirstChapter,
      size,
      direction,
      textScaler,
    ).length;
    final addedBookPages = usesTwoPageLayout && addedPages.isOdd
        ? addedPages + 1
        : addedPages;
    final addedControllerPages = usesTwoPageLayout
        ? addedBookPages ~/ 2
        : addedBookPages;
    final previousControllerOrigin = _horizontalPageIndexMap.origin;
    final nextControllerOrigin =
        previousControllerOrigin - addedControllerPages;
    if (nextControllerOrigin < 0) {
      debugPrint(
        '[reader-horizontal] backward expansion exhausted virtual reserve '
        'origin=$previousControllerOrigin added=$addedControllerPages',
      );
      return false;
    }
    _horizontalForwardExpansionPending = false;
    _horizontalForwardContractionPending = false;
    final nextLastChapter = math.max(
      nextFirstChapter,
      math.min(_horizontalLastChapter, _chapterIndex + 2),
    );
    _setReaderState(() {
      _horizontalPageIndexMap.origin = nextControllerOrigin;
      _horizontalFirstChapter = nextFirstChapter;
      _horizontalLastChapter = nextLastChapter;
    });
    debugPrint(
      '[reader-horizontal] backward origin '
      '$previousControllerOrigin->$nextControllerOrigin '
      'addedControllerPages=$addedControllerPages',
    );
    return true;
  }

  void _runWhenHorizontalControllerIsIdle(
    PageController? pageController,
    int controllerGeneration,
    VoidCallback action, {
    VoidCallback? onStale,
  }) {
    bool isCurrentController() =>
        mounted &&
        controllerGeneration == _pageControllerGeneration &&
        identical(pageController, _pageController);

    void run() {
      if (!isCurrentController()) {
        debugPrint(
          '[reader-horizontal] idle callback stale '
          'requestedGeneration=$controllerGeneration currentGeneration=$_pageControllerGeneration',
        );
        onStale?.call();
        return;
      }
      action();
    }

    if (!isCurrentController()) {
      onStale?.call();
      return;
    }
    if (pageController == null || !pageController.hasClients) {
      run();
      return;
    }
    final scrolling = pageController.position.isScrollingNotifier;
    if (!scrolling.value) {
      run();
      return;
    }
    debugPrint(
      '[reader-horizontal] defer window maintenance until idle '
      'controller=${pageController.page?.toStringAsFixed(2)} '
      'generation=$controllerGeneration',
    );
    late VoidCallback onIdle;
    onIdle = () {
      if (scrolling.value) return;
      scrolling.removeListener(onIdle);
      run();
    };
    scrolling.addListener(onIdle);
  }

  void _retryPendingHorizontalBackwardExpansion(List<_NativeChapter> chapters) {
    _horizontalBackwardExpansionWarmPending = false;
    if (!mounted || !_horizontalBackwardExpansionPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_horizontalBackwardExpansionPending ||
          _lastPaginationSize.isEmpty) {
        return;
      }
      final pageController = _pageController;
      final controllerGeneration = _pageControllerGeneration;
      _runWhenHorizontalControllerIsIdle(
        pageController,
        controllerGeneration,
        () {
          _commitHorizontalBackwardExpansion(
            chapters,
            _lastPaginationSize,
            Directionality.of(context),
            readerBodyTextScaler,
            usesTwoPageLayout: _lastUsesTwoPageLayout ?? false,
          );
        },
      );
    });
  }

  Future<void> _prepareHorizontalBackwardExpansion(
    List<_NativeChapter> chapters,
    int chapterIndex,
    Size size,
    TextDirection direction,
    TextScaler textScaler, {
    required bool usesTwoPageLayout,
  }) async {
    final requestedPageController = _pageController;
    final requestedControllerGeneration = _pageControllerGeneration;
    final requestedFirstChapter = _horizontalFirstChapter;
    final requestedLayoutFingerprint = _paginationFingerprintFor(
      chapterIndex,
      size,
      direction,
      textScaler,
    );

    bool requestIsCurrent() =>
        mounted &&
        _horizontalBackwardExpansionPending &&
        requestedControllerGeneration == _pageControllerGeneration &&
        identical(requestedPageController, _pageController) &&
        requestedFirstChapter == _horizontalFirstChapter &&
        chapterIndex == _horizontalFirstChapter - 1 &&
        size == _lastPaginationSize &&
        usesTwoPageLayout == (_lastUsesTwoPageLayout ?? false) &&
        direction == Directionality.of(context) &&
        requestedLayoutFingerprint ==
            _paginationFingerprintFor(
              chapterIndex,
              size,
              direction,
              textScaler,
            );

    try {
      await _loadIndexedChapterWindow(
        chapters,
        chapterIndex,
        retainAroundCurrentChapter: true,
      );
    } catch (error) {
      debugPrint('prepare previous native chapter failed: $error');
      _horizontalBackwardExpansionWarmPending = false;
      return;
    }

    if (!requestIsCurrent()) {
      _retryPendingHorizontalBackwardExpansion(chapters);
      return;
    }

    void paginateAndCommit() {
      if (!requestIsCurrent()) {
        _retryPendingHorizontalBackwardExpansion(chapters);
        return;
      }
      try {
        _pagesFor(
          chapters[chapterIndex],
          chapterIndex,
          size,
          direction,
          textScaler,
        );
      } catch (error) {
        debugPrint('paginate previous native chapter failed: $error');
        _horizontalBackwardExpansionWarmPending = false;
        return;
      }
      _horizontalBackwardExpansionWarmPending = false;
      _commitHorizontalBackwardExpansion(
        chapters,
        size,
        direction,
        textScaler,
        usesTwoPageLayout: usesTwoPageLayout,
      );
    }

    _runWhenHorizontalControllerIsIdle(
      requestedPageController,
      requestedControllerGeneration,
      paginateAndCommit,
      onStale: () => _retryPendingHorizontalBackwardExpansion(chapters),
    );
  }

  void _commitHorizontalWindowMaintenanceWhenIdle(
    List<_BookPageRef> bookPages,
    List<_NativeChapter> chapters,
    Size size,
    TextDirection direction,
    TextScaler textScaler, {
    required bool usesTwoPageLayout,
  }) {
    final pageController = _pageController;
    if (pageController == null || !pageController.hasClients) return;
    final controllerGeneration = _pageControllerGeneration;

    void commit() {
      if (!mounted ||
          controllerGeneration != _pageControllerGeneration ||
          !identical(pageController, _pageController)) {
        return;
      }
      _publishPendingHorizontalPage(chapters);
      if (_horizontalBackwardExpansionPending) {
        _commitHorizontalBackwardExpansion(
          chapters,
          size,
          direction,
          textScaler,
          usesTwoPageLayout: usesTwoPageLayout,
        );
        return;
      }
      if (_horizontalForwardContractionPending) {
        _commitHorizontalForwardContraction(
          bookPages,
          chapters,
          usesTwoPageLayout: usesTwoPageLayout,
        );
        return;
      }
      _commitHorizontalForwardExpansion(chapters);
    }

    debugPrint(
      '[reader-horizontal] window maintenance requested '
      'controller=${pageController.page?.toStringAsFixed(2)} '
      'generation=$controllerGeneration '
      'pending=backward=$_horizontalBackwardExpansionPending '
      'contraction=$_horizontalForwardContractionPending '
      'forward=$_horizontalForwardExpansionPending',
    );

    _runWhenHorizontalControllerIsIdle(
      pageController,
      controllerGeneration,
      commit,
    );
  }
}
