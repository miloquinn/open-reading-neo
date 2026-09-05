part of 'native_reader_page.dart';

extension _NativeReaderAutoPageTurn on _NativeReaderPageState {
  (bool, bool, ReaderAutoPageTurnMode, double)
  get _currentAutoPageTurnUiState => (
    _autoPageTurnController.isActive,
    _autoPageTurnController.isRunning,
    _autoPageTurnController.mode,
    _autoPageTurnController.secondsFor(_autoPageTurnController.mode),
  );

  void _onAutoPageTurnChanged() {
    final next = _currentAutoPageTurnUiState;
    if (next == _autoPageTurnUiState || !mounted) return;
    final enteringContinuousSurface =
        _pageMode == NativePageMode.verticalScroll &&
        next.$1 &&
        next.$3 == ReaderAutoPageTurnMode.continuous &&
        !_retainWholeBookAfterAutoScroll;
    final leavingForAnotherAutoMode =
        _pageMode == NativePageMode.verticalScroll &&
        _retainWholeBookAfterAutoScroll &&
        next.$3 != ReaderAutoPageTurnMode.continuous;
    _autoPageTurnUiState = next;
    if (enteringContinuousSurface || leavingForAnotherAutoMode) {
      final visibleOffset = _visibleContinuousParts.isEmpty
          ? null
          : _visibleContinuousParts[_pageIndex.clamp(
                  0,
                  _visibleContinuousParts.length - 1,
                )]
                .content
                .startOffset;
      _anchorOffset =
          _verticalCanonicalOffset ?? _anchorOffset ?? visibleOffset ?? 0;
      _restoreAnchorAfterLayout = true;
      _restoreContinuousAnchorCentered = true;
      _initialPositionRestored = false;
      _initialPositionRestoreScheduled = false;
      _lastSavedLocation = null;
    }
    if (enteringContinuousSurface) {
      _retainWholeBookAfterAutoScroll = true;
    } else if (leavingForAnotherAutoMode) {
      _retainWholeBookAfterAutoScroll = false;
    }
    _setReaderState(() {});
  }

  void _pauseAutoPageTurn({bool smooth = false}) {
    _autoPageTurnStartRequest++;
    _autoPageTurnController.pause(smooth: smooth);
  }

  void _cancelAutoSweepOrPause() {
    _autoPageTurnStartRequest++;
    if (_autoPageTurnController.isActive &&
        _autoPageTurnController.mode == ReaderAutoPageTurnMode.sweep) {
      _autoPageTurnController.stop();
    } else {
      _autoPageTurnController.pause();
    }
  }

  void _handleAutoPageTurnPointerDown(PointerDownEvent event) {
    final wasRunning =
        _autoPageTurnController.isActive && _autoPageTurnController.isRunning;
    _consumeAutoPageTurnTap = wasRunning;
    _pauseAutoPageTurn(smooth: wasRunning);
  }

  void _handleAutoPageTurnPointerMove(PointerMoveEvent event) {
    if (!_autoPageTurnController.isActive) return;
    if (_autoPageTurnController.mode == ReaderAutoPageTurnMode.sweep) {
      _consumeAutoPageTurnTap = false;
      _autoPageTurnController.stop();
    } else if (_autoPageTurnController.mode ==
            ReaderAutoPageTurnMode.continuous &&
        _autoPageTurnController.smoothPauseRequested) {
      _consumeAutoPageTurnTap = false;
      _autoPageTurnController.pause();
    }
  }

  void _handleAutoPageTurnPointerSignal(PointerSignalEvent event) {
    _consumeAutoPageTurnTap = false;
    _cancelAutoSweepOrPause();
  }

  bool _consumeAutoPageTurnContentTap() {
    if (!_consumeAutoPageTurnTap) return false;
    _consumeAutoPageTurnTap = false;
    return true;
  }

  bool get _canAutoPageTurn =>
      mounted &&
      !_exitInProgress &&
      !_annotationInteractionActive &&
      !_tapZoneEditorVisible &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<void> _showAutoPageTurnSettings() async {
    _pauseAutoPageTurn();
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final selection = await showReaderAutoPageTurnSheet(
      context: context,
      palette: _readerTheme,
      controller: _autoPageTurnController,
      vertical: _pageMode == NativePageMode.verticalScroll,
    );
    if (selection == null || !_canAutoPageTurn) return;
    await _autoPageTurnController.applySelection(selection);
    if (_canAutoPageTurn) await _resumeAutoPageTurn();
  }

