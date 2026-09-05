part of 'native_reader_page.dart';

extension _NativeReaderTxtEditing on _NativeReaderPageState {
  bool get _canEditCurrentTxt =>
      !kIsWeb &&
      !_activeBook.isOnline &&
      _activeBook.format.toLowerCase() == 'txt' &&
      _chapterIndex >= 0 &&
      _chapterIndex < _loadedChapters.length;

  Future<void> _editCurrentTxtChapter() async {
    if (!_canEditCurrentTxt) return;
    _pauseAutoPageTurn();
    final chapterId = _loadedChapters[_chapterIndex].id;
    final prefaceTitle = context.l10n.readerPrefaceTitle;
    // Freeze the legacy content-derived identity before the first edit.
    await stableBookUid(_activeBook);
    if (!mounted) return;
    Book? committedBook;
    final outcome = await Navigator.of(context).push<TxtChapterEditorOutcome>(
      MaterialPageRoute(
        builder: (context) => TxtChapterEditorPage(
          book: _activeBook,
          chapterId: chapterId,
          prefaceTitle: prefaceTitle,
          service: TxtEditService(),
          onCommitMetadata: (commit) async {
            committedBook = await _txtEditReferenceService.commitRevision(
              book: _activeBook,
              commit: commit,
            );
          },
        ),
      ),
    );
    if (!mounted || outcome == null) return;

    final file = File(_activeBook.filePath);
    final stat = await file.stat();
    final contentHash = committedBook?.contentHash;
    if (contentHash == null || contentHash.isEmpty) {
      throw StateError('TXT edit committed without a content revision');
    }
    final values = (committedBook ?? _activeBook).toMap()
      ..['file_modified_time'] = stat.modified.millisecondsSinceEpoch
      ..['content_hash'] = contentHash
      ..['cached_content'] = null
      ..['cached_pages'] = null
      ..['table_of_contents'] = null;
    final updatedBook = Book.fromMap(values);
    _activeBook = updatedBook;
    _currentContentSignature = contentHash;

    LibraryEventBus().notifyLibraryChanged();
    TxtContentChangeBus.instance.notify(
      TxtContentChanged(
        book: updatedBook,
        contentHash: contentHash,
        modifiedAt: stat.modified,
        origin: outcome.result == TxtChapterEditorResult.restored
            ? TxtContentChangeOrigin.restore
            : TxtContentChangeOrigin.localEdit,
      ),
    );
    clearNativeReaderMemoryCaches();
    if (widget.book.id case final bookId?) {
      try {
        await (widget.paginationCacheDao ?? PaginationCacheDao()).deleteForBook(
          bookId,
        );
      } catch (error) {
        debugPrint('TXT pagination cache cleanup failed: $error');
      }
    }
    _pageCache = <String, List<_ReaderPageData>>{};
    _parsedNavigationChapters = const [];
    _navigationChapters = const [];
    _navigationCatalog = ReaderNavigationCatalog(const []);
    _savedChapterId = chapterId;
    _anchorOffset = null;
    _verticalCanonicalOffset = null;
    _pageIndex = 0;
    _contentEditRevision++;
    _resetHorizontalPagingWindow(_chapterIndex);
    final refreshed = _prepareLoadedChapters(_loadBook());
    _chaptersFuture = refreshed;
    try {
      final chapters = await refreshed;
      final chapterIndex = chapters.indexWhere(
        (candidate) => candidate.id == chapterId,
      );
      final chapter = chapterIndex < 0 ? null : chapters[chapterIndex];
      final quote = outcome.anchorQuote;
      if (chapter != null && quote.isNotEmpty) {
        await chapter.prepareReplacementAsync(_replaceRules);
        final first = chapter.plainText.indexOf(quote);
        if (first >= 0 && chapter.plainText.indexOf(quote, first + 1) < 0) {
          final verifiedOffset = first + outcome.offsetWithinQuote;
          _anchorOffset = verifiedOffset;
          _verticalCanonicalOffset = verifiedOffset;
        }
      }
    } catch (error) {
      debugPrint('TXT reader refresh failed after committed edit: $error');
    }
    await Future.wait<void>([_loadBookmarks(), _loadAnnotations()]);
    _setReaderState(() {});
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(TxtEditorCopy.of(context).saved)));
    }
  }
}
