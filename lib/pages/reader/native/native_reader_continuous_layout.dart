part of 'native_reader_page.dart';

extension _NativeReaderContinuousLayout on _NativeReaderPageState {
  void _scheduleInitialContinuousScrollRestore(Size viewport) {
    if (_initialPositionRestored || _initialPositionRestoreScheduled) return;
    final chapterIndex = _chapterIndex;
    final chapter = _loadedChapters[chapterIndex];
    final parts = _continuousPartsFor(chapter, viewport);
    final partIndex = _pageIndex;
    final anchor = _anchorOffset ?? 0;
    final centerAnchor = _restoreContinuousAnchorCentered;
    final revision = _verticalScrollRevision;
    _initialPositionRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _verticalScrollRevision) return;
      final controller = _usesChapterScopedVerticalList
          ? _verticalPageScrollController
          : _verticalChapterScrollController;
      if (!controller.isAttached) {
        _initialPositionRestoreScheduled = false;
        _scheduleInitialContinuousScrollRestore(viewport);
        return;
      }
      controller.jumpTo(
        index: _usesChapterScopedVerticalList ? partIndex : chapterIndex,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _verticalScrollRevision) return;
        unawaited(
          _scrollContinuousAnchorIntoView(
            chapter,
            parts,
            partIndex,
            anchor,
            centerInViewport: centerAnchor,
          ).then((restored) {
            if (!mounted || revision != _verticalScrollRevision) return;
            _initialPositionRestoreScheduled = false;
            if (!restored) {
              _scheduleInitialContinuousScrollRestore(viewport);
              return;
            }
            _setReaderState(() {
              _initialPositionRestored = true;
              _restoreContinuousAnchorCentered = false;
            });
            unawaited(
              _saveCanonicalProgress(
                chapter,
                _ReaderPageData(
                  text: '',
                  startOffset: anchor,
                  endOffset: anchor,
                ),
                chapterIndex,
              ),
            );
            _continuousRestoreCompletion?.complete();
            _continuousRestoreCompletion = null;
          }),
        );
      });
    });
  }
}
