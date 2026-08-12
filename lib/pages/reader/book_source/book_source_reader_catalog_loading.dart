part of 'book_source_reader_page.dart';

extension _BookSourceReaderCatalogLoading on _BookSourceReaderPageState {
  Future<void> _initialize() async {
    _updateReaderState(() {
      _loadingCatalog = true;
      _error = null;
    });
    try {
      await ReplaceRuleService.instance.load();
      final results = await Future.wait<Object?>([
        _client.getChapters(
          widget.source,
          widget.book.id,
          sourceVariables: widget.book.sourceVariables,
        ),
        widget.progressStore.load(
          sourceId: widget.source.id,
          bookId: widget.book.id,
        ),
        _readerSettingsStore.load(),
        _readerSettingsStore.loadScrollByChapter(),
        _customThemeStore.loadAll(),
        _themeOrderStore.load(),
        _readerSettingsStore.loadTapZones(),
      ]);
      final rawChapters = [...results[0]! as List<BookSourceChapter>]
        ..sort((a, b) => a.order.compareTo(b.order));
      final chapters = _withReplacedChapterTitles(rawChapters);
      final navigationChapters = _navigationFor(chapters);
      final navigationCatalog = ReaderNavigationCatalog(navigationChapters);
      final saved = results[1] as BookSourceReadingProgress?;
      final settings = results[2]! as ReaderSettings;
      final scrollByChapter = results[3]! as bool;
      final customThemes = results[4] as List<ReaderCustomTheme>;
      final themeOrder = results[5] as List<String>;
      final tapZones = results[6] as ReaderTapZones;
      var initialIndex = saved?.chapterIndex ?? 0;
      if (saved != null && saved.chapterId.isNotEmpty) {
        final byId = chapters.indexWhere(
          (chapter) => chapter.id == saved.chapterId,
        );
        if (byId >= 0) initialIndex = byId;
      }
      if (chapters.isNotEmpty) {
        initialIndex = initialIndex.clamp(0, chapters.length - 1);
      }
      if (!mounted) return;
      ReaderThemes.setCustomThemes(customThemes);
      ReaderThemes.setThemeOrder(themeOrder);
      _updateReaderState(() {
        _rawChapters = rawChapters;
        _chapters = chapters;
        _navigationChapters = navigationChapters;
        _navigationCatalog = navigationCatalog;
        _chapterIndex = initialIndex;
        _fontSize = settings.fontSize;
        _fontWeight = settings.fontWeight;
        _horizontalMargin = settings.horizontalMargin;
        _topMargin = settings.topMargin;
        _bottomMargin = settings.bottomMargin;
        _lineHeight = settings.lineHeight;
        _letterSpacing = settings.letterSpacing;
        _textAlignment = settings.textAlignment;
        _firstLineIndent = settings.firstLineIndent;
        _paragraphSpacing = settings.paragraphSpacing;
        _readerThemeId = ReaderThemes.byId(settings.themeId).id;
        _pageMode = settings.pageMode;
        _pullBookmarkEnabled = settings.pullBookmarkEnabled;
        _tapPageAnimationEnabled = settings.tapPageAnimationEnabled;
        _tapZones = tapZones;
        _tabletTwoPageEnabled = settings.tabletTwoPageEnabled;
        _scrollByChapter = scrollByChapter;
        _loadingCatalog = false;
      });
      unawaited(_syncVolumeKeyPaging());
      if (chapters.isNotEmpty) {
        unawaited(_resolveShelfBook());
        await _loadChapter(
          initialIndex,
          restoreProgress: saved?.chapterProgress ?? 0,
          saveCurrent: false,
        );
      }
    } catch (error) {
      if (!mounted) return;
      _updateReaderState(() {
        _loadingCatalog = false;
        _error = error;
        _controlsVisible = true;
      });
    }
  }

  String _cleanChapterTitle(String title) {
    final cleaned = ReplaceRuleService.instance.apply(
      title,
      bookTitle: widget.book.title,
      sourceName: widget.source.name,
      title: true,
    );
    return cleaned.trim().isEmpty ? title : cleaned;
  }

  List<BookSourceChapter> _withReplacedChapterTitles(
    List<BookSourceChapter> chapters,
  ) => chapters
      .map(
        (chapter) => BookSourceChapter(
          id: chapter.id,
          title: _cleanChapterTitle(chapter.title),
          order: chapter.order,
          updatedAt: chapter.updatedAt,
        ),
      )
      .toList(growable: false);

  List<ReaderNavigationChapter> _navigationFor(
    List<BookSourceChapter> chapters,
  ) => List<ReaderNavigationChapter>.generate(
    chapters.length,
    (index) => ReaderNavigationChapter(
      title: chapters[index].title,
      index: index,
      id: chapters[index].id,
    ),
    growable: false,
  );

  Future<void> _syncVolumeKeyPaging() => ReaderVolumeKeyController.activate(
    owner: this,
    pageTurningAvailable: _pageMode != BookSourcePageMode.verticalScroll,
    onNextPage: () => unawaited(_handleVolumePageTurn(forward: true)),
    onPreviousPage: () => unawaited(_handleVolumePageTurn(forward: false)),
  );

