part of 'native_reader_page.dart';

extension _NativeReaderScaffold on _NativeReaderPageState {
  Widget _buildReaderPage(BuildContext context) {
    final systemUiOverlayStyle = _readerSystemUiOverlayStyle;
    if (!_readerDependenciesInitialized) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        key: const ValueKey('reader-system-ui-region'),
        value: systemUiOverlayStyle,
        child: Theme(
          data: _readerThemeData,
          child: _buildOpeningScaffold(
            key: const ValueKey('native-reader-opening-placeholder'),
            showLoader: false,
          ),
        ),
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      key: const ValueKey('reader-system-ui-region'),
      value: systemUiOverlayStyle,
      child: PopScope(
        // A route pop used to dispose the reader before its last horizontal
        // page, which can be held until the PageView settles, was persisted.
        // Keep the route until _exitReader has committed that page.
        canPop: _exitPositionCommitted,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            BookOpenTransition.beginExit();
          } else if (_tapZoneEditorVisible) {
            _setReaderState(() => _tapZoneEditorVisible = false);
          } else {
            unawaited(_exitReader());
          }
        },
        child: Theme(
          data: _readerThemeData,
          child: FutureBuilder<List<_NativeChapter>>(
            future: _chaptersFuture,
            builder: (context, snapshot) {
              if (!_readerSettingsLoaded || !_readerFontReady) {
                return _buildOpeningScaffold(
                  key: const ValueKey('native-reader-opening-placeholder'),
                  showLoader: false,
                );
              }
              if (snapshot.hasError) {
                _scheduleOpeningContentReady();
                return _buildReaderMessageScaffold(
                  key: const ValueKey('native-reader-error'),
                  message: context.l10n.readerOpenFailed(
                    snapshot.error.toString(),
                  ),
                  showAppBar: true,
                );
              }
              final chapters = snapshot.data;
              if (chapters == null) {
                if (!_showOpeningLoader) {
                  return _buildOpeningScaffold(
                    key: const ValueKey('native-reader-loading-placeholder'),
                    showLoader: false,
                  );
                }
                return _buildOpeningScaffold(
                  key: const ValueKey('native-reader-loading'),
                  showLoader: true,
                );
              }
              if (chapters.isEmpty) {
                _scheduleOpeningContentReady();
                return _buildReaderMessageScaffold(
                  key: const ValueKey('native-reader-empty'),
                  message: context.l10n.readerNoContent,
                );
              }
              // 封面还在飞行时不构建正文：首次整章排版（50~100ms）会
              // 冻结飞行帧。等封面到达静止停留画面后再构建，排版落在
              // 无感知窗口里；已有分页缓存（重开同一本书）则立即构建。
              if (!_openingCoverHoldReachedNow && _pageCache.isEmpty) {
                return _buildOpeningScaffold(
                  key: const ValueKey('native-reader-loading-placeholder'),
                  showLoader: false,
                );
              }

              _resolveSavedChapter(chapters);
              _chapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
              final chapter = chapters[_chapterIndex];
              _scheduleOpeningContentReady();
              return Scaffold(
                key: const ValueKey('native-reader-content'),
                backgroundColor: Colors.transparent,
                // The reader page has no text field of its own, but Scaffold
                // shrinks `body` for ANY keyboard inset by default, including
                // one raised by a TextField inside a modal sheet stacked on
                // top (e.g. the TOC search box). That resize changes the
                // LayoutBuilder constraints below every animation frame,
                // forcing a full chapter re-pagination each frame.
                resizeToAvoidBottomInset: false,
                body: ReaderThemeBackground(
                  palette: _readerTheme,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      _readerViewportSize = size;
                      final usesTwoPageLayout = _usesTwoPageLayout(size);
                      final paginationSize = _paginationSize(
                        size,
                        usesTwoPageLayout,
                      );
                      final paginationGeometryChanged =
                          !_lastPaginationSize.isEmpty &&
                          (_lastPaginationSize != paginationSize ||
                              _lastUsesTwoPageLayout != usesTwoPageLayout);
                      if (paginationGeometryChanged) {
                        _restoreAnchorAfterLayout = true;
                        _lastSavedLocation = null;
                      }
                      _lastPaginationSize = paginationSize;
                      _lastUsesTwoPageLayout = usesTwoPageLayout;
                      final textDirection = Directionality.of(context);
                      const textScaler = readerBodyTextScaler;
                      final pages = _pagesFor(
                        chapter,
                        _chapterIndex,
                        paginationSize,
                        textDirection,
                        textScaler,
                      );
                      _visiblePages = pages;
                      if (_pageMode == NativePageMode.verticalScroll) {
                        _visibleContinuousParts = _continuousPartsFor(
                          chapter,
                          size,
                        );
                        _visiblePages = _visibleContinuousParts
                            .map((part) => part.content)
                            .toList(growable: false);
                      }
                      _visibleChapterCount = chapters.length;
                      _visibleUsesTwoPageLayout = usesTwoPageLayout;
                      final bookPages =
                          _pageMode == NativePageMode.horizontalSlide ||
                              _pageMode == NativePageMode.coverSlide ||
                              _pageMode == NativePageMode.pageCurl
                          ? _bookPagesFor(
                              chapters,
                              _horizontalFirstChapter,
                              _horizontalLastChapter,
                              paginationSize,
                              textDirection,
                              textScaler,
                              padOddChapters: usesTwoPageLayout,
                            )
                          : const <_BookPageRef>[];
                      if (_pageMode == NativePageMode.horizontalSlide ||
                          _pageMode == NativePageMode.coverSlide ||
                          _pageMode == NativePageMode.pageCurl) {
                        _scheduleBookPaginationWarm(
                          chapters,
                          _horizontalLastChapter + 1,
                          paginationSize,
                          textDirection,
                          textScaler,
                        );
                        _scheduleBookPaginationWarm(
                          chapters,
                          _horizontalFirstChapter - 1,
                          paginationSize,
                          textDirection,
                          textScaler,
                        );
                      }
                      if (_openPreviousChapterAtLastPage) {
                        _pageIndex = usesTwoPageLayout
                            ? _spreadStartForPage(pages.length - 1)
                            : pages.length - 1;
                        _openPreviousChapterAtLastPage = false;
                      }
                      _pageIndex = _pageIndex.clamp(0, pages.length - 1);
                      if (usesTwoPageLayout) {
                        _pageIndex = _spreadStartForPage(_pageIndex);
                      }
                      if (_restoreAnchorAfterLayout && _anchorOffset != null) {
                        final anchor = _anchorOffset!;
                        final restoredIndex =
                            _pageMode == NativePageMode.verticalScroll
                            ? _continuousPartsFor(chapter, size).indexWhere(
                                (part) =>
                                    anchor >= part.content.startOffset &&
                                    anchor < part.content.endOffset,
                              )
                            : anchor == 0 && pages.first.isChapterTitle
                            ? 0
                            : pages.indexWhere(
                                (page) =>
                                    anchor >= page.startOffset &&
                                    anchor < page.endOffset,
                              );
                        if (restoredIndex >= 0) _pageIndex = restoredIndex;
                        if (usesTwoPageLayout) {
                          _pageIndex = _spreadStartForPage(_pageIndex);
                        }
                        _restoreAnchorAfterLayout = false;
                        if (_pageMode == NativePageMode.verticalScroll &&
                            anchor > 0) {
                          _scheduleInitialContinuousScrollRestore(size);
                        } else {
                          _initialPositionRestored = true;
                        }
                      }
                      if (_pageMode != NativePageMode.verticalScroll) {
                        final locationKey =
                            '$_chapterIndex:$_pageIndex:'
                            '${pages[_pageIndex].startOffset}';
                        if (_lastSavedLocation != locationKey) {
                          _lastSavedLocation = locationKey;
                          final pageToSave = pages[_pageIndex];
                          final chapterToSave = chapter;
                          final chapterIndexToSave = _chapterIndex;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _saveCanonicalProgress(
                              chapterToSave,
                              pageToSave,
                              chapterIndexToSave,
                            );
                          });
                        }
                      }
                      if (_pageMode == NativePageMode.horizontalSlide) {
                        final targetPage = bookPages.indexWhere(
                          (page) =>
                              page.chapterIndex == _chapterIndex &&
                              page.pageIndex == _pageIndex,
                        );
                        final localTargetControllerPage = usesTwoPageLayout
                            ? targetPage ~/ 2
                            : targetPage;
                        final targetControllerPage =
                            _horizontalPageIndexMap.origin +
                            localTargetControllerPage;
                        _pageController ??= PageController(
                          initialPage: math.max(0, targetControllerPage),
                        );
                        _schedulePendingHorizontalForwardBoundaryCommit(
                          bookPages,
                          chapters,
                          usesTwoPageLayout: usesTwoPageLayout,
                        );
                        final pageControllerGeneration =
                            _pageControllerGeneration;
                        final blockControllerRealignment =
                            _pendingHorizontalForwardBoundary != null ||
                            _pendingHorizontalPage != null;
                        if (_horizontalChapterJumpPending) {
                          if (!_horizontalChapterJumpRevealScheduled) {
                            _horizontalChapterJumpRevealScheduled = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted ||
                                  pageControllerGeneration !=
                                      _pageControllerGeneration) {
                                return;
                              }
                              _setReaderState(() {
                                _horizontalChapterJumpPending = false;
                                _horizontalChapterJumpRevealScheduled = false;
                                _initialPositionRestored = true;
                              });
                            });
                          }
                        } else {
                          _initialPositionRestored = true;
                        }
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (pageControllerGeneration !=
                              _pageControllerGeneration) {
                            return;
                          }
                          if (blockControllerRealignment ||
                              _pendingHorizontalForwardBoundary != null ||
                              _pendingHorizontalPage != null) {
                            return;
                          }
                          final pageController = _pageController;
                          if (pageController == null ||
                              !pageController.hasClients) {
                            return;
                          }
                          // A live drag or fling already drives the
                          // controller toward the page that will report
                          // through onPageChanged; forcing jumpToPage while
                          // that motion is in flight fights the user's
                          // finger and reads as a flash to another page.
                          if (pageController
                              .position
                              .isScrollingNotifier
                              .value) {
                            return;
                          }
                          final current = pageController.page?.round();
                          if (targetPage >= 0 &&
                              current != targetControllerPage) {
                            pageController.jumpToPage(targetControllerPage);
                          }
                        });
                      }

                      final bookmarkPage = _bookmarkPageFor(pages);
                      final currentBookmarkAnchorKey = _bookmarkAnchorKey(
                        chapter,
                        bookmarkPage,
                      );
                      final currentPageIsBookmarked = _bookmarks.any(
                        (bookmark) =>
                            bookmark.anchorKey == currentBookmarkAnchorKey,
                      );

                      final reader = ReaderPullBookmark(
                        enabled: _pullBookmarkEnabled,
                        bookmarked: currentPageIsBookmarked,
                        busy: _bookmarkBusy,
                        palette: _readerTheme,
                        addHint: context.l10n.readerPullBookmarkAddHint,
                        removeHint: context.l10n.readerPullBookmarkRemoveHint,
                        releaseHint: context.l10n.readerPullBookmarkReleaseHint,
                        onTriggered: () =>
                            unawaited(_toggleBookmark(chapter, bookmarkPage)),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child:
                                  BookOpenTransition.buildReaderContentReveal(
                                    context,
                                    child: ReaderDesktopInput(
                                      key: const ValueKey(
                                        'native-reader-desktop-input',
                                      ),
                                      enabled: !_annotationInteractionActive,
                                      turnPageOnPointerScroll:
                                          _pageMode !=
                                          NativePageMode.verticalScroll,
                                      onNext: _handleDesktopNextPage,
                                      onPrevious: _handleDesktopPreviousPage,
                                      child: ReaderTapObserver(
                                        key: const ValueKey(
                                          'native-reader-tap-observer',
                                        ),
                                        enabled: !_annotationInteractionActive,
                                        onTap: _handleReaderTap,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          onHorizontalDragEnd:
                                              _pageMode ==
                                                      NativePageMode
                                                          .horizontalSlide ||
                                                  _pageMode ==
                                                      NativePageMode
                                                          .coverSlide ||
                                                  _pageMode ==
                                                      NativePageMode.pageCurl
                                              ? null
                                              : (details) =>
                                                    _handleHorizontalSwipe(
                                                      details,
                                                      pages,
                                                      chapters.length,
                                                      usesTwoPageLayout,
                                                    ),
                                          child: _buildReaderContent(
                                            chapters,
                                            chapter,
                                            pages,
                                            bookPages,
                                            usesTwoPageLayout,
                                            _paginationFingerprintFor(
                                              _chapterIndex,
                                              paginationSize,
                                              textDirection,
                                              textScaler,
                                            ),
                                            size,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                            ),
                            if (!_initialPositionRestored)
                              Positioned.fill(
                                child: ColoredBox(
                                  key: const ValueKey(
                                    'native-reader-positioning-placeholder',
                                  ),
                                  color: _readerTheme.background,
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            if (_showLeafFloatingStatus &&
                                _pageMode == NativePageMode.verticalScroll)
                              ReaderFloatingStatusOverlay(
                                palette: _readerTheme,
                                status: _leafStatusController.value,
                                safeArea: _readerSafeArea,
                                horizontalPadding:
                                    _floatingStatusHorizontalPadding,
                              ),
                            ReaderChromeOverlay(
                              palette: _readerTheme,
                              visible: _controlsVisible,
                              title: chapter.title.isEmpty
                                  ? widget.book.title
                                  : chapter.title,
                              statusBottom: _readerSafeArea.pageNumberBottom,
                              showViewportStatus:
                                  _pageMode == NativePageMode.verticalScroll &&
                                  _topBarStyle != ReaderTopBarStyle.hidden,
                              showViewportTitle:
                                  _pageMode == NativePageMode.verticalScroll &&
                                  _topBarStyle == ReaderTopBarStyle.reader,
                              viewportTitleTop: _readerSafeArea.readerTopBarTop,
                              viewportTitleKey: const ValueKey(
                                'native-reader-viewport-title',
                              ),
                              readerStatus: _leafStatusController.value,
                              viewportStatusHorizontalPadding: math.max(
                                24,
                                _horizontalMargin,
                              ),
                              statusBuilder: (context, style, key) =>
                                  _buildReaderStatusText(
                                    pages: pages,
                                    chapterCount: chapters.length,
                                    style: style,
                                    key: key,
                                  ),
                              onBack: () => unawaited(_exitReader()),
                              onBookmark: () => unawaited(
                                _toggleBookmark(chapter, bookmarkPage),
                              ),
                              onTableOfContents: () => unawaited(
                                _showTableOfContents(
                                  chapters,
                                  currentAnchorKey: currentBookmarkAnchorKey,
                                ),
                              ),
                              onSearch: () => unawaited(_showFullTextSearch()),
                              searchTooltip: '全文搜索',
                              onReadAloud: isReaderAloudPlatformSupported
                                  ? () => unawaited(
                                      _handleReaderAloudButtonPressed(),
                                    )
                                  : null,
                              readAloudTooltip: context.l10n.ttsReading,
                              readAloudActive: _readerAloudActive,
                              onAskAi: () => unawaited(
                                _showAskAiPanel(chapter, bookmarkPage),
                              ),
                              askAiTooltip: context.l10n.readerAskAi,
                              onSettings: _showReadingSettings,
                              backTooltip: MaterialLocalizations.of(
                                context,
                              ).backButtonTooltip,
                              bookmarkTooltip: currentPageIsBookmarked
                                  ? context.l10n.bookmarkRemoved
                                  : context.l10n.readerAddBookmark,
                              tableOfContentsTooltip:
                                  context.l10n.readerToolbarTOC,
                              settingsTooltip: context.l10n.readingSettings,
                              bookmarked: currentPageIsBookmarked,
                              bookmarkBusy: _bookmarkBusy,
                              topKey: const ValueKey(
                                'native-reader-top-controls',
                              ),
                              bottomKey: const ValueKey(
                                'native-reader-bottom-controls',
                              ),
                              statusKey: const ValueKey('native-reader-status'),
                            ),
                          ],
                        ),
                      );
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          reader,
                          if (_tapZoneEditorVisible)
                            Positioned.fill(
                              child: ReaderTapZoneEditorOverlay(
                                palette: _readerTheme,
                                zones: _tapZones,
                                onZonesChanged: _setTapZones,
                                onClose: () => _setReaderState(
                                  () => _tapZoneEditorVisible = false,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
