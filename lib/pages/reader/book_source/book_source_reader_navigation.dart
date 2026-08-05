part of '../book_source_reader_page.dart';

extension _BookSourceReaderNavigation on _BookSourceReaderPageState {
  void _restoreScrollProgress(double progress) {
    _restorePageProgress = progress.clamp(0, 1);
    _restorePagedPosition = true;
    _scrollProgress.value = progress.clamp(0.0, 1.0);
  }

  void _showControlsTemporarily() {
    _controlsTimer?.cancel();
    if (mounted) _updateReaderState(() => _controlsVisible = true);
    _controlsTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) _updateReaderState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_annotationInteractionActive) return;
    _controlsTimer?.cancel();
    _updateReaderState(() => _controlsVisible = !_controlsVisible);
  }

  Future<void> _requestExit() async {
    if (_exitPromptVisible) return;
    if (_shelfBookId != null) {
      BookOpenTransition.beginExit();
      await _saveProgress();
      unawaited(_flushReadingSession());
      if (!mounted) return;
      _updateReaderState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }
    _exitPromptVisible = true;
    await _saveProgress();
    // 阅读统计是退出后的派生写入，不应阻塞“加入书架？”确认弹窗。
    unawaited(_flushReadingSession());
    final shelfBook = await _shelfService.findShelfBook(
      sourceId: widget.source.id,
      sourceBookId: widget.book.id,
    );
    if (!mounted) return;
    if (shelfBook != null) {
      BookOpenTransition.beginExit();
      _updateReaderState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }

    final shouldAdd = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.bookSourceExitAddTitle),
        content: Text(context.l10n.bookSourceExitAddMessage(widget.book.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.bookSourceNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.bookSourceAddToShelf),
          ),
        ],
      ),
    );
    _exitPromptVisible = false;
    if (!mounted) return;
    if (shouldAdd == true) {
      final added = await _shelfService.addOnline(
        source: widget.source,
        book: widget.book,
      );
      _shelfBookId = added.id;
      await _saveProgress();
      if (!mounted) return;
    }
    BookOpenTransition.beginExit();
    _updateReaderState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  void _handleHorizontalSwipe(DragEndDetails details) {
    if (_annotationInteractionActive) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -350 && _chapterIndex < _chapters.length - 1) {
      unawaited(_loadChapter(_chapterIndex + 1));
    } else if (velocity > 350 && _chapterIndex > 0) {
      unawaited(_loadChapter(_chapterIndex - 1));
    }
  }

  void _handlePagedSwipe(DragEndDetails details) {
    if (_annotationInteractionActive) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -350) {
      unawaited(_turnForward());
    } else if (velocity > 350) {
      unawaited(_turnBackward());
    }
  }

  double get _currentReadingProgress {
    if (_pageMode != BookSourcePageMode.verticalScroll) {
      return _pagedReadingProgress(_pageIndex, _pageCount);
    }
    final text = _readableChapterText[_chapterIndex];
    final offset = _currentTextOffset;
    if (text == null || text.isEmpty || offset == null) return 0;
    return (offset / text.length).clamp(0.0, 1.0);
  }

  int? get _currentTextOffset {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return _verticalCanonicalOffset;
    }
    if (_paginatedPages.isEmpty) return null;
    return _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
        .startOffset;
  }

  void _setPagedIndex(int index, {bool jumpPageView = false}) {
    if (_paginatedPages.isEmpty) return;
    final clamped = index.clamp(0, _paginatedPages.length - 1);
    final next = _usesTwoPageLayout ? _spreadStartForPage(clamped) : clamped;
    if (next > _pageIndex) _sessionPagesRead++;
    if (next != _pageIndex) _updateReaderState(() => _pageIndex = next);
    _pageCount = _paginatedPages.length;
    _scrollProgress.value = _pagedReadingProgress(_pageIndex, _pageCount);
    if (jumpPageView && _pageController.hasClients) {
      _pageController.jumpToPage(_pageIndex + _pageViewLeading);
    }
    if (_pageCount - _pageIndex <= 3) {
      unawaited(_preloadChapter(_chapterIndex + 1));
    }
    _scheduleProgressSave();
  }

  void _scheduleProgressSave() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_saveProgress()),
    );
  }

  void _queueSlideChapterCommit({
    required int chapterIndex,
    required int boundaryViewIndex,
    required double restoreProgress,
  }) {
    _pendingSlideChapterIndex = chapterIndex;
    _pendingSlideBoundaryViewIndex = boundaryViewIndex;
    _pendingSlideRestoreProgress = restoreProgress;
  }

  void _commitPendingSlideChapter() {
    final chapterIndex = _pendingSlideChapterIndex;
    final boundaryViewIndex = _pendingSlideBoundaryViewIndex;
    if (chapterIndex == null || boundaryViewIndex == null) return;
    final settledPage = _pageController.hasClients
        ? _pageController.page
        : null;
    if (settledPage == null ||
        (settledPage - boundaryViewIndex).abs() > 0.001) {
      return;
    }
    _pendingSlideChapterIndex = null;
    _pendingSlideBoundaryViewIndex = null;
    final restoreProgress = _pendingSlideRestoreProgress;
    // Let PageController.nextPage/previousPage finish their own ScrollEnd
    // future before replacing the PageView with the target chapter.
    Timer.run(() {
      if (!mounted) return;
      unawaited(_loadChapter(chapterIndex, restoreProgress: restoreProgress));
    });
  }

  void _schedulePendingSlideChapterCommit() {
    if (_slideChapterCommitCheckScheduled) return;
    _slideChapterCommitCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slideChapterCommitCheckScheduled = false;
      if (mounted) _commitPendingSlideChapter();
    });
  }

  void _handleReaderTap(Offset localPosition) {
    if (_pageMode == BookSourcePageMode.horizontalSlide &&
        _pageController.hasClients) {
      final page = _pageController.page;
      if (page != null && (page - page.round()).abs() > 0.001) return;
    }
    _handleTapZoneAction(
      _tapZones.actionAt(localPosition, MediaQuery.sizeOf(context)),
    );
  }

  void _setTapZones(ReaderTapZones zones) {
    if (zones == _tapZones) return;
    _updateReaderState(() => _tapZones = zones);
    unawaited(_readerSettingsStore.saveTapZones(zones));
  }

  Future<void> _showTapZoneSettings() async {
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _controlsTimer?.cancel();
    _updateReaderState(() {
      _controlsVisible = false;
      _tapZoneEditorVisible = true;
    });
  }

  Future<void> _turnForward() async {
    final imageContent = _content;
    if (imageContent != null && isImageOnlyBookSourceChapter(imageContent)) {
      if (_pageIndex + 1 < imageContent.images.length) return;
      if (_chapterIndex + 1 < _chapters.length) {
        await _loadChapter(_chapterIndex + 1, restoreProgress: 0);
      } else {
        _showControlsTemporarily();
      }
      return;
    }
    final pageStep = _usesTwoPageLayout ? 2 : 1;
    if (_pageIndex + pageStep < _pageCount) {
      _setPagedIndex(_pageIndex + pageStep, jumpPageView: true);
    } else if (_chapterIndex + 1 < _chapters.length) {
      await _loadChapter(_chapterIndex + 1, restoreProgress: 0);
    } else {
      _showControlsTemporarily();
    }
  }

  Future<void> _turnBackward() async {
    final imageContent = _content;
    if (imageContent != null && isImageOnlyBookSourceChapter(imageContent)) {
      if (_pageIndex > 0) return;
      if (_chapterIndex > 0) {
        await _loadChapter(_chapterIndex - 1, restoreProgress: 1);
      } else {
        _showControlsTemporarily();
      }
      return;
    }
    final pageStep = _usesTwoPageLayout ? 2 : 1;
    if (_pageIndex >= pageStep) {
      _setPagedIndex(_pageIndex - pageStep, jumpPageView: true);
    } else if (_chapterIndex > 0) {
      await _loadChapter(_chapterIndex - 1, restoreProgress: 1);
    } else {
      _showControlsTemporarily();
    }
  }

  int _currentBookmarkOffset(String text) {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      final pages = _verticalLayouts[_chapterIndex]?.pages;
      if (pages != null && pages.isNotEmpty) {
        return _verticalCanonicalOffset ?? pages.first.startOffset;
      }
    } else if (_paginatedPages.isNotEmpty) {
      return _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)]
          .startOffset;
    }
    return (_scrollProgress.value * text.length).round().clamp(0, text.length);
  }

  String? get _currentBookmarkAnchorKey {
    final content = _content;
    if (content == null || _chapters.isEmpty) return null;
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: _chapters[_chapterIndex].title,
    );
    final offset = _currentBookmarkOffset(text);
    return '${_chapters[_chapterIndex].id}:$offset';
  }

  Future<void> _toggleCurrentBookmark() async {
    final shelfBookId = _shelfBookId;
    final content = _content;
    if (_bookmarkBusy || content == null || _chapters.isEmpty) return;
    if (shelfBookId == null) {
      showSideToast(
        context,
        context.l10n.readerBookmarkRequiresShelf,
        duration: const Duration(milliseconds: 1900),
        icon: Icons.library_add_rounded,
        kind: SideToastKind.warning,
      );
      return;
    }
    final text = readableBookSourceChapterText(
      content,
      fallbackTitle: _chapters[_chapterIndex].title,
    );
    final offset = _currentBookmarkOffset(text);
    final anchorKey = '${_chapters[_chapterIndex].id}:$offset';
    Bookmark? existing;
    for (final bookmark in _bookmarks) {
      if (bookmark.anchorKey == anchorKey) {
        existing = bookmark;
        break;
      }
    }
    _updateReaderState(() => _bookmarkBusy = true);
    try {
      if (existing != null) {
        final existingId = existing.id!;
        await _bookmarkDao.deleteBookmark(existingId);
        if (!mounted) return;
        _updateReaderState(() {
          _bookmarks = _bookmarks
              .where((bookmark) => bookmark.id != existingId)
              .toList(growable: false);
        });
        showSideToast(
          context,
          context.l10n.bookmarkRemoved,
          duration: const Duration(milliseconds: 1600),
          icon: Icons.bookmark_remove_rounded,
          kind: SideToastKind.success,
        );
        return;
      }
      final excerptEnd = (offset + 120).clamp(offset, text.length);
      final excerpt = text
          .substring(offset, excerptEnd)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final locator = CanonicalLocator.fromComponents(
        format: content.contentType == 'text/html'
            ? BookFormat.html
            : BookFormat.txt,
        chapterId: _chapters[_chapterIndex].id,
        offset: offset,
        excerpt: excerpt,
        progression: text.isEmpty ? 0 : offset / text.length,
      );
      final bookmark = Bookmark(
        bookId: shelfBookId,
        pageNumber: _chapterIndex,
        canonicalLocator: LocatorCodec.encodeCanonicalLocator(locator),
        anchorKey: anchorKey,
        chapterIndex: _chapterIndex,
        chapterTitle: _chapters[_chapterIndex].title,
        excerpt: excerpt,
      );
      final id = await _bookmarkDao.insertBookmark(bookmark);
      if (!mounted) return;
      _updateReaderState(() {
        _bookmarks = [..._bookmarks, bookmark.copyWith(id: id)]
          ..sort(
            (a, b) => (a.chapterIndex ?? a.pageNumber).compareTo(
              b.chapterIndex ?? b.pageNumber,
            ),
          );
      });
      showSideToast(
        context,
        context.l10n.bookmarkAdded,
        duration: const Duration(milliseconds: 1600),
        icon: Icons.bookmark_added_rounded,
        kind: SideToastKind.success,
      );
    } catch (error) {
      debugPrint('toggle source bookmark failed: $error');
    } finally {
      if (mounted) _updateReaderState(() => _bookmarkBusy = false);
    }
  }

  Future<void> _deleteBookmark(Bookmark bookmark) async {
    final id = bookmark.id;
    if (id == null) return;
    await _bookmarkDao.deleteBookmark(id);
    if (!mounted) return;
    _updateReaderState(() {
      _bookmarks = _bookmarks
          .where((candidate) => candidate.id != id)
          .toList(growable: false);
    });
    showSideToast(
      context,
      context.l10n.bookmarkRemoved,
      duration: const Duration(milliseconds: 1600),
      icon: Icons.bookmark_remove_rounded,
      kind: SideToastKind.success,
    );
  }

  Future<void> _jumpToBookmark(Bookmark bookmark) async {
    final raw = bookmark.canonicalLocator;
    final locator = raw == null
        ? null
        : LocatorCodec.decodeCanonicalLocator(raw);
    final chapterId = locator?.chapterId ?? locator?.textAnchor?.chapterId;
    var chapterIndex = chapterId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0) {
      chapterIndex = (bookmark.chapterIndex ?? bookmark.pageNumber).clamp(
        0,
        _chapters.length - 1,
      );
    }
    _restoreTextOffset = locator?.textAnchor?.startOffsetUtf16;
    if (_pageMode == BookSourcePageMode.verticalScroll && !_scrollByChapter) {
      await _jumpToVerticalChapter(
        chapterIndex,
        textOffset: _restoreTextOffset,
        progress: locator?.progression ?? 0,
      );
      return;
    }
    await _loadChapter(
      chapterIndex,
      restoreProgress: locator?.progression ?? 0,
    );
  }

  Future<void> _jumpToAnnotation(BookNote annotation) {
    final chapterId = readerAnnotationChapterId(annotation);
    var chapterIndex = chapterId == null
        ? -1
        : _chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0 && annotation.chapter.trim().isNotEmpty) {
      chapterIndex = _chapters.indexWhere(
        (chapter) => chapter.title.trim() == annotation.chapter.trim(),
      );
    }
    return _jumpToBookmark(
      Bookmark(
        bookId: annotation.bookId,
        pageNumber: annotation.pageNumber ?? 0,
        canonicalLocator: annotation.canonicalLocator,
        chapterIndex: chapterIndex < 0 ? null : chapterIndex,
        chapterTitle: annotation.chapter,
        excerpt: annotation.content,
      ),
    );
  }

  Future<void> _showCatalog() async {
    if (_chapters.isEmpty) return;
    _controlsTimer?.cancel();
    // Prepared with the catalog so the interaction frame only mounts the
    // sheet instead of allocating one navigation model per chapter.
    final navigationChapters = _navigationChapters;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: _readerTheme.shadow.withValues(
        alpha: _readerTheme.brightness == Brightness.dark ? 0.72 : 0.38,
      ),
      showDragHandle: false,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.86,
          child: ReaderNavigationSheet(
            palette: _readerTheme,
            chapters: navigationChapters,
            currentChapterIndex: _chapterIndex,
            bookmarks: _bookmarks,
            annotations: _annotations,
            currentAnchorKey: _currentBookmarkAnchorKey,
            onChapterSelected: (index) {
              Navigator.of(sheetContext).pop();
              if (_pageMode == BookSourcePageMode.verticalScroll &&
                  !_scrollByChapter) {
                unawaited(_jumpToVerticalChapter(index));
              } else {
                unawaited(_loadChapter(index));
              }
            },
            onBookmarkSelected: (bookmark) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToBookmark(bookmark));
            },
            onBookmarkDeleted: (bookmark) async {
              await _deleteBookmark(bookmark);
              if (mounted) setSheetState(() {});
            },
            onAnnotationSelected: (annotation) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToAnnotation(annotation));
            },
            onAnnotationDeleted: (annotation) async {
              await _deleteAnnotation(annotation);
              if (mounted) setSheetState(() {});
            },
          ),
        ),
      ),
    );
  }
}
