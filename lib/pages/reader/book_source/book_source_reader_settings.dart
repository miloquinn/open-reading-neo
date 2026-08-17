part of 'book_source_reader_page.dart';

extension _BookSourceReaderSettings on _BookSourceReaderPageState {
  String _readerThemeName(String themeId) {
    final customName = ReaderThemes.customThemeById(themeId)?.name.trim();
    if (customName != null && customName.isNotEmpty) return customName;
    return switch (themeId) {
      ReaderThemes.systemId => context.l10n.readerThemeFollowSystem,
      'mist' => context.l10n.readerThemeMist,
      'green' => context.l10n.readerThemeGreen,
      'rose' => context.l10n.readerThemeRose,
      'navy' => context.l10n.readerThemeNavy,
      'night' => context.l10n.readerThemeNight,
      'pureBlack' => context.l10n.readerThemePureBlack,
      'parchment' => context.l10n.readerThemeParchment,
      ReaderCustomTheme.themeId => context.l10n.readerThemeCustom,
      _ => context.l10n.readerThemeDay,
    };
  }

  Future<void> _updateReadingSettings({
    double? fontSize,
    int? fontWeight,
    double? lineHeight,
    double? letterSpacing,
    ReaderTextAlignment? textAlignment,
    int? firstLineIndent,
    int? paragraphSpacing,
    double? horizontalMargin,
    double? topMargin,
    double? bottomMargin,
    String? themeId,
    BookSourcePageMode? pageMode,
    bool? pullBookmarkEnabled,
    bool? tapPageAnimationEnabled,
    bool? tabletTwoPageEnabled,
  }) async {
    final repaginate =
        fontSize != null ||
        fontWeight != null ||
        lineHeight != null ||
        letterSpacing != null ||
        textAlignment != null ||
        firstLineIndent != null ||
        paragraphSpacing != null ||
        horizontalMargin != null ||
        topMargin != null ||
        bottomMargin != null ||
        (tabletTwoPageEnabled != null &&
            tabletTwoPageEnabled != _tabletTwoPageEnabled) ||
        (pageMode != null && pageMode != _pageMode);
    final currentProgress = _currentReadingProgress;
    final currentTextOffset = _currentTextOffset;
    _updateReaderState(() {
      _fontSize = fontSize ?? _fontSize;
      _fontWeight = normalizeReaderFontWeight(fontWeight ?? _fontWeight);
      _lineHeight = (lineHeight ?? _lineHeight).clamp(1.4, 2.1);
      _letterSpacing = (letterSpacing ?? _letterSpacing).clamp(
        ReaderSettings.minLetterSpacing,
        ReaderSettings.maxLetterSpacing,
      );
      _textAlignment = textAlignment ?? _textAlignment;
      _firstLineIndent = (firstLineIndent ?? _firstLineIndent).clamp(0, 4);
      _paragraphSpacing = (paragraphSpacing ?? _paragraphSpacing).clamp(0, 2);
      _horizontalMargin = (horizontalMargin ?? _horizontalMargin).clamp(
        ReaderMarginSettings.horizontalMin,
        ReaderMarginSettings.horizontalMax,
      );
      _topMargin = (topMargin ?? _topMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      );
      _bottomMargin = (bottomMargin ?? _bottomMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      );
      _readerThemeId = ReaderThemes.byId(themeId ?? _readerThemeId).id;
      _pageMode = pageMode ?? _pageMode;
      _pullBookmarkEnabled = pullBookmarkEnabled ?? _pullBookmarkEnabled;
      _tapPageAnimationEnabled =
          tapPageAnimationEnabled ?? _tapPageAnimationEnabled;
      _tabletTwoPageEnabled = tabletTwoPageEnabled ?? _tabletTwoPageEnabled;
      if (repaginate) {
        _paginationKey = null;
        _paginatedPages = const [];
        _pagedLayouts.clear();
        _warmedPagedLayoutIndexes.clear();
        _verticalLayouts.clear();
        _restorePageProgress = currentProgress;
        _restorePagedPosition = true;
        _restoreTextOffset = currentTextOffset;
      }
    });
    if (themeId != null) ReaderThemes.rememberSavedPalette(_readerTheme);
    unawaited(_syncVolumeKeyPaging());
    await _readerSettingsStore.save(_readerSettings);
    if (themeId != null && _readerSystemUiApplied) {
      await _applyReaderSystemUi();
    }
    if (repaginate) _restoreScrollProgress(currentProgress);
  }

