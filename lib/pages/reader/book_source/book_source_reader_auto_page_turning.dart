part of 'book_source_reader_page.dart';

extension _BookSourceReaderAutoPageTurning on _BookSourceReaderPageState {
  void _onAutoPageTurnChanged() {
    if (!mounted) return;
    final wholeBook =
        _pageMode == BookSourcePageMode.verticalScroll &&
        (_autoPageTurnController.isActive || _autoWholeBook) &&
        _autoPageTurnController.mode == ReaderAutoPageTurnMode.continuous;
    // Keep the mounted reading window when stopping: a chapter-only list
    // cannot retain the previous chapter still visible above a new chapter.
    // Explicit layout settings or another mode restore chapter scoping.
    if (wholeBook != _autoWholeBook) {
      if (_scrollByChapter) {
        _autoRestoreCentered = _verticalCanonicalOffset != null;
        _restoreTextOffset = _verticalCanonicalOffset ?? _currentTextOffset;
        _restorePageProgress = _currentReadingProgress;
        _restorePagedPosition = true;
        _autoScrollRestoring = true;
      }
      _autoWholeBook = wholeBook;
    }
    _updateReaderState(() {});
  }

  void _handleAutoPointerDown(PointerDownEvent event) {
    final wasRunning =
        _autoPageTurnController.isActive && _autoPageTurnController.isRunning;
    _consumeAutoTap = wasRunning;
    _pauseAutoPageTurn(smooth: wasRunning);
  }

  void _handleAutoPointerMove(PointerMoveEvent event) {
    if (!_autoPageTurnController.isActive) return;
    if (_autoPageTurnController.mode == ReaderAutoPageTurnMode.sweep) {
      _consumeAutoTap = false;
      _stopAutoPageTurn();
    } else if (_autoPageTurnController.mode ==
            ReaderAutoPageTurnMode.continuous &&
        _autoPageTurnController.smoothPauseRequested) {
      _consumeAutoTap = false;
      _autoPageTurnController.pause();
    }
  }

