part of 'book_source_reader_page.dart';

extension _BookSourceReaderShell on _BookSourceReaderPageState {
  void _scheduleOpeningContentReady() {
    if (_openingContentReadyScheduled) return;
    _openingContentReadyScheduled = true;
    _openingLoaderTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) BookOpenTransition.markReaderContentReady(context);
    });
  }

  String get _bodyStateName {
    if (!_readerFontReady ||
        _loadingCatalog ||
        (_loadingContent && _content == null)) {
      return _showOpeningLoader ? 'loading' : 'loading-placeholder';
    }
    if (_error != null) return 'error';
    if (_chapters.isEmpty || _content == null) return 'empty';
    return 'content';
  }

  Widget _buildTransitionAwareBody() {
    final bodyState = _bodyStateName;
    final body = _buildBody();
    if (bodyState != 'content') return body;
    return BookOpenTransition.buildReaderContentReveal(context, child: body);
  }

  /// 打开动画封面仍在飞行时，把整章排版（`_applyLoadedChapter` 内同步执行，
  /// 数十毫秒）延后到封面到达静止停留画面之后；已有分页缓存或不在打开
  /// 转场中时立即返回 false，不引入任何延迟。
  Future<bool> _deferChapterApplyForOpeningFlight(int index) async {
    if (!mounted || _pagedLayouts[index] != null) return false;
    final listenable = BookOpenTransition.openingCoverHoldListenableOf(context);
    if (listenable == null || listenable.value) return false;
    final completer = Completer<void>();
    late final VoidCallback onChanged;
    onChanged = () {
      if (!listenable.value) return;
      listenable.removeListener(onChanged);
      if (!completer.isCompleted) completer.complete();
    };
    listenable.addListener(onChanged);
    await completer.future;
    return true;
  }

  Widget _buildBody() {
    if (!_readerFontReady ||
        _loadingCatalog ||
        (_loadingContent && _content == null)) {
      if (!_showOpeningLoader) {
        return GestureDetector(
          key: const ValueKey('book-source-reader-loading-placeholder'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          child: const SizedBox.expand(),
        );
      }
      return GestureDetector(
        key: const ValueKey('book-source-reader-loading-surface'),
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: ReaderOpeningLoader(palette: _readerTheme),
      );
    }
    _scheduleOpeningContentReady();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: _readerTheme.secondaryText,
              ),
              const SizedBox(height: 12),
              Text(
                _error.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _chapters.isEmpty
                    ? _initialize
                    : () => _loadChapter(_chapterIndex, saveCurrent: false),
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_chapters.isEmpty || _content == null) {
      return Center(child: Text(context.l10n.readerNoContent));
    }

    final content = _content!;
    if (isImageOnlyBookSourceChapter(content)) {
      return _buildImageOnlyChapterReader(content);
    }
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          _verticalViewportSize = viewport;
          if (!_scrollByChapter) {
            return _buildVerticalReadingWindow(_buildVerticalBook(viewport));
          }
          final layout = _verticalLayoutFor(_chapterIndex, content, viewport);
          return _buildVerticalReadingWindow(
            _buildVerticalPageList(layout, viewport),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final usesTwoPageLayout = _shouldUseTwoPageLayout(constraints.biggest);
        _usesTwoPageLayout = usesTwoPageLayout;
        final paginationViewport = _paginationViewport(
          constraints.biggest,
          usesTwoPageLayout,
        );
        if (_pagedViewportSize != paginationViewport) {
          _pagedViewportSize = paginationViewport;
          _warmedPagedLayoutIndexes.clear();
        }
        _ensurePagination(paginationViewport, content: content);
        _schedulePagedLayoutWarm(_chapterIndex + 1);
        return switch (_pageMode) {
          BookSourcePageMode.instantPage => _buildInstantReader(),
          BookSourcePageMode.horizontalSlide => _buildSlideReader(),
          BookSourcePageMode.coverSlide => _buildCoverReader(),
          BookSourcePageMode.pageCurl => _buildCurlReader(
            usesTwoPageLayout: usesTwoPageLayout,
          ),
          BookSourcePageMode.verticalScroll => const SizedBox.shrink(),
        };
      },
    );
  }

  Widget _buildImageOnlyChapterReader(BookSourceChapterContent content) {
    final images = content.images;
    if (images.isEmpty) return const SizedBox.shrink();
    // Mixed text/image books keep catalog ownership here. Dedicated comics
    // go through ComicReaderPage; both use the same page renderer.
    return PagedImageReader(
      title: _chapters[_chapterIndex].title,
      pageCount: images.length,
      initialPage: _pageIndex.clamp(0, images.length - 1),
      settingsId: 'comic:${widget.source.id}:${widget.book.id}',
      palette: _readerTheme,
      loadPage: (index, {preload = false}) => _remoteImageCache.load(
        images[index].url,
        headers: images[index].headers,
        priority: preload
            ? SourceImageLoadPriority.preload
            : SourceImageLoadPriority.visible,
      ),
      onPageChanged: (index) {
        if (!mounted) return;
        _pageIndex = index;
        _pageCount = images.length;
        _scrollProgress.value = _pagedReadingProgress(index, images.length);
        _scheduleProgressSave();
      },
    );
  }

  ReaderFontProfile get _readerFontProfile => resolveReaderFontProfile(
    selection: _readerFont,
    locale: Localizations.maybeLocaleOf(context),
  );

  TextStyle get _bodyTextStyle => TextStyle(
    inherit: false,
    fontFamily: _readerFontProfile.fontFamily,
    fontFamilyFallback: _readerFontProfile.fontFamilyFallback.isEmpty
        ? null
        : _readerFontProfile.fontFamilyFallback,
    color: readerTextColorForBrightness(
      effectiveReaderTextBrightness(
        brightness: _textBrightness,
        dimInDarkMode: _dimTextInDarkMode,
        isDarkMode: _readerTheme.brightness == Brightness.dark,
      ),
      isDarkMode: _readerTheme.brightness == Brightness.dark,
    ),
    fontSize: _fontSize,
    fontWeight: readerFontWeightFromValue(_fontWeight),
    fontVariations: readerFontVariationsFromValue(
      _fontWeight,
      supportsVariableWeight: _readerFont.supportsVariableWeight,
      variableWeightMin: _readerFont.variableWeightMin,
      variableWeightMax: _readerFont.variableWeightMax,
    ),
    height: _lineHeight,
    letterSpacing: _letterSpacing,
  );

  TextAlign get _bodyTextAlign => switch (_textAlignment) {
    ReaderTextAlignment.natural => TextAlign.start,
    ReaderTextAlignment.justified => TextAlign.justify,
  };

  NativeTextFlowStyle _bodyTextFlowStyle({
    TextDirection? direction,
    TextScaler? textScaler,
    Locale? locale,
  }) => NativeTextFlowStyle(
    textDirection: direction ?? Directionality.of(context),
    textScaler: textScaler ?? readerBodyTextScaler,
    locale: locale ?? Localizations.maybeLocaleOf(context),
    strutStyle: readerStrutStyle(_bodyTextStyle),
    textHeightBehavior: readerTextHeightBehavior,
    textAlign: _bodyTextAlign,
  );

  String _readerStatus() {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return context.l10n.readerStatusPaged(
        _chapterIndex + 1,
        _chapters.length,
        _verticalPageIndex + 1,
        _verticalPageCount,
      );
    }
    return context.l10n.readerStatusPaged(
      _chapterIndex + 1,
      _chapters.length,
      _pageIndex + 1,
      _pageCount,
    );
  }

  bool get _currentPageIsBookmarked {
    final anchorKey = _currentBookmarkAnchorKey;
    return anchorKey != null &&
        _bookmarks.any((bookmark) => bookmark.anchorKey == anchorKey);
  }

  Widget _buildReaderStatusText(
    BuildContext context,
    TextStyle? style,
    Key? key,
  ) {
    return ValueListenableBuilder<double>(
      valueListenable: _scrollProgress,
      builder: (context, _, _) => Text(
        _chapters.isEmpty ? widget.book.title : _readerStatus(),
        key: key,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }

  Widget _buildReaderShell() {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      key: const ValueKey('reader-system-ui-region'),
      value: _readerSystemUiOverlayStyle,
      child: PopScope(
        canPop: _canPopWithoutPrompt && !_tapZoneEditorVisible,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            BookOpenTransition.beginExit();
          } else if (_tapZoneEditorVisible) {
            _updateReaderState(() => _tapZoneEditorVisible = false);
          } else {
            unawaited(_requestExit());
          }
        },
        child: Theme(
          data: _readerThemeData,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // The reader page has no text field of its own, but Scaffold
            // shrinks `body` for ANY keyboard inset by default, including
            // one raised by a TextField inside a modal sheet stacked on top
            // (e.g. the TOC search box). That resize changes the layout
            // constraints the pagination below reacts to on every animation
            // frame, forcing a full chapter re-pagination each frame.
            resizeToAvoidBottomInset: false,
            body: ReaderThemeBackground(
              palette: _readerTheme,
              child: ReaderPullBookmark(
                enabled:
                    _pullBookmarkEnabled &&
                    _chapters.isNotEmpty &&
                    !_tapZoneEditorVisible,
                bookmarked: _currentPageIsBookmarked,
                busy: _bookmarkBusy,
                palette: _readerTheme,
                addHint: context.l10n.readerPullBookmarkAddHint,
                removeHint: context.l10n.readerPullBookmarkRemoveHint,
                releaseHint: context.l10n.readerPullBookmarkReleaseHint,
                onTriggered: () => unawaited(_toggleCurrentBookmark()),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ReaderDesktopInput(
                        key: const ValueKey('book-source-reader-desktop-input'),
                        enabled:
                            _readerFontReady &&
                            !_loadingCatalog &&
                            (!_loadingContent || _content != null) &&
                            _error == null &&
                            _chapters.isNotEmpty &&
                            _content != null &&
                            !_annotationInteractionActive,
                        turnPageOnPointerScroll:
                            _pageMode != BookSourcePageMode.verticalScroll,
                        onNext: _handleDesktopNextPage,
                        onPrevious: _handleDesktopPreviousPage,
                        child: ReaderTapObserver(
                          key: const ValueKey(
                            'book-source-reader-tap-observer',
                          ),
                          enabled:
                              _readerFontReady &&
                              !_loadingCatalog &&
                              (!_loadingContent || _content != null) &&
                              _error == null &&
                              _chapters.isNotEmpty &&
                              _content != null &&
                              !_annotationInteractionActive,
                          onTap: _handleReaderTap,
                          child: Semantics(
                            label: widget.book.title,
                            child: KeyedSubtree(
                              key: ValueKey(
                                'book-source-reader-$_bodyStateName',
                              ),
                              child: _buildTransitionAwareBody(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_showLeafFloatingStatus &&
                        _pageMode == BookSourcePageMode.verticalScroll)
                      ReaderFloatingStatusOverlay(
                        palette: _readerTheme,
                        status: _leafStatusController.value,
                        safeArea: _readerSafeArea,
                        horizontalPadding: _floatingStatusHorizontalPadding,
                      ),
                    ReaderChromeOverlay(
                      palette: _readerTheme,
                      visible: _controlsVisible,
                      title: _chapters.isEmpty
                          ? widget.book.title
                          : _chapters[_chapterIndex.clamp(
                                  0,
                                  _chapters.length - 1,
                                )]
                                .title,
                      statusBottom: _readerSafeArea.pageNumberBottom,
                      showViewportStatus:
                          _pageMode == BookSourcePageMode.verticalScroll &&
                          _topBarStyle != ReaderTopBarStyle.hidden,
                      showViewportTitle:
                          _pageMode == BookSourcePageMode.verticalScroll &&
                          _topBarStyle == ReaderTopBarStyle.reader,
                      viewportTitleTop: _readerSafeArea.readerTopBarTop,
                      viewportTitleKey: const ValueKey(
                        'book-source-viewport-title',
                      ),
                      readerStatus: _leafStatusController.value,
                      viewportStatusHorizontalPadding: math.max(
                        24,
                        _horizontalMargin,
                      ),
                      statusBuilder: _buildReaderStatusText,
                      onBack: () => unawaited(_requestExit()),
                      onBookmark: _chapters.isEmpty
                          ? null
                          : () => unawaited(_toggleCurrentBookmark()),
                      onTableOfContents: _chapters.isEmpty
                          ? null
                          : _showCatalog,
                      onSearch: _chapters.isEmpty
                          ? null
                          : () => unawaited(_showFullTextSearch()),
                      searchTooltip: '全文搜索',
                      onReadAloud:
                          _chapters.isEmpty || !isReaderAloudPlatformSupported
                          ? null
                          : () => unawaited(_handleReaderAloudButtonPressed()),
                      readAloudTooltip: context.l10n.ttsReading,
                      readAloudActive: _readerAloudActive,
                      onAskAi: _chapters.isEmpty
                          ? null
                          : () => unawaited(_showAskAiPanel()),
                      askAiTooltip: context.l10n.readerAskAi,
                      onChangeSource: () => unawaited(_changeBookSource()),
                      changeSourceTooltip:
                          context.l10n.bookSourceChangeSourceTitle,
                      onSettings: _showReadingSettings,
                      backTooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      bookmarkTooltip: _currentPageIsBookmarked
                          ? context.l10n.bookmarkRemoved
                          : context.l10n.readerAddBookmark,
                      tableOfContentsTooltip: context.l10n.readerToolbarTOC,
                      settingsTooltip: context.l10n.readingSettings,
                      bookmarked: _currentPageIsBookmarked,
                      bookmarkBusy: _bookmarkBusy,
                      topKey: const ValueKey('book-source-top-controls'),
                      bottomKey: const ValueKey('book-source-bottom-controls'),
                      statusKey: const ValueKey('book-source-reader-status'),
                    ),
                    if (_tapZoneEditorVisible)
                      Positioned.fill(
                        child: ReaderTapZoneEditorOverlay(
                          palette: _readerTheme,
                          zones: _tapZones,
                          onZonesChanged: _setTapZones,
                          onClose: () => _updateReaderState(
                            () => _tapZoneEditorVisible = false,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
