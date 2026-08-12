part of 'native_reader_page.dart';

extension _NativeReaderNavigation on _NativeReaderPageState {
  _ReaderPageData _bookmarkPageFor(List<_ReaderPageData> pages) {
    if (_pageMode == NativePageMode.verticalScroll) {
      if (_visibleContinuousParts.isNotEmpty &&
          _visibleChapters.isNotEmpty &&
          _chapterIndex < _visibleChapters.length) {
        final partIndex = _pageIndex.clamp(
          0,
          _visibleContinuousParts.length - 1,
        );
        final offset =
            _verticalCanonicalOffset ??
            _visibleContinuousParts[partIndex].content.startOffset;
        return _ReaderPageData(
          text: '',
          startOffset: offset,
          endOffset: offset,
        );
      }
    }
    return pages[_pageIndex.clamp(0, pages.length - 1)];
  }

  String _bookmarkAnchorKey(_NativeChapter chapter, _ReaderPageData page) =>
      '${chapter.id}:${page.startOffset}';

  String _bookmarkExcerpt(_NativeChapter chapter, _ReaderPageData page) {
    final start = page.startOffset.clamp(0, chapter.plainText.length);
    final end = (start + 120).clamp(start, chapter.plainText.length);
    return chapter.plainText
        .substring(start, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _toggleBookmark(
    _NativeChapter chapter,
    _ReaderPageData page,
  ) async {
    final bookId = widget.book.id;
    if (bookId == null || _bookmarkBusy) return;
    final anchorKey = _bookmarkAnchorKey(chapter, page);
    Bookmark? existing;
    for (final bookmark in _bookmarks) {
      if (bookmark.anchorKey == anchorKey) {
        existing = bookmark;
        break;
      }
    }
    _setReaderState(() => _bookmarkBusy = true);
    try {
      if (existing != null) {
        final existingId = existing.id!;
        await _bookmarkDao.deleteBookmark(existingId);
        if (!mounted) return;
        _setReaderState(() {
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

      final excerpt = _bookmarkExcerpt(chapter, page);
      final locator = CanonicalLocator.fromComponents(
        format: BookFormat.fromFileExtension(widget.book.format),
        chapterId: chapter.id,
        offset: page.startOffset,
        excerpt: excerpt,
        progression: chapter.plainText.isEmpty
            ? 0
            : page.startOffset / chapter.plainText.length,
      );
      final bookmark = Bookmark(
        bookId: bookId,
        pageNumber: _chapterIndex,
        canonicalLocator: LocatorCodec.encodeCanonicalLocator(locator),
        anchorKey: anchorKey,
        chapterIndex: _chapterIndex,
        chapterTitle: chapter.title,
        excerpt: excerpt,
      );
      final id = await _bookmarkDao.insertBookmark(bookmark);
      if (!mounted) return;
      _setReaderState(() {
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
      debugPrint('toggle bookmark failed: $error');
    } finally {
      if (mounted) _setReaderState(() => _bookmarkBusy = false);
    }
  }

  Future<void> _deleteBookmark(Bookmark bookmark) async {
    final id = bookmark.id;
    if (id == null) return;
    await _bookmarkDao.deleteBookmark(id);
    if (!mounted) return;
    _setReaderState(() {
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

  Future<void> _jumpToBookmark(
    Bookmark bookmark,
    List<_NativeChapter> chapters,
  ) async {
    final locatorRaw = bookmark.canonicalLocator;
    final locator = locatorRaw == null
        ? null
        : LocatorCodec.decodeCanonicalLocator(locatorRaw);
    final chapterId = locator?.chapterId ?? locator?.textAnchor?.chapterId;
    var chapterIndex = chapterId == null
        ? -1
        : chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0) {
      chapterIndex = (bookmark.chapterIndex ?? bookmark.pageNumber).clamp(
        0,
        chapters.length - 1,
      );
    }
    _anchorOffset = locator?.textAnchor?.startOffsetUtf16;
    _restoreAnchorAfterLayout = true;
    await _setChapter(
      chapterIndex,
      chapters.length,
      recenterContinuousScroll: false,
    );
    if (_pageMode != NativePageMode.verticalScroll) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _verticalViewportSize.isEmpty) return;
    final parts = _continuousPartsFor(
      chapters[chapterIndex],
      _verticalViewportSize,
    );
    final anchor = _anchorOffset ?? 0;
    final targetPage = parts.indexWhere(
      (part) =>
          anchor >= part.content.startOffset && anchor < part.content.endOffset,
    );
    final safePage = (targetPage < 0 ? parts.length - 1 : targetPage).clamp(
      0,
      parts.length - 1,
    );
    _setReaderState(() {
      _pageIndex = safePage;
      _visibleContinuousParts = parts;
      _visiblePages = parts.map((part) => part.content).toList(growable: false);
      _restoreAnchorAfterLayout = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (_scrollByChapter && _verticalPageScrollController.isAttached) {
      _verticalPageScrollController.jumpTo(index: safePage);
    } else if (_verticalChapterScrollController.isAttached) {
      _verticalChapterScrollController.jumpTo(index: chapterIndex);
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scrollContinuousAnchorIntoView(
      chapters[chapterIndex],
      parts,
      safePage,
      anchor,
    );
  }

  Future<void> _jumpToNavigationChapter(
    ReaderNavigationChapter navigation,
    List<_NativeChapter> chapters,
  ) async {
    final navigationPosition = _navigationChapters.indexOf(navigation);
    _lastNavigationJumpPosition = navigationPosition < 0
        ? null
        : navigationPosition;
    final chapterIndex = navigation.index.clamp(0, chapters.length - 1);
    await _loadIndexedChapterWindow(chapters, chapterIndex);
    if (!mounted) return;
    final chapter = chapters[chapterIndex];
    final offset = chapter.navigationOffsetFor(navigation) ?? 0;
    final excerptEnd = (offset + 72).clamp(offset, chapter.plainText.length);
    final locator = CanonicalLocator.fromComponents(
      format: BookFormat.fromFileExtension(widget.book.format),
      chapterId: chapter.id,
      offset: offset,
      excerpt: chapter.plainText.substring(offset, excerptEnd),
      progression: chapter.plainText.isEmpty
          ? 0
          : offset / chapter.plainText.length,
    );
    final alreadyInChapter = chapterIndex == _chapterIndex;
    await _jumpToBookmark(
      Bookmark(
        bookId: widget.book.id ?? 0,
        pageNumber: chapterIndex,
        chapterIndex: chapterIndex,
        chapterTitle: navigation.title,
        canonicalLocator: LocatorCodec.encodeCanonicalLocator(locator),
      ),
      chapters,
    );
    if (alreadyInChapter &&
        mounted &&
        _pageMode != NativePageMode.verticalScroll) {
      _setReaderState(() {});
    }
  }

  Future<void> _jumpToAnnotation(
    BookNote annotation,
    List<_NativeChapter> chapters,
  ) {
    final chapterId = readerAnnotationChapterId(annotation);
    var chapterIndex = chapterId == null
        ? -1
        : chapters.indexWhere((chapter) => chapter.id == chapterId);
    if (chapterIndex < 0 && annotation.chapter.trim().isNotEmpty) {
      chapterIndex = chapters.indexWhere(
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
      chapters,
    );
  }

  Future<void> _showTableOfContents(
    List<_NativeChapter> chapters, {
    String? currentAnchorKey,
  }) async {
    // Prepared once while the book is loading. Opening the sheet must not
    // allocate one navigation model per chapter on the interaction frame.
    final navigationChapters = _navigationChapters;
    final navigationCatalog = _navigationCatalog;
    if (navigationCatalog == null) return;
    final initialNavigationPosition = navigationCatalog
        .initialPositionForChapter(_chapterIndex);
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
            catalog: navigationCatalog,
            currentChapterIndex: _chapterIndex,
            currentChapterOffset: _anchorOffset,
            currentChapterText: chapters[_chapterIndex].plainText,
            currentNavigationPosition: initialNavigationPosition,
            resolveCurrentNavigationPosition: () =>
                _currentNavigationPosition(navigationCatalog, chapters),
            bookmarks: _bookmarks,
            annotations: _annotations,
            currentAnchorKey: currentAnchorKey,
            onChapterSelected: (index) {
              Navigator.of(sheetContext).pop();
              unawaited(
                _setChapter(
                  index,
                  chapters.length,
                  recenterContinuousScroll: true,
                ),
              );
            },
            onNavigationChapterSelected: (navigation) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToNavigationChapter(navigation, chapters));
            },
            onBookmarkSelected: (bookmark) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToBookmark(bookmark, chapters));
            },
            onBookmarkDeleted: (bookmark) async {
              await _deleteBookmark(bookmark);
              if (mounted) setSheetState(() {});
            },
            onAnnotationSelected: (annotation) {
              Navigator.of(sheetContext).pop();
              unawaited(_jumpToAnnotation(annotation, chapters));
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

  int _currentNavigationPosition(
    ReaderNavigationCatalog catalog,
    List<_NativeChapter> chapters,
  ) {
    if (_chapterIndex < 0 || _chapterIndex >= chapters.length) return -1;
    final chapter = chapters[_chapterIndex];
    final lastJumpPosition = _lastNavigationJumpPosition;
    if (lastJumpPosition != null &&
        lastJumpPosition >= 0 &&
        lastJumpPosition < catalog.chapters.length &&
        _pageMode != NativePageMode.verticalScroll &&
        _visiblePages.isNotEmpty) {
      final target = catalog.chapters[lastJumpPosition];
      if (target.index == _chapterIndex) {
        final targetOffset = chapter.navigationOffsetFor(target) ?? 0;
        final firstPage = _pageIndex.clamp(0, _visiblePages.length - 1);
        final lastPage = _visibleUsesTwoPageLayout
            ? (firstPage + 1).clamp(firstPage, _visiblePages.length - 1)
            : firstPage;
        if (targetOffset >= _visiblePages[firstPage].startOffset &&
            targetOffset < _visiblePages[lastPage].endOffset) {
          return lastJumpPosition;
        }
      }
    }
    final currentOffset = (_anchorOffset ?? 0).clamp(
      0,
      chapter.plainText.length,
    );
    final chapterPositions = catalog.positionsByChapter[_chapterIndex];
    if (chapterPositions == null || chapterPositions.isEmpty) {
      return catalog.lastPositionBeforeChapter(_chapterIndex);
    }
    var selectedPosition = catalog.lastPositionBeforeChapter(_chapterIndex);
    var selectedOffset = -1;
    for (final position in chapterPositions) {
      final target = catalog.chapters[position];
      final targetOffset = chapter.navigationOffsetFor(target) ?? 0;
      if (targetOffset <= currentOffset && targetOffset >= selectedOffset) {
        selectedPosition = position;
        selectedOffset = targetOffset;
      }
    }
    return selectedPosition;
  }
}