  bool get _autoContinuousReady {
    if (!_autoWholeBook || _autoScrollRestoring || _restorePagedPosition) {
      return false;
    }
    var lastVisible = _chapterIndex;
    for (final item in _verticalChapterPositionsListener.itemPositions.value) {
      if (item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0) {
        lastVisible = math.max(lastVisible, item.index);
      }
    }
    final through = math.min(
      _chapters.length - 1,
      math.max(_chapterIndex + 1, lastVisible + 1),
    );
    _autoRetainThrough = through;
    var ready = true;
    for (var index = _chapterIndex; index <= through; index++) {
      if (!_prefetchedContent.containsKey(index) ||
          !_readableChapterText.containsKey(index)) {
        ready = false;
        final pending = index;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_prepareAutoChapter(pending));
        });
      }
    }
    return ready;
  }

  Future<void> _prepareAutoNextChapter() =>
      _prepareAutoChapter(_chapterIndex + 1);

  Future<void> _prepareAutoChapter(int index) async {
    if (!_autoPageTurnController.isRunning ||
        index >= _chapters.length ||
        !_autoPreparingChapters.add(index)) {
      return;
    }
    try {
      final content = await _continuousContentFor(index);
      if (!mounted) return;
      if (isImageOnlyBookSourceChapter(content)) _stopAutoPageTurn();
      _updateReaderState(() {});
    } catch (error) {
      if (mounted) _pauseAutoPageTurn();
      debugPrint('Automatic reading chapter preparation failed: $error');
    } finally {
      _autoPreparingChapters.remove(index);
    }
  }

  void _cancelAutoSweepOrPause() {
    if (_autoPageTurnController.mode == ReaderAutoPageTurnMode.sweep) {
      _stopAutoPageTurn();
    } else {
      _pauseAutoPageTurn();
    }
  }

  void _pauseAutoPageTurn({bool smooth = false}) {
    _autoPageTurnStartRequest++;
    _autoPageTurnController.pause(smooth: smooth);
  }

  void _stopAutoPageTurn() {
    _autoPageTurnStartRequest++;
    _autoPageTurnController.stop();
  }

  Future<void> _resumeAutoPageTurn() async {
    if (!mounted ||
        !_appLifecycleActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        _loadingCatalog ||
        _loadingContent ||
        _annotationInteractionActive ||
        _tapZoneEditorVisible ||
        _error != null ||
        _content == null) {
      return;
    }
    final wasActive = _autoPageTurnController.isActive;
    final request = ++_autoPageTurnStartRequest;
    final readerAloud = _readerAloudController;
    if (readerAloud?.state == ReaderAloudPlaybackState.loading) {
      await readerAloud!.stop();
    } else {
      await readerAloud?.pause();
    }
    if (!mounted ||
        request != _autoPageTurnStartRequest ||
        (wasActive && !_autoPageTurnController.isActive) ||
        !_appLifecycleActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        _loadingCatalog ||
        _loadingContent ||
        _annotationInteractionActive ||
        _tapZoneEditorVisible ||
        _error != null ||
        _content == null) {
      return;
    }
    _controlsTimer?.cancel();
    if (_controlsVisible) _updateReaderState(() => _controlsVisible = false);
    _autoPageTurnController.setVertical(
      _pageMode == BookSourcePageMode.verticalScroll,
    );
    _autoPageTurnController.start();
  }

  Future<void> _showAutoPageTurnSettings() async {
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final selection = await showReaderAutoPageTurnSheet(
      context: context,
      palette: _readerTheme,
      controller: _autoPageTurnController,
      vertical: _pageMode == BookSourcePageMode.verticalScroll,
    );
    if (selection == null || !mounted) return;

    await _autoPageTurnController.applySelection(selection);
    await _resumeAutoPageTurn();
  }

  Future<bool> _advanceAutoPageTurn() async {
    if (!mounted) return false;
    if (!_appLifecycleActive ||
        ModalRoute.of(context)?.isCurrent != true ||
        _annotationInteractionActive ||
        _tapZoneEditorVisible ||
        _controlsVisible ||
        _error != null) {
      _autoPageTurnController.pause();
      return true;
    }
    if (_loadingCatalog || _loadingContent || _content == null) return true;
    if (isImageOnlyBookSourceChapter(_content!)) return false;

    if (_pageMode == BookSourcePageMode.horizontalSlide) {
      if (!_pageController.hasClients ||
          _pageController.position.isScrollingNotifier.value) {
        return true;
      }
      final page = _pageController.page;
      if (page == null || (page - page.round()).abs() > 0.001) return true;
    }

    if (_pageMode == BookSourcePageMode.verticalScroll) {
      if (_verticalViewportAtEnd()) {
        if (_effectiveScrollByChapter && _chapterIndex + 1 < _chapters.length) {
          await _loadChapter(_chapterIndex + 1, restoreProgress: 0);
          return mounted && _error == null;
        }
        return false;
      }
      await _scrollVerticalByViewport(forward: true);
      return mounted;
    }

    final pageStep = _usesTwoPageLayout ? 2 : 1;
    final atBookEnd =
        _pageIndex + pageStep >= _pageCount &&
        _chapterIndex + 1 >= _chapters.length;
    if (atBookEnd) return false;
    await _turnFromTap(forward: true);
    return mounted && _error == null;
  }

  Widget _buildAutoSweepSurface() {
    final step = _usesTwoPageLayout ? 2 : 1;
    final start = _usesTwoPageLayout
        ? _spreadStartForPage(_pageIndex)
        : _pageIndex;
    final crossesChapter = start + step >= _pageCount;
    final targetChapter = crossesChapter ? _chapterIndex + 1 : _chapterIndex;
    final targetPage = crossesChapter ? 0 : start + step;
    final hasNext = targetChapter < _chapters.length;

    ReaderPageSnapshot? leaf(int chapter, int page, {bool right = false}) {
      if (chapter >= _chapters.length) return null;
      final content = chapter == _chapterIndex
          ? _content
          : _prefetchedContent[chapter];
      if (content == null || isImageOnlyBookSourceChapter(content)) return null;
      final layout = _pagedLayoutFor(chapter, content, _pagedViewportSize);
      if (page >= layout.pages.length) {
        return _buildBlankSourceSnapshot('$chapter:$page');
      }
      return _buildPageSnapshot(
        layout.pages[page],
        chapterIndex: chapter,
        chapterContent: content,
        pageIndex: page,
        pageCount: layout.pages.length,
        layoutFingerprint: layout.fingerprint,
        pageNumberPlacement: _usesTwoPageLayout && !right
            ? ReaderPageNumberPlacement.bottomLeft
            : ReaderPageNumberPlacement.bottomRight,
        topInformationLayout: !_usesTwoPageLayout
            ? ReaderTopInformationLayout.full
            : right
            ? ReaderTopInformationLayout.spreadRight
            : ReaderTopInformationLayout.spreadLeft,
      );
    }

    ReaderPageSnapshot? snapshot(int chapter, int page) {
      final left = leaf(chapter, page);
      if (left == null || !_usesTwoPageLayout) return left;
      final right = leaf(chapter, page + 1, right: true);
      if (right == null) return null;
      return ReaderPageSnapshot(
        key: ReaderPageSnapshotKey(
          pageIdentity: '${left.key.pageIdentity}|${right.key.pageIdentity}',
          layoutFingerprint: left.key.layoutFingerprint,
          themeId: left.key.themeId,
        ),
        contentRevision: _leafContentRevision,
        child: _buildSourceSpread(left: left.child, right: right.child),
      );
    }

    final current = snapshot(_chapterIndex, start);
    if (current == null) return const SizedBox.shrink();
    return ReaderSweepPageTurn(
      controller: _autoPageTurnController,
      currentPage: current,
      nextPage: hasNext ? snapshot(targetChapter, targetPage) : null,
      hasNext: hasNext,
      twoPage: _usesTwoPageLayout,
      contentInsets: EdgeInsets.only(
        top: _readerSafeArea.contentTop,
        bottom: _readerSafeArea.contentBottom,
      ),
      spreadGutter: _bookSourceSpreadGutter,
      onNeedNextPage: () => unawaited(_prepareAutoNextChapter()),
      onTurnForward: _turnForward,
    );
  }

  bool _verticalViewportAtEnd() {
    final positions =
        (_effectiveScrollByChapter
                ? _verticalPagePositionsListener
                : _verticalChapterPositionsListener)
            .itemPositions
            .value;
    if (positions.isEmpty) return false;
    final finalIndex = _effectiveScrollByChapter
        ? _verticalPageCount - 1
        : _chapters.length - 1;
    for (final position in positions) {
      if (position.index == finalIndex &&
          position.itemLeadingEdge < 1 &&
          position.itemTrailingEdge <= 1) {
        return true;
      }
    }
    return false;
  }
}
