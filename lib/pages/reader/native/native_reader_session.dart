part of 'native_reader_page.dart';

extension _NativeReaderSession on _NativeReaderPageState {
  void _startReadingSession() {
    _readingSessionStartedAt ??= DateTime.now();
  }

  Future<void> _flushReadingSession() async {
    final startedAt = _readingSessionStartedAt;
    if (startedAt == null) return;

    final endedAt = DateTime.now();
    final pagesRead = _sessionPagesRead;
    _readingSessionStartedAt = null;
    _sessionPagesRead = 0;

    try {
      await _readingStatsDao.recordReadingSession(
        startTime: startedAt,
        endTime: endedAt,
        bookId: widget.book.id,
        pagesRead: pagesRead,
      );
    } catch (error) {
      debugPrint('record native reading session failed: $error');
    }
  }

  Future<void> _loadBookmarks() async {
    final bookId = widget.book.id;
    if (bookId == null) return;
    try {
      final bookmarks = await _bookmarkDao.getBookmarksForBook(bookId);
      if (mounted) _setReaderState(() => _bookmarks = bookmarks);
    } catch (error) {
      debugPrint('load bookmarks failed: $error');
    }
  }

  Future<void> _loadAnnotations() async {
    final bookId = widget.book.id;
    if (bookId == null) return;
    try {
      final annotations = await _bookNoteDao.selectBookNotesByBookId(bookId);
      if (mounted) {
        _setReaderState(() {
          _annotations = annotations;
          _annotationRevision++;
        });
      }
    } catch (error) {
      debugPrint('load reader annotations failed: $error');
    }
  }

  Future<void> _saveTextAnnotation(
    ReaderSelectionSnapshot selection,
    ReaderAnnotationEditorResult annotation,
  ) async {
    final bookId = widget.book.id;
    if (bookId == null || _annotationBusy) return;
    _setReaderState(() => _annotationBusy = true);
    try {
      final now = DateTime.now();
      final note = BookNote(
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
      );
      await _bookNoteDao.insertBookNote(note);
      await _loadAnnotations();
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
      debugPrint('save reader annotation failed: $error');
    } finally {
      if (mounted) _setReaderState(() => _annotationBusy = false);
    }
  }

  Future<void> _deleteAnnotation(BookNote annotation) async {
    final id = annotation.id;
    if (id == null) return;
    await _bookNoteDao.deleteBookNoteById(id);
    if (!mounted) return;
    _setReaderState(() {
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

  Future<void> _exitReader() async {
    if (_exitInProgress) return;
    _exitInProgress = true;
    BookOpenTransition.beginExit();
    unawaited(_flushReadingSession());
    await _persistCurrentReaderPosition(reason: 'exit');
    await _flushPendingPositionSave();
    debugPrint('[reader-progress] exit position queue flushed');
    if (!mounted) return;
    _setReaderState(() => _exitPositionCommitted = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    debugPrint('[reader-progress] pop reader after exit position commit');
    Navigator.of(context).pop();
  }

  Future<void> _persistCurrentReaderPosition({required String reason}) {
    final chapters = _loadedChapters;
    if (chapters.isEmpty) return Future<void>.value();

    // PageView intentionally defers the current page while a drag or fling is
    // active. A route exit must commit that exact target before flushing the
    // write queue, otherwise the previous chapter opening is restored.
    if (_pageMode == NativePageMode.horizontalSlide &&
        _pendingHorizontalPage != null) {
      final pending = _pendingHorizontalPage!;
      debugPrint(
        '[reader-progress] commit pending page on $reason '
        'chapter=${pending.page.chapterIndex} page=${pending.page.pageIndex} '
        'offset=${pending.page.content.startOffset}',
      );
      _publishPendingHorizontalPage(chapters);
      return Future<void>.value();
    }

    if (_visiblePages.isEmpty) return Future<void>.value();
    final chapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
    final pageIndex = _pageIndex.clamp(0, _visiblePages.length - 1);
    final page = _visiblePages[pageIndex];
    debugPrint(
      '[reader-progress] save visible page on $reason '
      'chapter=$chapterIndex page=$pageIndex offset=${page.startOffset}',
    );
    return _saveCanonicalProgress(chapters[chapterIndex], page, chapterIndex);
  }

  Future<void> _flushPendingPositionSave() => _positionSaveQueue.flush();
}