  Future<void> _setTopBarStyle(ReaderTopBarStyle style) async {
    if (_topBarStyle == style) return;
    // 顶部预留高度随样式变化；完全沉浸在上下滚动时取消整个预留区域。
    final repaginate =
        _topChromeReserveFor(_topBarStyle) != _topChromeReserveFor(style) ||
        (_topBarStyle == ReaderTopBarStyle.hidden) !=
            (style == ReaderTopBarStyle.hidden);
    final currentProgress = _currentReadingProgress;
    final currentTextOffset = _currentTextOffset;
    _updateReaderState(() {
      _topBarStyle = style;
      if (repaginate) {
        _paginationKey = null;
        _paginatedPages = const [];
        _pagedLayouts.clear();
        _warmedPagedLayoutIndexes.clear();
        _verticalLayouts.clear();
        _restorePageProgress = currentProgress;
        _restorePagedPosition = true;
        _restoreTextOffset = currentTextOffset;
      }
    });
    await ReaderSystemUiController.savePreference(style);
    await _applyReaderSystemUi();
    if (repaginate) _restoreScrollProgress(currentProgress);
  }

  Future<void> _setScrollByChapter(bool value) async {
    if (_scrollByChapter == value) return;
    final currentProgress = _currentReadingProgress;
    _updateReaderState(() {
      _scrollByChapter = value;
      _restorePageProgress = currentProgress;
      _restorePagedPosition = true;
    });
    await _readerSettingsStore.saveScrollByChapter(value);
    _restoreScrollProgress(currentProgress);
  }

  String _pageModeSummary() {
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      return _scrollByChapter
          ? context.l10n.readerModeVerticalScrollHint
          : context.l10n.readerModeWholeBookScrollHint;
    }
    return _pageModeHint(_pageMode);
  }

  String _pageModeTitle(BookSourcePageMode mode) => switch (mode) {
    BookSourcePageMode.verticalScroll => context.l10n.pageTurningScroll,
    BookSourcePageMode.instantPage => context.l10n.readerModeHorizontalPage,
    BookSourcePageMode.horizontalSlide => context.l10n.pageTurningSlide,
    BookSourcePageMode.coverSlide => context.l10n.readerModeCoverSlide,
    BookSourcePageMode.pageCurl => context.l10n.readerModePageCurl,
  };

  String _pageModeHint(BookSourcePageMode mode) => switch (mode) {
    BookSourcePageMode.verticalScroll =>
      context.l10n.readerModeVerticalScrollHint,
    BookSourcePageMode.instantPage => context.l10n.readerModeHorizontalPageHint,
    BookSourcePageMode.horizontalSlide =>
      context.l10n.readerModeHorizontalSlideHint,
    BookSourcePageMode.coverSlide => context.l10n.readerModeCoverSlideHint,
    BookSourcePageMode.pageCurl => context.l10n.readerModePageCurlHint,
  };

  String _topBarStyleTitle(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystem,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReader,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloating,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHidden,
  };

  String _topBarStyleHint(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystemHint,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReaderHint,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloatingHint,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHiddenHint,
  };

  ReaderAloudController? _ensureReaderAloudController() {
    final existing = _readerAloudController;
    if (existing != null) return existing;
    ReaderAloudService aloudService;
    try {
      aloudService = context.read<ReaderAloudService>();
    } on ProviderNotFoundException {
      return null;
    }
    final session = context.read<ReaderAloudSession>();
    final controller = session.acquire(
      sourceId: 'source:${widget.source.id}:${widget.book.id}',
      create: () => ReaderAloudController(
        engine: aloudService,
        notificationSink: PlatformReaderAloudMediaSession.instance,
        source: CallbackReaderAloudSource(
          bookTitle: widget.book.title,
          chapterCount: () => _chapters.length,
          currentPosition: () async {
            if (_chapters.isEmpty) {
              return const ReaderAloudPosition(chapterIndex: 0, offset: 0);
            }
            final chapterIndex = _chapterIndex.clamp(0, _chapters.length - 1);
            final content = await _continuousContentFor(chapterIndex);
            final text =
                _readableChapterText[chapterIndex] ??
                await readableBookSourceChapterTextAsync(
                  content,
                  fallbackTitle: _chapters[chapterIndex].title,
                );
            final offset =
                _currentTextOffset ??
                (text.length * _currentReadingProgress).round();
            return ReaderAloudPosition(
              chapterIndex: chapterIndex,
              offset: offset.clamp(0, text.length),
            );
          },
          loadChapter: (index) async {
            if (index < 0 || index >= _chapters.length) return null;
            final content = await _continuousContentFor(index);
            final text =
                _readableChapterText[index] ??
                await readableBookSourceChapterTextAsync(
                  content,
                  fallbackTitle: _chapters[index].title,
                );
            return ReaderAloudChapter(
              index: index,
              id: _chapters[index].id,
              title: _chapters[index].title,
              text: text,
            );
          },
          revealPosition: _revealReaderAloudPosition,
          persistPosition: _persistReaderAloudPosition,
        ),
      ),
    )..addListener(_onReaderAloudChanged);
    _readerAloudController = controller;
    return controller;
  }
}
