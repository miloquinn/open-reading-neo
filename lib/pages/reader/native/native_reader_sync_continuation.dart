part of 'native_reader_page.dart';

extension _NativeReaderSyncContinuation on _NativeReaderPageState {
  void _markReadingPositionChanged() {
    if (_suppressProgressSyncEvents) return;
    _progressSyncEventPending = true;
  }

  void _startSyncContinuationWatch() {
    if (widget.book.id == null) return;
    unawaited(_refreshRemoteProgressCandidate());
    _syncContinuationTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refreshRemoteProgressCandidate()),
    );
  }

  Future<void> _refreshRemoteProgressCandidate() async {
    final bookId = widget.book.id;
    if (bookId == null || !mounted) return;
    final sync = Provider.of<WebDavSyncController?>(context, listen: false);
    if (sync?.autoSync != true || sync?.scope.progress != true) {
      if (_remoteProgressCandidate != null) {
        _setReaderState(() => _remoteProgressCandidate = null);
      }
      return;
    }
    final candidate = await ReadingProgressSyncService.instance
        .remoteCandidateFor(bookId);
    if (!mounted) return;
    if (candidate == null) {
      if (_remoteProgressCandidate != null) {
        _setReaderState(() => _remoteProgressCandidate = null);
      }
      return;
    }
    final candidateId = readingProgressCandidateId(
      candidate.snapshot.toEventJson(),
    );
    final currentCandidateId = _remoteProgressCandidate == null
        ? null
        : readingProgressCandidateId(
            _remoteProgressCandidate!.snapshot.toEventJson(),
          );
    if (candidateId == _dismissedRemoteProgressEventId ||
        candidateId == currentCandidateId) {
      return;
    }
    _setReaderState(() => _remoteProgressCandidate = candidate);
  }

  bool _candidateMatchesCurrentContent(
    ReadingProgressRemoteCandidate candidate,
  ) => ReadingProgressSyncService.instance.candidateMatchesBook(
    candidate,
    _activeBook.copyWith(contentHash: _currentContentSignature),
  );

  Future<void> _applyRemoteProgressCandidate() async {
    final candidate = _remoteProgressCandidate;
    final bookId = widget.book.id;
    if (candidate == null || bookId == null || _loadedChapters.isEmpty) return;
    if (!_candidateMatchesCurrentContent(candidate)) {
      showSideToast(
        context,
        TxtEditorCopy.of(context).remoteProgressVersionMismatch,
        kind: SideToastKind.warning,
      );
      return;
    }
    _suppressProgressSyncEvents = true;
    _progressSyncEventPending = false;
    try {
      final applied = await ReadingProgressSyncService.instance.applyCandidate(
        bookId,
        candidate,
      );
      if (!applied) return;
      await _jumpToBookmark(
        Bookmark(
          bookId: bookId,
          pageNumber: candidate.snapshot.currentPage,
          chapterIndex: candidate.snapshot.currentPage,
          canonicalLocator: candidate.snapshot.canonicalLocator,
        ),
        _loadedChapters,
      );
      if (!mounted) return;
      _setReaderState(() {
        _remoteProgressCandidate = null;
        _showReturnToLocalPosition = true;
      });
    } finally {
      _suppressProgressSyncEvents = false;
    }
  }

  Future<void> _returnToPreSyncPosition() async {
    final bookId = widget.book.id;
    final snapshot = bookId == null
        ? null
        : ReadingProgressSyncService.instance.preSyncPositionFor(bookId);
    if (bookId == null || snapshot == null || _loadedChapters.isEmpty) return;
    _suppressProgressSyncEvents = true;
    _progressSyncEventPending = false;
    try {
      final restored = await ReadingProgressSyncService.instance
          .restorePreSyncPosition(bookId);
      if (restored == null) {
        if (mounted) {
          _setReaderState(() => _showReturnToLocalPosition = false);
          showSideToast(context, TxtEditorCopy.of(context).locationUnavailable);
        }
        return;
      }
      await _jumpToBookmark(
        Bookmark(
          bookId: bookId,
          pageNumber: snapshot.currentPage,
          chapterIndex: snapshot.currentPage,
          canonicalLocator: snapshot.canonicalLocator,
        ),
        _loadedChapters,
      );
      if (mounted) {
        _setReaderState(() => _showReturnToLocalPosition = false);
      }
    } finally {
      _suppressProgressSyncEvents = false;
    }
  }

  Future<void> _dismissRemoteProgressCandidate() async {
    final candidate = _remoteProgressCandidate;
    if (candidate == null) return;
    final bookId = widget.book.id;
    if (bookId != null) {
      await ReadingProgressSyncService.instance.snoozeCandidate(
        bookId,
        candidate,
      );
    }
    if (!mounted) return;
    _setReaderState(() {
      _dismissedRemoteProgressEventId = readingProgressCandidateId(
        candidate.snapshot.toEventJson(),
      );
      _remoteProgressCandidate = null;
    });
  }

  Widget _buildSyncContinuationBanner() {
    final candidate = _remoteProgressCandidate;
    final copy = TxtEditorCopy.of(context);
    return Positioned(
      left: 16,
      right: 16,
      top: 12,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: _readerTheme.surface.withValues(alpha: 0.96),
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Icon(Icons.sync_rounded, color: _readerTheme.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    candidate != null
                        ? copy.remoteProgressAvailable
                        : copy.remoteProgressApplied,
                    style: TextStyle(
                      color: _readerTheme.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (candidate != null) ...[
                  TextButton(
                    onPressed: () =>
                        unawaited(_dismissRemoteProgressCandidate()),
                    child: Text(copy.later),
                  ),
                  FilledButton.tonal(
                    onPressed: () => unawaited(_applyRemoteProgressCandidate()),
                    child: Text(copy.continueReading),
                  ),
                ] else
                  TextButton(
                    onPressed: () => unawaited(_returnToPreSyncPosition()),
                    child: Text(copy.returnToLocalPosition),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
