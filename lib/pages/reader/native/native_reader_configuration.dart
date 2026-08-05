part of 'native_reader_page.dart';

extension _NativeReaderConfiguration on _NativeReaderPageState {
  Future<void> _loadPageMode() async {
    try {
      final results = await Future.wait<Object?>([
        _readerSettingsStore.load(),
        _readerSettingsStore.loadScrollByChapter(),
        _customThemeStore.loadAll(),
        _themeOrderStore.load(),
        ReaderSystemUiController.loadPreference(),
        _readerSettingsStore.loadTapZones(),
        _readerSettingsStore.loadTxtChapterTitlePageEnabled(),
      ]);
      final settings = results[0] as ReaderSettings;
      final scrollByChapter = results[1] as bool;
      final customThemes = results[2] as List<ReaderCustomTheme>;
      final themeOrder = results[3] as List<String>;
      final topBarStyle = results[4] as ReaderTopBarStyle;
      final tapZones = results[5] as ReaderTapZones;
      final txtChapterTitlePageEnabled = results[6] as bool;
      if (!mounted) return;
      ReaderThemes.setCustomThemes(customThemes);
      ReaderThemes.setThemeOrder(themeOrder);
      _setReaderState(() {
        _pageMode = settings.pageMode;
        _fontSize = settings.fontSize;
        _fontWeight = settings.fontWeight;
        _lineHeight = settings.lineHeight;
        _letterSpacing = settings.letterSpacing;
        _textAlignment = settings.textAlignment;
        _horizontalMargin = settings.horizontalMargin;
        _topMargin = settings.topMargin;
        _bottomMargin = settings.bottomMargin;
        _firstLineIndent = settings.firstLineIndent;
        _paragraphSpacing = settings.paragraphSpacing;
        _scrollByChapter = scrollByChapter;
        _readerThemeId = ReaderThemes.byId(settings.themeId).id;
        _pullBookmarkEnabled = settings.pullBookmarkEnabled;
        _tapPageAnimationEnabled = settings.tapPageAnimationEnabled;
        _tapZones = tapZones;
        _tabletTwoPageEnabled = settings.tabletTwoPageEnabled;
        _topBarStyle = topBarStyle;
        _txtChapterTitlePageEnabled = txtChapterTitlePageEnabled;
        _readerSettingsLoaded = true;
      });
      unawaited(_syncVolumeKeyPaging());
    } catch (error, stackTrace) {
      debugPrint('Reader settings failed to load: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _setReaderState(() => _readerSettingsLoaded = true);
        unawaited(_syncVolumeKeyPaging());
      }
    }
  }

  Future<void> _syncVolumeKeyPaging() => ReaderVolumeKeyController.activate(
    owner: this,
    pageTurningAvailable: _pageMode != NativePageMode.verticalScroll,
    onNextPage: () => _handleVolumePageTurn(forward: true),
    onPreviousPage: () => _handleVolumePageTurn(forward: false),
  );

  void _handleVolumePageTurn({required bool forward}) {
    if (!mounted ||
        _pageMode == NativePageMode.verticalScroll ||
        _visiblePages.isEmpty ||
        _visibleChapterCount <= 0) {
      return;
    }
    if (forward) {
      _nextPage(
        _visiblePages,
        _visibleChapterCount,
        usesTwoPageLayout: _visibleUsesTwoPageLayout,
      );
    } else {
      _previousPage(
        _visiblePages,
        _visibleChapterCount,
        usesTwoPageLayout: _visibleUsesTwoPageLayout,
      );
    }
  }

  ReaderThemePalette get _readerTheme =>
      !_readerSettingsLoaded && widget.initialTheme != null
      ? widget.initialTheme!
      : ReaderThemes.byId(_readerThemeId);

  ThemeData get _readerThemeData =>
      _readerTheme.toThemeData(typography: Theme.of(context).textTheme);