  Future<void> _resumeAutoPageTurn() async {
    if (!_canAutoPageTurn) return;
    final request = ++_autoPageTurnStartRequest;
    final wasActive = _autoPageTurnController.isActive;
    final aloud = _readerAloudController;
    if (aloud?.state == ReaderAloudPlaybackState.loading) {
      await aloud!.stop();
    } else if (aloud?.state == ReaderAloudPlaybackState.playing) {
      await aloud!.pause();
    }
    if (!_canAutoPageTurn ||
        request != _autoPageTurnStartRequest ||
        (wasActive && !_autoPageTurnController.isActive)) {
      return;
    }
    _hideControlsForPageTurn();
    _autoPageTurnController.setVertical(
      _pageMode == NativePageMode.verticalScroll,
    );
    if (_pageMode == NativePageMode.verticalScroll &&
        _autoPageTurnController.mode == ReaderAutoPageTurnMode.continuous) {
      final ready = await _prepareContinuousAutoScrollAhead();
      if (!_canAutoPageTurn || request != _autoPageTurnStartRequest) return;
      if (!ready) {
        _autoPageTurnController.start();
        _autoPageTurnController.pause();
        return;
      }
    }
    _autoPageTurnController.start();
  }

  Future<bool> _advanceAutoPageTurn() async {
    if (!_canAutoPageTurn || _controlsVisible) {
      _pauseAutoPageTurn();
      return true;
    }
    if (_visiblePages.isEmpty ||
        !_initialPositionRestored ||
        _horizontalChapterJumpPending ||
        _pendingHorizontalForwardBoundary != null ||
        _pendingHorizontalPage != null ||
        (_pageController?.hasClients == true &&
            _pageController!.position.isScrollingNotifier.value)) {
      return true;
    }
    final mode = _autoPageTurnController.mode;
    if (mode == ReaderAutoPageTurnMode.interval) {
      if (_pageMode != NativePageMode.verticalScroll) return true;
      return _advanceAutoPageTurnVertically();
    }
    if (mode != ReaderAutoPageTurnMode.timed ||
        _pageMode == NativePageMode.verticalScroll) {
      return true;
    }
    final step = _visibleUsesTwoPageLayout ? 2 : 1;
    if (_chapterIndex >= _visibleChapterCount - 1 &&
        _pageIndex + step >= _visiblePages.length) {
      return false;
    }
    await _nextPage(
      _visiblePages,
      _visibleChapterCount,
      usesTwoPageLayout: _visibleUsesTwoPageLayout,
      animate: _tapPageAnimationEnabled,
    );
    return true;
  }

  Future<bool> _advanceAutoPageTurnVertically() async {
    final itemController = _scrollByChapter
        ? _verticalPageScrollController
        : _verticalChapterScrollController;
    if (!itemController.isAttached || _verticalViewportSize.isEmpty) {
      return true;
    }
    final positions =
        (_scrollByChapter
                ? _verticalPagePositionsListener
                : _verticalChapterPositionsListener)
            .itemPositions
            .value;
    final lastIndex = _scrollByChapter
        ? _visibleContinuousParts.length - 1
        : _visibleChapters.length - 1;
    final reachedEnd = positions.any(
      (item) =>
          item.index == lastIndex &&
          item.itemLeadingEdge < 1 &&
          item.itemTrailingEdge <= 1.001,
    );
    if (reachedEnd) {
      if (!_scrollByChapter || _chapterIndex >= _visibleChapterCount - 1) {
        return false;
      }
      await _setChapter(_chapterIndex + 1, _visibleChapterCount);
      return true;
    }
    await _scrollVerticalByViewport(forward: true);
    return true;
  }

