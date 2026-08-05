part of 'native_reader_page.dart';

extension _NativeReaderContinuousLayout on _NativeReaderPageState {
  void _scheduleInitialContinuousScrollRestore(Size viewport) {
    if (_initialPositionRestored || _initialPositionRestoreScheduled) return;
    if ((_anchorOffset ?? 0) <= 0) {
      _initialPositionRestored = true;
      return;
    }
    _initialPositionRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controllerReady = _scrollByChapter
          ? _verticalPageScrollController.isAttached
          : _verticalChapterScrollController.isAttached;
      if (!controllerReady) {
        _initialPositionRestoreScheduled = false;
        _scheduleInitialContinuousScrollRestore(viewport);
        return;
      }
      final chapter = _loadedChapters[_chapterIndex];
      final parts = _continuousPartsFor(chapter, viewport);
      var precedingExtent = 0.0;
      for (final part in parts.take(_pageIndex)) {
        precedingExtent += _measureContinuousPartExtent(
          chapter,
          part,
          viewport,
        );
      }
      if (!_scrollByChapter && precedingExtent > 0) {
        unawaited(
          _verticalChapterOffsetController
              .animateScroll(
                offset: precedingExtent,
                duration: const Duration(milliseconds: 1),
              )
              .catchError((error) {
                debugPrint('restore continuous reader offset failed: $error');
              }),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _scrollContinuousAnchorIntoView(
            chapter,
            parts,
            _pageIndex,
            _anchorOffset ?? parts[_pageIndex].content.startOffset,
          ).whenComplete(() {
            if (!mounted) return;
            _setReaderState(() {
              _initialPositionRestored = true;
              _initialPositionRestoreScheduled = false;
            });
          }),
        );
      });
    });
  }

  double _measureContinuousPartExtent(
    _NativeChapter chapter,
    _ContinuousReaderPart part,
    Size viewport,
  ) {
    if (part.content.isChapterTitle) return _verticalPageExtentFor(viewport);
    final imageExtent = part.imageBlockIndex == null ? 0.0 : 444.0;
    if (part.content.text.isEmpty) return imageExtent;
    final painter =
        _readerTextFlowStyle(
            direction: _verticalTextDirection,
            textScaler: _verticalTextScaler,
          ).createPainter(
            part.content.buildSpan(
              style: _readerTextStyle,
              sourceSpanBuilder: (start, end) =>
                  _styledSpanForRange(chapter, start, end, _readerTextStyle),
            ),
          )
          ..layout(
            maxWidth: readerTextContentWidth(viewport.width, _horizontalMargin),
          );
    final extent = painter.height + imageExtent;
    painter.dispose();
    return extent;
  }
}
