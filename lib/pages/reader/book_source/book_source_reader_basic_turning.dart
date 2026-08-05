part of 'book_source_reader_page.dart';

extension _BookSourceReaderBasicTurning on _BookSourceReaderPageState {
  void _handleTapZoneAction(ReaderTapZoneAction action) {
    if (_annotationInteractionActive) return;
    switch (action) {
      case ReaderTapZoneAction.menu:
        _toggleControls();
      case ReaderTapZoneAction.none:
        break;
      case ReaderTapZoneAction.previousPage:
        // 上下翻页由滚动手势负责，点击翻页保持关闭。
        if (_pageMode == BookSourcePageMode.verticalScroll) return;
        unawaited(_turnFromTap(forward: false));
      case ReaderTapZoneAction.nextPage:
        if (_pageMode == BookSourcePageMode.verticalScroll) return;
        unawaited(_turnFromTap(forward: true));
      case ReaderTapZoneAction.previousChapter:
        _openAdjacentChapter(-1);
      case ReaderTapZoneAction.nextChapter:
        _openAdjacentChapter(1);
    }
  }

  void _openAdjacentChapter(int delta) {
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) return;
    if (_pageMode == BookSourcePageMode.verticalScroll && !_scrollByChapter) {
      unawaited(_jumpToVerticalChapter(target));
    } else {
      unawaited(_loadChapter(target));
    }
  }

  Future<void> _turnFromTap({required bool forward}) async {
    if (!_tapPageAnimationEnabled ||
        _pageMode == BookSourcePageMode.instantPage) {
      if (forward) {
        await _turnForward();
      } else {
        await _turnBackward();
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
    if (forward) {
      await _turnForward();
    } else {
      await _turnBackward();
    }
  }

  Widget _buildInstantReader() => LayoutBuilder(
    builder: (context, constraints) => Semantics(
      label: _pageModeHint(BookSourcePageMode.instantPage),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _handlePagedSwipe,
        child: _buildPageLeaf(
          _paginatedPages[_pageIndex],
          pageIndex: _pageIndex,
          pageCount: _pageCount,
          layoutFingerprint: _paginationKey!,
        ),
      ),
    ),
  );

  Widget _buildSlideReader() {
    final previousChapterIndex = _chapterIndex - 1;
    final previousContent = previousChapterIndex >= 0
        ? _prefetchedContent[previousChapterIndex]
        : null;
    final previousLayout = previousContent == null || _pagedViewportSize.isEmpty
        ? null
        : _pagedLayoutFor(
            previousChapterIndex,
            previousContent,
            _pagedViewportSize,
          );
    final previousPageCount = previousLayout?.pages.length ?? 1;
    final nextChapterIndex = _chapterIndex + 1;
    final hasNextChapter = nextChapterIndex < _chapters.length;
    final nextContent = hasNextChapter
        ? _prefetchedContent[nextChapterIndex]
        : null;
    final nextLayout = nextContent == null || _pagedViewportSize.isEmpty
        ? null
        : _pagedLayoutFor(nextChapterIndex, nextContent, _pagedViewportSize);
    final nextPageCount = nextLayout?.pages.length ?? 1;
    final trailing = hasNextChapter ? nextPageCount : 0;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        _schedulePendingSlideChapterCommit();
        return false;
      },
      child: PageView.builder(
        key: ValueKey('source-slide:${_chapters[_chapterIndex].id}'),
        controller: _pageController,
        physics: _annotationInteractionActive
            ? const NeverScrollableScrollPhysics()
            : null,
        itemCount: _pageViewLeading + _pageCount + trailing,
        onPageChanged: (viewIndex) {
          if (_ignoreSlidePageChanges) return;
          final page = viewIndex - _pageViewLeading;
          if (page < 0) {
            final previousPageIndex = previousPageCount + page;
            _queueSlideChapterCommit(
              chapterIndex: previousChapterIndex,
              boundaryViewIndex: viewIndex,
              restoreProgress: previousLayout == null || previousPageCount <= 1
                  ? 1
                  : previousPageIndex / (previousPageCount - 1),
            );
            return;
          }
          if (page >= _pageCount) {
            final nextPageIndex = page - _pageCount;
            _queueSlideChapterCommit(
              chapterIndex: nextChapterIndex,
              boundaryViewIndex: viewIndex,
              restoreProgress: nextPageCount <= 1
                  ? 0
                  : nextPageIndex / (nextPageCount - 1),
            );
            return;
          }
          _pendingSlideChapterIndex = null;
          _pendingSlideBoundaryViewIndex = null;
          _setPagedIndex(page);
        },
        itemBuilder: (context, viewIndex) {
          final page = viewIndex - _pageViewLeading;
          final Widget child;
          if (page < 0) {
            final previousPageIndex = previousPageCount + page;
            child =
                _buildAdjacentPreview(
                  previousChapterIndex,
                  pageIndex: previousLayout == null ? null : previousPageIndex,
                  lastPage: previousLayout == null,
                ) ??
                _buildBoundaryLeaf(forward: false);
          } else if (page >= _pageCount) {
            final nextPageIndex = page - _pageCount;
            child =
                _buildAdjacentPreview(
                  nextChapterIndex,
                  pageIndex: nextPageIndex,
                ) ??
                _buildBoundaryLeaf(forward: true);
          } else {
            child = _buildPageLeaf(
              _paginatedPages[page],
              pageIndex: page,
              pageCount: _pageCount,
              layoutFingerprint: _paginationKey!,
            );
          }
          return child;
        },
      ),
    );
  }
}