  Widget _buildAutoSweepSurface({
    required List<_NativeChapter> chapters,
    required List<_BookPageRef> bookPages,
    required bool usesTwoPageLayout,
  }) {
    final currentIndex = bookPages.indexWhere(
      (page) =>
          !page.isBlank &&
          !page.isForwardBoundary &&
          page.chapterIndex == _chapterIndex &&
          page.pageIndex == _pageIndex,
    );
    if (currentIndex < 0) {
      unawaited(_prepareAutoSweepTarget(chapters));
      final chapter = chapters[_chapterIndex];
      final pages = _visiblePages;
      final pageIndex = _pageIndex.clamp(0, pages.length - 1);
      final layoutFingerprint = _paginationFingerprintFor(
        _chapterIndex,
        _lastPaginationSize,
        Directionality.of(context),
        readerBodyTextScaler,
      );
      if (usesTwoPageLayout) {
        final spreadStart = _spreadStartForPage(pageIndex);
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
        pages[pageIndex],
        chapterIndex: _chapterIndex,
        pageIndex: pageIndex,
        pageCount: pages.length,
        layoutFingerprint: layoutFingerprint,
      );
    }
    final currentStart = usesTwoPageLayout
        ? _spreadStartForPage(currentIndex)
        : currentIndex;
    final targetIndex = currentStart + (usesTwoPageLayout ? 2 : 1);
    final expectedPageStep = usesTwoPageLayout ? 2 : 1;
    final logicalHasNext =
        _chapterIndex < chapters.length - 1 ||
        _pageIndex + expectedPageStep < _visiblePages.length;
    final target = targetIndex < bookPages.length
        ? bookPages[targetIndex]
        : null;
    final targetIsImmediateNext =
        target != null &&
        ((target.chapterIndex == _chapterIndex &&
                target.pageIndex == _pageIndex + expectedPageStep) ||
            (_pageIndex + expectedPageStep >= _visiblePages.length &&
                target.chapterIndex == _chapterIndex + 1 &&
                target.pageIndex == 0));
    final hasPreparedTarget =
        targetIsImmediateNext && !target.isForwardBoundary;
    final currentSnapshot = usesTwoPageLayout
        ? _buildCoverSpreadSnapshot(chapters, bookPages, currentStart)
        : _buildBookPageSnapshot(chapters, bookPages[currentStart]);
    final nextSnapshot = !hasPreparedTarget
        ? null
        : usesTwoPageLayout
        ? _buildCoverSpreadSnapshot(chapters, bookPages, targetIndex)
        : _buildBookPageSnapshot(chapters, bookPages[targetIndex]);
    final expectedChapter = _chapterIndex;
    final expectedPage = _pageIndex;
    return ReaderSweepPageTurn(
      controller: _autoPageTurnController,
      currentPage: currentSnapshot,
      nextPage: nextSnapshot,
      hasNext: logicalHasNext,
      twoPage: usesTwoPageLayout,
      contentInsets: EdgeInsets.only(
        top: _readerSafeArea.contentTop,
        bottom: _readerSafeArea.contentBottom,
      ),
      spreadGutter: _spreadGutter,
      onNeedNextPage: () => unawaited(_prepareAutoSweepTarget(chapters)),
      onTurnForward: () async {
        if (!mounted ||
            _chapterIndex != expectedChapter ||
            _pageIndex != expectedPage ||
            targetIndex >= bookPages.length ||
            bookPages[targetIndex].isForwardBoundary) {
          return;
        }
        _onBookPageChanged(targetIndex, bookPages, chapters);
      },
    );
  }

  Future<void> _prepareAutoSweepTarget(List<_NativeChapter> chapters) async {
    if (!mounted ||
        !_autoPageTurnController.isActive ||
        _autoPageTurnController.mode != ReaderAutoPageTurnMode.sweep ||
        _chapterIndex >= chapters.length - 1 ||
        _lastPaginationSize.isEmpty) {
      return;
    }
    final nextChapterIndex = _chapterIndex + 1;
    try {
      await _loadIndexedChapterWindow(
        chapters,
        nextChapterIndex,
        retainAroundCurrentChapter: true,
      );
      if (!mounted || !_autoPageTurnController.isActive) return;
      _pagesFor(
        chapters[nextChapterIndex],
        nextChapterIndex,
        _lastPaginationSize,
        Directionality.of(context),
        readerBodyTextScaler,
      );
      if (nextChapterIndex > _horizontalLastChapter) {
        _horizontalLastChapter = nextChapterIndex;
      }
      _setReaderState(() {});
    } catch (error) {
      debugPrint('prepare native sweep page failed: $error');
      _pauseAutoPageTurn();
    }
  }

  Future<bool> _handleContinuousAutoScrollBoundary() async {
    if (!mounted ||
        !_autoPageTurnController.isActive ||
        _autoPageTurnController.mode != ReaderAutoPageTurnMode.continuous) {
      return false;
    }
    // Continuous mode temporarily mounts the whole book, so its trailing edge
    // is the actual book end rather than a chapter boundary.
    return false;
  }

  Future<bool> _prepareContinuousAutoScrollAhead() async {
    final chapters = _loadedChapters;
    final nextChapterIndex = _chapterIndex + 1;
    if (nextChapterIndex >= chapters.length ||
        chapters[nextChapterIndex].hasLoadedText) {
      return true;
    }
    try {
      await _loadIndexedChapterWindow(
        chapters,
        nextChapterIndex,
        retainAroundCurrentChapter: true,
      );
      if (mounted) _setReaderState(() {});
      return chapters[nextChapterIndex].hasLoadedText;
    } catch (error) {
      debugPrint('prepare native continuous chapter failed: $error');
      if (_autoPageTurnController.isActive) _pauseAutoPageTurn();
      return false;
    }
  }
}
