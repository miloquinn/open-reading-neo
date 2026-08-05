part of 'book_source_reader_page.dart';

extension _BookSourceReaderChapterLoading on _BookSourceReaderPageState {
  Future<void> _loadChapter(
    int index, {
    double restoreProgress = 0,
    bool saveCurrent = true,
  }) async {
    if (index < 0 || index >= _chapters.length || _loadingContent) return;
    if (saveCurrent && index > _chapterIndex) _sessionPagesRead++;
    if (saveCurrent && _content != null) unawaited(_saveProgress());
    if (!mounted) return;
    final loadSerial = ++_chapterLoadSerial;
    final prefetched = _prefetchedContent[index];
    if (prefetched != null && _readableChapterText.containsKey(index)) {
      if (await _deferChapterApplyForOpeningFlight(index)) {
        if (!mounted || loadSerial != _chapterLoadSerial) return;
      }
      _applyLoadedChapter(index, prefetched, restoreProgress: restoreProgress);
      return;
    }
    _updateReaderState(() {
      _loadingContent = true;
      _error = null;
    });
    try {
      final contentFuture = _continuousContentFor(index);
      final content = await contentFuture;
      if (!mounted || loadSerial != _chapterLoadSerial) return;
      if (await _deferChapterApplyForOpeningFlight(index)) {
        if (!mounted || loadSerial != _chapterLoadSerial) return;
      }
      _applyLoadedChapter(index, content, restoreProgress: restoreProgress);
    } catch (error) {
      if (!mounted || loadSerial != _chapterLoadSerial) return;
      _updateReaderState(() {
        _loadingContent = false;
        _error = error;
        _controlsVisible = true;
      });
    }
  }

  void _applyLoadedChapter(
    int index,
    BookSourceChapterContent content, {
    required double restoreProgress,
  }) {
    final normalizedProgress = restoreProgress.clamp(0.0, 1.0);
    final preparedLayout = _preparedPagedLayoutForChapter(index, content);
    final preparedPages = preparedLayout?.pages;
    final preparedPageCount = preparedPages?.length ?? 1;
    final preparedPageIndex = preparedPages == null
        ? 0
        : (_usesTwoPageLayout
                  ? _spreadStartForPage(
                      ((preparedPageCount - 1) * normalizedProgress).round(),
                    )
                  : ((preparedPageCount - 1) * normalizedProgress).round())
              .clamp(0, preparedPageCount - 1);
    final slideLeading = _slideLeadingPageCount(index);
    _pagedLayouts.removeWhere(
      (chapterIndex, _) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    _warmedPagedLayoutIndexes.removeWhere(
      (chapterIndex) => chapterIndex < index - 1 || chapterIndex > index + 2,
    );
    _updateReaderState(() {
      _chapterIndex = index;
      _content = content;
      _prefetchedContent[index] = content;
      _loadingContent = false;
      _pageIndex = preparedPageIndex;
      _pageCount = preparedPageCount;
      _pageViewLeading = slideLeading;
      _paginatedPages = preparedPages ?? const [];
      _paginationKey = preparedLayout?.fingerprint;
      _restorePageProgress = normalizedProgress;
      _restorePagedPosition = preparedLayout == null;
      _ignoreSlidePageChanges = true;
      _pendingSlideChapterIndex = null;
      _pendingSlideBoundaryViewIndex = null;
    });
    if (_pageMode == BookSourcePageMode.horizontalSlide) {
      _replaceSlidePageController(
        initialPage: preparedPageIndex + slideLeading,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ignoreSlidePageChanges = false;
      });
    }
    _scrollProgress.value = normalizedProgress;
    unawaited(_preloadAround(index));
  }

  _BookSourcePagedLayout? _preparedPagedLayoutForChapter(
    int index,
    BookSourceChapterContent content,
  ) {
    if (_pageMode == BookSourcePageMode.verticalScroll ||
        _pagedViewportSize.isEmpty) {
      return null;
    }
    return _pagedLayoutFor(index, content, _pagedViewportSize);
  }

  int _slideLeadingPageCount(int chapterIndex) {
    if (chapterIndex <= 0) return 0;
    final previousContent = _prefetchedContent[chapterIndex - 1];
    if (previousContent == null || _pagedViewportSize.isEmpty) return 1;
    final previousLayout = _pagedLayoutFor(
      chapterIndex - 1,
      previousContent,
      _pagedViewportSize,
    );
    return previousLayout.pages.length;
  }

  void _replaceSlidePageController({required int initialPage}) {
    final previous = _pageController;
    _pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> _preloadAround(int index) async {
    // The next chapter is the only cache entry needed for a forward turn.
    // Load and lay it out before competing for a source connection with the
    // backwards preview or the farther look-ahead chapter.
    await _preloadChapter(index + 1);
    for (final chapterIndex in <int>[index - 1, index + 2]) {
      unawaited(_preloadChapter(chapterIndex));
    }
  }

  Future<void> _preloadChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    try {
      await _continuousContentFor(index);
      _schedulePagedLayoutWarm(index);
    } catch (_) {
      // Adjacent content is opportunistic and can be retried on demand.
    }
  }