  Future<void> _handleVolumePageTurn({required bool forward}) async {
    if (!mounted ||
        _loadingCatalog ||
        _loadingContent ||
        _pageMode == BookSourcePageMode.verticalScroll) {
      return;
    }
    final imageContent = _content;
    if (imageContent != null && isImageOnlyBookSourceChapter(imageContent)) {
      return;
    }
    if (_pageMode == BookSourcePageMode.pageCurl) {
      final controller = _usesTwoPageLayout
          ? (forward
                ? _spreadForwardPageCurlController
                : _spreadBackwardPageCurlController)
          : _pageCurlController;
      if (forward) {
        await controller.turnForward();
      } else {
        await controller.turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.coverSlide) {
      if (forward) {
        await _coverPageTurnController.turnForward();
      } else {
        await _coverPageTurnController.turnBackward();
      }
      return;
    }
    if (_pageMode == BookSourcePageMode.horizontalSlide &&
        _pageController.hasClients) {
      if (forward) {
        await _pageController.nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } else {
        await _pageController.previousPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    if (forward) {
      await _turnForward();
    } else {
      await _turnBackward();
    }
  }

  Future<void> _saveProgress() {
    if (_chapters.isEmpty || _chapterIndex >= _chapters.length) {
      return Future<void>.value();
    }
    final chapterIndex = _chapterIndex;
    final chapterId = _chapters[chapterIndex].id;
    final chapterCount = _chapters.length;
    final shelfBookId = _shelfBookId;
    var progress = _scrollProgress.value;
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      progress = _verticalPageCount <= 1
          ? 0
          : (_verticalPageIndex / (_verticalPageCount - 1)).clamp(0.0, 1.0);
    } else {
      progress = _pagedReadingProgress(_pageIndex, _pageCount);
    }
    final progressSnapshot = BookSourceReadingProgress(
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      chapterProgress: progress,
      updatedAt: DateTime.now().toUtc(),
    );
    _progressSaveQueue = _progressSaveQueue.then((_) async {
      try {
        await widget.progressStore.save(
          sourceId: widget.source.id,
          bookId: widget.book.id,
          progress: progressSnapshot,
        );
        if (shelfBookId != null) {
          await _shelfService.updateShelfProgress(
            shelfBookId: shelfBookId,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterProgress: progress,
          );
        }
      } catch (error) {
        debugPrint('save source reading progress failed: $error');
      }
    });
    return _progressSaveQueue;
  }

  Future<void> _resolveShelfBook() async {
    Book? shelfBook;
    try {
      shelfBook = await _shelfService.findShelfBook(
        sourceId: widget.source.id,
        sourceBookId: widget.book.id,
      );
    } catch (error) {
      debugPrint('resolve source shelf book failed: $error');
      return;
    }
    if (!mounted) return;
    _updateReaderState(() => _shelfBookId = shelfBook?.id);
    final shelfBookId = _shelfBookId;
    if (shelfBookId == null) return;
    unawaited(ReadingResumeService.markReading(shelfBookId));
    try {
      final results = await Future.wait<Object>([
        _bookmarkDao.getBookmarksForBook(shelfBookId),
        _bookNoteDao.selectBookNotesByBookId(shelfBookId),
      ]);
      if (mounted) {
        _updateReaderState(() {
          _bookmarks = results[0] as List<Bookmark>;
          _annotations = results[1] as List<BookNote>;
          _annotationRevision++;
        });
      }
    } catch (error) {
      debugPrint('load source bookmarks and annotations failed: $error');
    }
  }

  Future<void> _reloadAnnotations() async {
    final bookId = _shelfBookId;
    if (bookId == null) return;
    final annotations = await _bookNoteDao.selectBookNotesByBookId(bookId);
    if (!mounted) return;
    _updateReaderState(() {
      _annotations = annotations;
      _annotationRevision++;
    });
  }

  bool _ensureAnnotationBook() {
    if (_shelfBookId != null) return true;
    showSideToast(
      context,
      context.l10n.readerAnnotationShelfRequired,
      duration: const Duration(milliseconds: 2200),
      icon: Icons.add_to_photos_outlined,
      kind: SideToastKind.info,
    );
    return false;
  }

  Future<void> _saveTextAnnotation(
    ReaderSelectionSnapshot selection,
    ReaderAnnotationEditorResult annotation,
  ) async {
    if (!_ensureAnnotationBook() || _annotationBusy) return;
    final bookId = _shelfBookId!;
    _updateReaderState(() => _annotationBusy = true);
    try {
      final now = DateTime.now();
      await _bookNoteDao.insertBookNote(
        BookNote(
          bookId: bookId,
          content: selection.selectedText,
          cfi: selection.cfiFor(annotation.type),
          canonicalLocator: selection.canonicalLocatorJson,
          chapter: selection.chapterTitle,
          type: annotation.type,
          color: annotation.colorHex,
          readerNote: annotation.note,
          pageNumber: selection.pageIndex,
          startOffset: selection.startOffset,
          endOffset: selection.endOffset,
          createTime: now,
          updateTime: now,
        ),
      );
      await _reloadAnnotations();
      if (!mounted) return;
      showSideToast(
        context,
        context.l10n.readerAnnotationSaved,
        duration: const Duration(milliseconds: 1600),
        icon: annotation.type == readerAnnotationTypeNote
            ? Icons.mode_comment_rounded
            : Icons.auto_awesome_rounded,
        kind: SideToastKind.success,
      );
    } catch (error) {
      debugPrint('save source annotation failed: $error');
    } finally {
      if (mounted) _updateReaderState(() => _annotationBusy = false);
    }
  }

  Future<void> _deleteAnnotation(BookNote annotation) async {
    final id = annotation.id;
    if (id == null) return;
    await _bookNoteDao.deleteBookNoteById(id);
    if (!mounted) return;
    _updateReaderState(() {
      _annotations = _annotations
          .where((candidate) => candidate.id != id)
          .toList(growable: false);
      _annotationRevision++;
    });
    showSideToast(
      context,
      context.l10n.readerAnnotationDeleted,
      duration: const Duration(milliseconds: 1600),
      icon: Icons.delete_outline_rounded,
      kind: SideToastKind.success,
    );
  }
}