  ReaderSettings get _readerSettings => ReaderSettings(
    fontSize: _fontSize,
    fontWeight: _fontWeight,
    lineHeight: _lineHeight,
    letterSpacing: _letterSpacing,
    textAlignment: _textAlignment,
    horizontalMargin: _horizontalMargin,
    topMargin: _topMargin,
    bottomMargin: _bottomMargin,
    themeId: _readerThemeId,
    pageMode: _pageMode,
    firstLineIndent: _firstLineIndent,
    paragraphSpacing: _paragraphSpacing,
    pullBookmarkEnabled: _pullBookmarkEnabled,
    tapPageAnimationEnabled: _tapPageAnimationEnabled,
    tabletTwoPageEnabled: _tabletTwoPageEnabled,
  );

  TextStyle get _readerTextStyle => TextStyle(
    inherit: false,
    fontFamily: _readerFont.family,
    fontFamilyFallback: readerFontFamilyFallbacks(
      fontFamily: _readerFont.family,
      configuredFallbacks: _readerFont.fallbackFamilies,
      locale: Localizations.maybeLocaleOf(context),
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
    color: _readerTheme.text,
  );

  TextAlign get _readerTextAlign => switch (_textAlignment) {
    ReaderTextAlignment.natural => TextAlign.start,
    ReaderTextAlignment.justified => TextAlign.justify,
  };

  NativeTextFlowStyle _readerTextFlowStyle({
    TextDirection? direction,
    TextScaler? textScaler,
  }) {
    final style = _readerTextStyle;
    return NativeTextFlowStyle(
      textDirection: direction ?? Directionality.of(context),
      textScaler: textScaler ?? readerBodyTextScaler,
      locale: Localizations.maybeLocaleOf(context),
      strutStyle: readerStrutStyle(style),
      textHeightBehavior: readerTextHeightBehavior,
      textAlign: _readerTextAlign,
    );
  }

  Future<void> _setReaderTheme(String themeId) async {
    final nextTheme = ReaderThemes.byId(themeId);
    if (_readerThemeId == nextTheme.id) return;
    _setReaderState(() => _readerThemeId = nextTheme.id);
    ReaderThemes.rememberSavedPalette(nextTheme);
    if (_readerSystemUiApplied) await _applyReaderSystemUi();
    await _readerSettingsStore.save(_readerSettings);
  }

  Widget _buildStyledReaderText(
    _NativeChapter chapter,
    _ReaderPageData page, {
    required int chapterIndex,
    required int pageIndex,
    bool fillAvailableSpace = true,
  }) {
    final flowStyle = _readerTextFlowStyle();
    return ReaderAnnotatedTextPage(
      key: ValueKey(
        'native-annotated-page:${chapter.id}:$pageIndex:'
        '${page.startOffset}:${page.endOffset}',
      ),
      page: page,
      sourceText: chapter.plainText,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      bookId: widget.book.id,
      format: BookFormat.fromFileExtension(widget.book.format),
      renderer: ReaderRendererType.flutterNative,
      palette: _readerTheme,
      bodyStyle: _readerTextStyle,
      flowStyle: flowStyle,
      annotations: _annotations,
      spokenHighlight: _readerAloudHighlight,
      baseSourceSpanBuilder: (start, end) =>
          _styledSpanForRange(chapter, start, end, _readerTextStyle),
      onSaveTextAnnotation: _saveTextAnnotation,
      onAskAiSelection: _askAiAboutSelection,
      fillAvailableSpace: fillAvailableSpace,
      onInteractionChanged: (active) {
        if (!mounted || _annotationInteractionActive == active) return;
        _setReaderState(() => _annotationInteractionActive = active);
      },
    );
  }

  ReaderSafeAreaMetrics get _readerSafeArea => ReaderSafeAreaMetrics(
    viewPadding: MediaQuery.viewPaddingOf(context),
    topMargin: _topMargin,
    bottomMargin: _bottomMargin,
    topChromeReserve: _topChromeReserveFor(_topBarStyle),
  );

  /// 阅读信息栏占一条固定信息条；灵动信息栏借用状态栏区域，仅在设备
  /// 没有状态栏 inset（隐藏后归零）时补足最小高度，避免正文顶进时间与
  /// 电量。其余样式顶部只避开状态栏本身。
  double _topChromeReserveFor(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.reader => ReaderSafeAreaMetrics.readerTopBarReserve,
    ReaderTopBarStyle.floating => math.max(
      0,
      ReaderSafeAreaMetrics.floatingStatusMinHeight -
          MediaQuery.viewPaddingOf(context).top,
    ),
    _ => 0,
  };

  bool get _showLeafFloatingStatus =>
      _topBarStyle == ReaderTopBarStyle.floating;

  double get _floatingStatusHorizontalPadding =>
      math.max(32, _horizontalMargin);

  /// 阅读信息栏与灵动信息栏都画进纸页快照，需要随分钟时钟/电量刷新重绘。
  int get _leafContentRevision => Object.hash(
    _topBarStyle == ReaderTopBarStyle.reader || _showLeafFloatingStatus
        ? _leafStatusController.value.revision
        : 0,
    _annotationRevision,
  );

  double get _effectiveTopMargin => _readerSafeArea.contentTop;

  double get _effectiveBottomMargin => _readerSafeArea.contentBottom;

  bool _usesTwoPageLayout(Size size) =>
      _tabletTwoPageEnabled &&
      _pageMode != NativePageMode.verticalScroll &&
      ReaderLayoutBreakpoints.supportsTwoPageLayout(size);

  Size _paginationSize(Size viewport, bool usesTwoPageLayout) {
    if (!usesTwoPageLayout) return viewport;
    return Size((viewport.width - _spreadGutter) / 2, viewport.height);
  }

  int _spreadStartForPage(int pageIndex) => (pageIndex ~/ 2) * 2;

  Future<void> _updateLayout({
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
  }) async {
    _setReaderState(() {
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
      _pageIndex = 0;
      _restoreAnchorAfterLayout = true;
    });
    await _readerSettingsStore.save(_readerSettings);
  }

  Future<void> _setTxtChapterTitlePageEnabled(bool value) async {
    if (_txtChapterTitlePageEnabled == value) return;
    _setReaderState(() {
      _txtChapterTitlePageEnabled = value;
      _pageIndex = 0;
      _restoreAnchorAfterLayout = true;
    });
    await _readerSettingsStore.saveTxtChapterTitlePageEnabled(value);
  }

  String get _layoutSignature =>
      '${_fontSize.toStringAsFixed(1)}:'
      '$_fontWeight:'
      '${_lineHeight.toStringAsFixed(2)}:'
      '${_letterSpacing.toStringAsFixed(1)}:${_textAlignment.name}:'
      '${_horizontalMargin.toStringAsFixed(1)}:'
      '${_topMargin.toStringAsFixed(1)}:'
      '${_bottomMargin.toStringAsFixed(1)}:${_pageMode.name}:'
      '$_firstLineIndent:$_paragraphSpacing:${_readerFont.id}:'
      '${widget.book.format.toLowerCase() == 'txt' ? _txtChapterTitlePageEnabled : true}';

  Future<void> _setTopBarStyle(ReaderTopBarStyle style) async {
    if (_topBarStyle == style) return;
    // 顶部预留高度随样式变化；完全沉浸在上下滚动时取消整个预留区域。
    final repaginate =
        _topChromeReserveFor(_topBarStyle) != _topChromeReserveFor(style) ||
        (_topBarStyle == ReaderTopBarStyle.hidden) !=
            (style == ReaderTopBarStyle.hidden);
    _setReaderState(() {
      _topBarStyle = style;
      if (repaginate) {
        _pageIndex = 0;
        _restoreAnchorAfterLayout = true;
      }
    });
    await ReaderSystemUiController.savePreference(style);
    await _applyReaderSystemUi();
  }
}