  Future<BookSourceChapterContent> _continuousContentFor(int index) {
    final cached = _prefetchedContent[index];
    if (cached != null && _readableChapterText.containsKey(index)) {
      return Future.value(cached);
    }
    final inFlight = _continuousContentLoads[index];
    if (inFlight != null) return inFlight;
    late final Future<BookSourceChapterContent> future;
    final contentFuture = cached != null
        ? Future<BookSourceChapterContent>.value(cached)
        : _client.getChapterContent(
            widget.source,
            bookId: widget.book.id,
            chapterId: _chapters[index].id,
            sourceVariables: {
              ...widget.book.sourceVariables,
              'chapterIndex': '$index',
              'chapterTitle': _chapters[index].title,
              'bookName': widget.book.title,
              'bookAuthor': widget.book.author,
              'bookType': '${widget.book.type}',
            },
          );
    future = contentFuture
        .then((content) async {
          _readableChapterText.remove(index);
          final readable = isImageOnlyBookSourceChapter(content)
              ? ''
              : await readableBookSourceChapterTextAsync(
                  content,
                  fallbackTitle: _chapters[index].title,
                );
          await ReplaceRuleService.instance.load();
          _readableChapterText[index] = ReplaceRuleService.instance.apply(
            readable,
            bookTitle: widget.book.title,
            sourceName: widget.source.name,
          );
          while (_readableChapterText.length >
              _bookSourceReadableChapterTextLimit) {
            _readableChapterText.remove(_readableChapterText.keys.first);
          }
          _prefetchedContent[index] = content;
          if (!mounted) {
            return content;
          }
          final pageStep = _usesTwoPageLayout ? 2 : 1;
          final updatesCurrentContent =
              !_loadingContent && _chapterIndex == index && _content != content;
          final revealsPagedBoundary =
              !_loadingContent &&
              _pageMode != BookSourcePageMode.verticalScroll &&
              ((index == _chapterIndex + 1 &&
                      _pageIndex + pageStep >= _pageCount) ||
                  (index == _chapterIndex - 1 && _pageIndex < pageStep));
          if (updatesCurrentContent || revealsPagedBoundary) {
            _updateReaderState(() {
              if (updatesCurrentContent) {
                _content = content;
              }
            });
          }
          _schedulePagedLayoutWarm(index);
          return content;
        })
        .whenComplete(() {
          if (identical(_continuousContentLoads[index], future)) {
            _continuousContentLoads.remove(index);
          }
        });
    _continuousContentLoads[index] = future;
    return future;
  }

  void _schedulePagedLayoutWarm(int index) {
    if (!mounted ||
        _pageMode == BookSourcePageMode.verticalScroll ||
        index != _chapterIndex + 1 ||
        index < 0 ||
        index >= _chapters.length ||
        _pagedViewportSize.isEmpty ||
        _prefetchedContent[index] == null ||
        _warmedPagedLayoutIndexes.contains(index) ||
        !_queuedPagedLayoutWarms.add(index)) {
      return;
    }
    _pagedLayoutWarmTimer?.cancel();
    final previousWarmIndex = _pagedLayoutWarmTimerIndex;
    if (previousWarmIndex != null) {
      _queuedPagedLayoutWarms.remove(previousWarmIndex);
    }
    _pagedLayoutWarmTimerIndex = index;
    _pagedLayoutWarmTimer = Timer(const Duration(milliseconds: 32), () {
      _pagedLayoutWarmTimer = null;
      _pagedLayoutWarmTimerIndex = null;
      _queuedPagedLayoutWarms.remove(index);
      if (!mounted ||
          _pageMode == BookSourcePageMode.verticalScroll ||
          index != _chapterIndex + 1 ||
          _pagedViewportSize.isEmpty) {
        return;
      }
      // 打开动画（含正文渐显）没播完前不预热整章排版，落定后再重新排队。
      final settled = BookOpenTransition.openingFlightSettledListenableOf(
        context,
      );
      if (settled != null && !settled.value) {
        late final VoidCallback onSettled;
        onSettled = () {
          settled.removeListener(onSettled);
          if (mounted) _schedulePagedLayoutWarm(index);
        };
        settled.addListener(onSettled);
        return;
      }
      final content = _prefetchedContent[index];
      if (content == null) return;
      _pagedLayoutFor(index, content, _pagedViewportSize);
      _warmedPagedLayoutIndexes.add(index);
    });
  }

  Future<void> _jumpToVerticalChapter(
    int index, {
    int? textOffset,
    double progress = 0,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final content = await _continuousContentFor(index);
    if (!mounted) return;
    var targetPage = 0;
    _BookSourceVerticalLayout? layout;
    if (!_verticalViewportSize.isEmpty) {
      layout = _verticalLayoutFor(index, content, _verticalViewportSize);
      targetPage = textOffset != null
          ? bookSourcePageIndexForOffset(layout.pages, textOffset)
          : ((layout.pages.length - 1) * progress.clamp(0.0, 1.0)).round();
    }
    _updateReaderState(() {
      _chapterIndex = index;
      _content = content;
      _pageIndex = targetPage;
      _verticalPageIndex = targetPage;
      _verticalPageCount = layout?.pages.length ?? 1;
      _restorePagedPosition = false;
      _restoreTextOffset = null;
    });
    _scrollProgress.value = _verticalPageCount <= 1
        ? 0
        : targetPage / (_verticalPageCount - 1);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (_scrollByChapter) {
      if (_verticalPageScrollController.isAttached) {
        await _verticalPageScrollController.scrollTo(
          index: targetPage,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      unawaited(_preloadAround(index));
      _scheduleProgressSave();
      return;
    }
    if (!_verticalChapterScrollController.isAttached) return;
    await _verticalChapterScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    if (targetPage > 0) {
      await _verticalChapterOffsetController.animateScroll(
        offset: targetPage * _verticalPageExtentFor(_verticalViewportSize),
        duration: const Duration(milliseconds: 1),
      );
      if (!mounted) return;
    }
    unawaited(_preloadAround(index));
    _scheduleProgressSave();
  }
}
