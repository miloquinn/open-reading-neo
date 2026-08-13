part of 'native_reader_page.dart';

extension _NativeReaderControls on _NativeReaderPageState {
  String _readerThemeName(BuildContext context, String themeId) {
    final customName = ReaderThemes.customThemeById(themeId)?.name.trim();
    if (customName != null && customName.isNotEmpty) return customName;
    switch (themeId) {
      case ReaderThemes.systemId:
        return context.l10n.readerThemeFollowSystem;
      case 'mist':
        return context.l10n.readerThemeMist;
      case 'green':
        return context.l10n.readerThemeGreen;
      case 'rose':
        return context.l10n.readerThemeRose;
      case 'navy':
        return context.l10n.readerThemeNavy;
      case 'night':
        return context.l10n.readerThemeNight;
      case 'pureBlack':
        return context.l10n.readerThemePureBlack;
      case 'parchment':
        return context.l10n.readerThemeParchment;
      case ReaderCustomTheme.themeId:
        return context.l10n.readerThemeCustom;
      default:
        return context.l10n.readerThemeDay;
    }
  }

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
      sourceId: 'local:${widget.book.id}',
      create: () => ReaderAloudController(
        engine: aloudService,
        notificationSink: PlatformReaderAloudMediaSession.instance,
        source: CallbackReaderAloudSource(
          bookTitle: widget.book.title,
          chapterCount: () => _loadedChapters.length,
          currentPosition: () async {
            final chapterIndex = _chapterIndex
                .clamp(0, math.max(0, _loadedChapters.length - 1))
                .toInt();
            var offset = _anchorOffset ?? 0;
            if (_pageMode == NativePageMode.verticalScroll &&
                _visibleContinuousParts.isNotEmpty) {
              offset =
                  _visibleContinuousParts[_pageIndex.clamp(
                        0,
                        _visibleContinuousParts.length - 1,
                      )]
                      .content
                      .startOffset;
            } else if (_visiblePages.isNotEmpty) {
              offset =
                  _visiblePages[_pageIndex.clamp(0, _visiblePages.length - 1)]
                      .startOffset;
            }
            return ReaderAloudPosition(
              chapterIndex: chapterIndex,
              offset: offset,
            );
          },
          loadChapter: (index) async {
            if (index < 0 || index >= _loadedChapters.length) return null;
            final chapter = _loadedChapters[index];
            await chapter.loadTextAsync();
            return ReaderAloudChapter(
              index: index,
              id: chapter.id,
              title: chapter.title,
              text: chapter.plainText,
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

  void _onReaderAloudChanged() {
    final active = _readerAloudController?.isActive ?? false;
    final highlight = _readerAloudController?.highlight;
    if (!mounted) return;
    final error = _readerAloudController?.lastError;
    if (error != null) {
      showSideToast(context, '朗读启动失败：$error', kind: SideToastKind.error);
    }
    if (active == _readerAloudActive && highlight == _readerAloudHighlight) {
      return;
    }
    _setReaderState(() {
      _readerAloudActive = active;
      _readerAloudHighlight = highlight;
    });
  }

  Future<void> _revealReaderAloudPosition(ReaderAloudPosition position) async {
    if (!mounted || _loadedChapters.isEmpty) return;
    final revealGeneration = ++_readerAloudPositionRevealGeneration;
    _readerAloudPositionRevealInProgress = true;
    try {
      final chapterIndex = position.chapterIndex.clamp(
        0,
        _loadedChapters.length - 1,
      );
      final chapter = _loadedChapters[chapterIndex];
      await chapter.loadTextAsync();
      final offset = position.offset.clamp(0, chapter.plainText.length);
      final excerptEnd = (offset + 72).clamp(offset, chapter.plainText.length);
      final locator = CanonicalLocator.fromComponents(
        format: BookFormat.fromFileExtension(widget.book.format),
        chapterId: chapter.id,
        offset: offset,
        excerpt: chapter.plainText.substring(offset, excerptEnd),
        progression: chapter.plainText.isEmpty
            ? 0
            : offset / chapter.plainText.length,
      );
      final revealsWithinCurrentChapter = chapterIndex == _chapterIndex;
      await _jumpToBookmark(
        Bookmark(
          bookId: widget.book.id ?? 0,
          pageNumber: chapterIndex,
          chapterIndex: chapterIndex,
          chapterTitle: chapter.title,
          canonicalLocator: LocatorCodec.encodeCanonicalLocator(locator),
        ),
        _loadedChapters,
      );
      if (revealsWithinCurrentChapter &&
          mounted &&
          _pageMode != NativePageMode.verticalScroll) {
        _setReaderState(() {});
      }
    } finally {
      if (revealGeneration == _readerAloudPositionRevealGeneration) {
        _readerAloudPositionRevealInProgress = false;
      }
    }
  }

  Future<void> _persistReaderAloudPosition(ReaderAloudPosition position) async {
    final bookId = widget.book.id;
    if (bookId == null || _loadedChapters.isEmpty) return;
    final chapterIndex = position.chapterIndex.clamp(
      0,
      _loadedChapters.length - 1,
    );
    final chapter = _loadedChapters[chapterIndex];
    await chapter.loadTextAsync();
    final offset = position.offset.clamp(0, chapter.plainText.length);
    final excerptEnd = (offset + 72).clamp(offset, chapter.plainText.length);
    final locator = CanonicalLocator.fromComponents(
      format: BookFormat.fromFileExtension(widget.book.format),
      chapterId: chapter.id,
      offset: offset,
      excerpt: chapter.plainText.substring(offset, excerptEnd),
      progression: chapter.plainText.isEmpty
          ? 0
          : offset / chapter.plainText.length,
    );
    _anchorOffset = offset;
    final canonicalLocator = LocatorCodec.encodeCanonicalLocator(locator);
    unawaited(
      ReadingResumeService.recordPosition(
        bookId: bookId,
        canonicalLocator: canonicalLocator,
        chapterIndex: chapterIndex,
      ),
    );
    await _queuePositionWrite(
      () => BookDao().updateBookCanonicalLocator(
        bookId,
        canonicalLocator,
        null,
        _layoutSignature,
        chapterIndex,
        readingProgress:
            (chapterIndex +
                (chapter.plainText.isEmpty
                    ? 1.0
                    : offset / chapter.plainText.length)) /
            _loadedChapters.length,
      ),
    );
  }

  Future<void> _showReaderAloudPanel() async {
    final controller = _ensureReaderAloudController();
    if (controller == null) return;
    final ttsService = context.read<TtsService>();
    final aloudService = context.read<ReaderAloudService>();
    await showReaderAloudPanelSheet(
      context: context,
      controller: controller,
      ttsService: ttsService,
      aloudService: aloudService,
      palette: _readerTheme,
      themeData: _readerThemeData,
    );
  }

  /// The toolbar button is intentionally a playback control. Detailed voice,
  /// speed and sleep settings remain available from the reader controls sheet.
  Future<void> _toggleReaderAloudPlayback() async {
    final controller = _ensureReaderAloudController();
    if (controller == null) return;
    if (controller.isActive) {
      await _showReaderAloudPanel();
      return;
    }
    switch (controller.state) {
      case ReaderAloudPlaybackState.playing:
      case ReaderAloudPlaybackState.loading:
        await controller.pause();
      case ReaderAloudPlaybackState.paused:
        await controller.resume();
      case ReaderAloudPlaybackState.stopped:
      case ReaderAloudPlaybackState.error:
        showSideToast(context, '正在开始朗读…');
        await controller.start();
    }
  }

  Future<void> _restartReaderAloudAtVisiblePage() async {
    final controller = _readerAloudController;
    if (_readerAloudPositionRevealInProgress ||
        controller == null ||
        !controller.isActive) {
      return;
    }
    await controller.start();
  }

  Future<void> _showAskAiPanel(
    _NativeChapter chapter,
    _ReaderPageData page,
  ) async {
    final pageText = page.text.trim().isEmpty ? chapter.plainText : page.text;
    await showReaderAiPanelSheet(
      context: context,
      palette: _readerTheme,
      themeData: _readerThemeData,
      meta: AIRequestMeta(
        bookId: widget.book.id?.toString() ?? '',
        chapterId: chapter.id,
        pageIndex: _pageIndex,
      ),
      pageText: pageText,
      bookTitle: widget.book.title,
    );
  }

  Future<void> _askAiAboutSelection(ReaderSelectionSnapshot selection) async {
    await showReaderAiPanelSheet(
      context: context,
      palette: _readerTheme,
      themeData: _readerThemeData,
      meta: AIRequestMeta(
        bookId: widget.book.id?.toString() ?? '',
        chapterId: selection.chapterId,
        pageIndex: selection.pageIndex,
      ),
      pageText: readerAiPageContextFromSelection(selection),
      bookTitle: widget.book.title,
      selection: ReaderAiSelectionContext(
        selectedText: selection.selectedText,
        contextBefore: selection.prefix,
        contextAfter: selection.suffix,
      ),
    );
  }

  Future<void> _showReadingSettings() async {
    final selectedMode = await showModalBottomSheet<NativePageMode>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => ReaderSettingsSheet(
        title: context.l10n.readingSettings,
        tabThemeLabel: context.l10n.readerSettingsTabTheme,
        tabTextLabel: context.l10n.readerSettingsTabText,
        tabLayoutLabel: context.l10n.readerSettingsTabLayout,
        tabPagingLabel: context.l10n.readerSettingsTabPaging,
        advancedTypographyTitle: context.l10n.readerSettingsAdvancedTypography,
        themeDescription: context.l10n.readerThemeDescription,
        pageModeTitle: context.l10n.pageTurningMode,
        pageModeSummary: _pageModeSummary(context),
        topBarStyleTitle: context.l10n.readerTopBarStyleTitle,
        topBarStyleSummary: _topBarStyleTitle(_topBarStyle),
        pullBookmarkTitle: context.l10n.readerPullBookmarkTitle,
        pullBookmarkHint: context.l10n.readerPullBookmarkHint,
        tapPageAnimationTitle: context.l10n.readerTapAnimationTitle,
        tapPageAnimationHint: context.l10n.readerTapAnimationHint,
        tapZonesTitle: context.l10n.tapZoneSettings,
        tapZonesHint: context.l10n.tapZoneSettingsHint,
        showTabletTwoPageToggle: ReaderLayoutBreakpoints.isTablet(
          MediaQuery.sizeOf(context),
        ),
        tabletTwoPageTitle: context.l10n.readerTabletTwoPageTitle,
        tabletTwoPageHint: context.l10n.readerTabletTwoPageHint,
        fontSizeLabel: context.l10n.fontSizeLabel,
        fontWeightLabel: context.l10n.readerFontWeightLabel,
        fontWeightValueLabels: <String>[
          context.l10n.readerFontWeightLight,
          context.l10n.readerFontWeightRegular,
          context.l10n.readerFontWeightMedium,
          context.l10n.readerFontWeightSemiBold,
          context.l10n.readerFontWeightBold,
        ],
        fontWeightHint: _readerFont.supportsVariableWeight
            ? context.l10n.readerFontWeightVariableHint(
                _readerFont.variableWeightMin!,
                _readerFont.variableWeightMax!,
              )
            : context.l10n.readerFontWeightSyntheticHint,
        fontWeightPreviewText: context.l10n.readerFontWeightPreview,
        lineHeightLabel: context.l10n.lineSpacingLabel,
        letterSpacingLabel: context.l10n.letterSpacingLabel,
        textAlignmentLabel: context.l10n.textAlignmentLabel,
        textAlignmentNaturalLabel: context.l10n.textAlignmentNatural,
        textAlignmentJustifiedLabel: context.l10n.textAlignmentJustified,
        firstLineIndentLabel: context.l10n.firstLineIndentLabel,
        paragraphSpacingLabel: context.l10n.paragraphSpacingLabel,
        horizontalMarginLabel: context.l10n.readerHorizontalMarginLabel,
        topMarginLabel: context.l10n.readerTopMarginLabel,
        bottomMarginLabel: context.l10n.readerBottomMarginLabel,
        txtChapterTitlePageTitle: widget.book.format.toLowerCase() == 'txt'
            ? context.l10n.readerTxtChapterTitlePageTitle
            : null,
        txtChapterTitlePageHint: widget.book.format.toLowerCase() == 'txt'
            ? context.l10n.readerTxtChapterTitlePageHint
            : null,
        themeId: _readerThemeId,
        fontSize: _fontSize,
        fontWeight: _fontWeight,
        fontFamily: _readerFont.family,
        fontFamilyFallback:
            readerFontFamilyFallbacks(
              fontFamily: _readerFont.family,
              configuredFallbacks: _readerFont.fallbackFamilies,
              locale: Localizations.maybeLocaleOf(context),
            ) ??
            const <String>[],
        fontWeightSupportsVariable: _readerFont.supportsVariableWeight,
        fontWeightVariableMin: _readerFont.variableWeightMin,
        fontWeightVariableMax: _readerFont.variableWeightMax,
        lineHeight: _lineHeight,
        letterSpacing: _letterSpacing,
        textAlignment: _textAlignment,
        firstLineIndent: _firstLineIndent,
        paragraphSpacing: _paragraphSpacing,
        horizontalMargin: _horizontalMargin,
        topMargin: _topMargin,
        bottomMargin: _bottomMargin,
        pullBookmarkEnabled: _pullBookmarkEnabled,
        tapPageAnimationEnabled: _tapPageAnimationEnabled,
        tabletTwoPageEnabled: _tabletTwoPageEnabled,
        txtChapterTitlePageEnabled: widget.book.format.toLowerCase() == 'txt'
            ? _txtChapterTitlePageEnabled
            : null,
        themeLabelFor: (id) => _readerThemeName(context, id),
        onThemeChanged: (id) => unawaited(_setReaderTheme(id)),
        onCustomThemeTap: _showCustomThemeEditor,
        onPageModeTap: _showPageModeSettings,
        onTopBarStyleTap: _showTopBarStyleSettings,
        onTapZonesTap: () => unawaited(_showTapZoneSettings()),
        onFontSizeChanged: (value) => unawaited(_updateLayout(fontSize: value)),
        onFontWeightChanged: (value) =>
            unawaited(_updateLayout(fontWeight: value)),
        onLineHeightChanged: (value) =>
            unawaited(_updateLayout(lineHeight: value)),
        onLetterSpacingChanged: (value) =>
            unawaited(_updateLayout(letterSpacing: value)),
        onTextAlignmentChanged: (value) =>
            unawaited(_updateLayout(textAlignment: value)),
        onFirstLineIndentChanged: (value) =>
            unawaited(_updateLayout(firstLineIndent: value)),
        onParagraphSpacingChanged: (value) =>
            unawaited(_updateLayout(paragraphSpacing: value)),
        onHorizontalMarginChanged: (value) =>
            unawaited(_updateLayout(horizontalMargin: value)),
        onTopMarginChanged: (value) =>
            unawaited(_updateLayout(topMargin: value)),
        onBottomMarginChanged: (value) =>
            unawaited(_updateLayout(bottomMargin: value)),
        onPullBookmarkChanged: (value) =>
            unawaited(_setInteractionPreferences(pullBookmark: value)),
        onTapPageAnimationChanged: (value) =>
            unawaited(_setInteractionPreferences(tapAnimation: value)),
        onTabletTwoPageChanged: (value) =>
            unawaited(_setTabletTwoPageEnabled(value)),
        onTxtChapterTitlePageChanged: widget.book.format.toLowerCase() == 'txt'
            ? (value) => unawaited(_setTxtChapterTitlePageEnabled(value))
            : null,
      ),
    );
    if (!mounted) return;
    await _applyReaderSystemUi();
    if (selectedMode == null || !mounted) return;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _setPageMode(selectedMode);
  }

  Future<void> _showReplaceRules() async {
    final chapter = _loadedChapters.isEmpty
        ? null
        : _loadedChapters[_chapterIndex.clamp(0, _loadedChapters.length - 1)];
    final fallbackOffset = _visiblePages.isEmpty
        ? 0
        : _visiblePages[_pageIndex.clamp(0, _visiblePages.length - 1)]
              .startOffset;
    final restoreProgress = chapter == null || chapter.plainText.isEmpty
        ? 0.0
        : ((_anchorOffset ?? fallbackOffset) / chapter.plainText.length).clamp(
            0.0,
            1.0,
          );
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ReplaceRulesPage()));
    if (!mounted) return;
    await _clearPersistedPaginationCache();
    if (!mounted) return;
    _setReaderState(() {
      _bookMemoryCache.remove(_bookCacheKey);
      _navigationMemoryCache.remove(_bookCacheKey);
      _paginationMemoryCache.remove(_bookCacheKey);
      _readerDependenciesInitialized = false;
      _pageCache.clear();
      _replacementRestoreChapterProgress = restoreProgress;
    });
    _initializeReaderDependencies();
  }

  Future<void> _setInteractionPreferences({
    bool? pullBookmark,
    bool? tapAnimation,
  }) async {
    _setReaderState(() {
      _pullBookmarkEnabled = pullBookmark ?? _pullBookmarkEnabled;
      _tapPageAnimationEnabled = tapAnimation ?? _tapPageAnimationEnabled;
    });
    await _readerSettingsStore.save(_readerSettings);
  }

  Future<void> _setTabletTwoPageEnabled(bool value) async {
    if (_tabletTwoPageEnabled == value) return;
    _setReaderState(() {
      _tabletTwoPageEnabled = value;
      _restoreAnchorAfterLayout = true;
      _lastSavedLocation = null;
    });
    await _readerSettingsStore.save(_readerSettings);
  }

  Future<void> _showCustomThemeEditor() async {
    Navigator.of(context).pop();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final result = await Navigator.of(context).push<ReaderCustomThemesResult>(
      MaterialPageRoute(
        builder: (_) => ReaderCustomThemesPage(
          initialThemes: ReaderThemes.customThemes,
          initialThemeOrder: ReaderThemes.themeOrder,
          initialSelectedThemeId: _readerThemeId,
        ),
      ),
    );
    if (result == null || !mounted) return;
    ReaderThemes.setCustomThemes(result.themes);
    ReaderThemes.setThemeOrder(result.themeOrder);
    _setReaderState(() {
      if (result.selectedThemeId != null) {
        _readerThemeId = result.selectedThemeId!;
      } else if (ReaderCustomTheme.isCustomThemeId(_readerThemeId) &&
          ReaderThemes.customThemeById(_readerThemeId) == null) {
        _readerThemeId = ReaderSettings.defaultThemeId;
      }
    });
    ReaderThemes.rememberSavedPalette(_readerTheme);
    await _readerSettingsStore.save(_readerSettings);
    await _applyReaderSystemUi();
  }

  String _pageModeSummary(BuildContext context) {
    switch (_pageMode) {
      case NativePageMode.verticalScroll:
        return _scrollByChapter
            ? context.l10n.readerModeVerticalScrollHint
            : context.l10n.readerModeWholeBookScrollHint;
      case NativePageMode.instantPage:
        return context.l10n.readerModeHorizontalPageHint;
      case NativePageMode.horizontalSlide:
        return context.l10n.readerModeHorizontalSlideHint;
      case NativePageMode.coverSlide:
        return context.l10n.readerModeCoverSlideHint;
      case NativePageMode.pageCurl:
        return context.l10n.readerModePageCurlHint;
    }
  }

  Future<void> _showPageModeSettings() async {
    var previewScrollByChapter = _scrollByChapter;
    final selectedMode = await showModalBottomSheet<NativePageMode>(
      context: context,
      backgroundColor: _readerTheme.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (menuContext) => StatefulBuilder(
        builder: (context, setMenuState) => ReaderPageModeSheet(
          palette: _readerTheme,
          title: context.l10n.pageTurningMode,
          selectedMode: _pageMode,
          titleFor: _pageModeTitle,
          hintFor: (mode) => mode == NativePageMode.verticalScroll
              ? (previewScrollByChapter
                    ? context.l10n.readerModeVerticalScrollHint
                    : context.l10n.readerModeWholeBookScrollHint)
              : _pageModeHint(mode),
          onSelected: (mode) => Navigator.of(menuContext).pop(mode),
          scrollByChapter: previewScrollByChapter,
          scrollByChapterTitle: context.l10n.readerScrollByChapterTitle,
          scrollByChapterOnHint: context.l10n.readerScrollByChapterOnHint,
          scrollByChapterOffHint: context.l10n.readerScrollByChapterOffHint,
          onScrollByChapterChanged: (value) {
            setMenuState(() => previewScrollByChapter = value);
            unawaited(_setScrollByChapter(value));
          },
        ),
      ),
    );
    if (selectedMode == null || !mounted) return;
    Navigator.of(context).pop(selectedMode);
  }

  Future<void> _showTopBarStyleSettings() async {
    final selectedStyle = await showModalBottomSheet<ReaderTopBarStyle>(
      context: context,
      backgroundColor: _readerTheme.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (menuContext) => ReaderTopBarStyleSheet(
        palette: _readerTheme,
        title: context.l10n.readerTopBarStyleTitle,
        selectedStyle: _topBarStyle,
        titleFor: _topBarStyleTitle,
        hintFor: _topBarStyleHint,
        onSelected: (style) => Navigator.of(menuContext).pop(style),
      ),
    );
    if (selectedStyle == null || !mounted) return;
    Navigator.of(context).pop();
    await _setTopBarStyle(selectedStyle);
  }

  String _pageModeTitle(NativePageMode mode) => switch (mode) {
    NativePageMode.verticalScroll => context.l10n.pageTurningScroll,
    NativePageMode.instantPage => context.l10n.readerModeHorizontalPage,
    NativePageMode.horizontalSlide => context.l10n.pageTurningSlide,
    NativePageMode.coverSlide => context.l10n.readerModeCoverSlide,
    NativePageMode.pageCurl => context.l10n.readerModePageCurl,
  };

  String _pageModeHint(NativePageMode mode) => switch (mode) {
    NativePageMode.verticalScroll => context.l10n.readerModeVerticalScrollHint,
    NativePageMode.instantPage => context.l10n.readerModeHorizontalPageHint,
    NativePageMode.horizontalSlide =>
      context.l10n.readerModeHorizontalSlideHint,
    NativePageMode.coverSlide => context.l10n.readerModeCoverSlideHint,
    NativePageMode.pageCurl => context.l10n.readerModePageCurlHint,
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
}
