part of 'book_source_reader_page.dart';

extension _BookSourceReaderAloudActions on _BookSourceReaderPageState {
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
    _updateReaderState(() {
      _readerAloudActive = active;
      _readerAloudHighlight = highlight;
    });
  }

  Future<void> _revealReaderAloudPosition(ReaderAloudPosition position) async {
    if (!mounted || _chapters.isEmpty) return;
    final revealGeneration = ++_readerAloudPositionRevealGeneration;
    _readerAloudPositionRevealInProgress = true;
    try {
      final chapterIndex = position.chapterIndex.clamp(0, _chapters.length - 1);
      final content = await _continuousContentFor(chapterIndex);
      if (!mounted) return;
      final text =
          _readableChapterText[chapterIndex] ??
          await readableBookSourceChapterTextAsync(
            content,
            fallbackTitle: _chapters[chapterIndex].title,
          );
      final offset = position.offset.clamp(0, text.length);
      final progress = text.isEmpty ? 0.0 : offset / text.length;

      if (_pageMode == BookSourcePageMode.verticalScroll) {
        await _jumpToVerticalChapter(
          chapterIndex,
          textOffset: offset,
          progress: progress,
        );
        return;
      }
      if (chapterIndex != _chapterIndex || _pagedViewportSize.isEmpty) {
        await _loadChapter(chapterIndex, restoreProgress: progress);
        return;
      }
      final layout = _pagedLayoutFor(chapterIndex, content, _pagedViewportSize);
      final pageIndex = bookSourcePageIndexForOffset(layout.pages, offset);
      _paginatedPages = layout.pages;
      _setPagedIndex(pageIndex, jumpPageView: true);
    } finally {
      if (revealGeneration == _readerAloudPositionRevealGeneration) {
        _readerAloudPositionRevealInProgress = false;
      }
    }
  }

  Future<void> _persistReaderAloudPosition(ReaderAloudPosition position) async {
    if (_chapters.isEmpty) return;
    final chapterIndex = position.chapterIndex.clamp(0, _chapters.length - 1);
    final content = await _continuousContentFor(chapterIndex);
    final text =
        _readableChapterText[chapterIndex] ??
        await readableBookSourceChapterTextAsync(
          content,
          fallbackTitle: _chapters[chapterIndex].title,
        );
    final progress = text.isEmpty
        ? 0.0
        : (position.offset / text.length).clamp(0.0, 1.0);
    final progressSnapshot = BookSourceReadingProgress(
      chapterId: _chapters[chapterIndex].id,
      chapterIndex: chapterIndex,
      chapterProgress: progress,
      updatedAt: DateTime.now().toUtc(),
    );
    final shelfBookId = _shelfBookId;
    final chapterCount = _chapters.length;
    _progressSaveQueue = _progressSaveQueue.then((_) async {
      try {
        await widget.progressStore.save(
          sourceId: widget.source.id,
          bookId: widget.book.id,
          progress: progressSnapshot,
        );
        if (shelfBookId != null) {
          await _shelfService.updateShelfProgress(
            shelfBookId: shelfBookId,
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterProgress: progress,
          );
        }
      } catch (error) {
        debugPrint('save source reader aloud progress failed: $error');
      }
    });
    await _progressSaveQueue;
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

  /// Starts immediately from the reader toolbar; settings stay in the panel.
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

  Future<void> _showAskAiPanel() async {
    if (_chapters.isEmpty) return;
    final chapterIndex = _chapterIndex.clamp(0, _chapters.length - 1);
    var pageText = '';
    if (_pageMode == BookSourcePageMode.verticalScroll) {
      final pages = _verticalLayouts[chapterIndex]?.pages;
      if (pages != null && pages.isNotEmpty) {
        pageText = pages[_verticalPageIndex.clamp(0, pages.length - 1)].text;
      }
    } else if (_paginatedPages.isNotEmpty) {
      pageText =
          _paginatedPages[_pageIndex.clamp(0, _paginatedPages.length - 1)].text;
    }
    final content = _content;
    if (pageText.trim().isEmpty && content != null) {
      pageText =
          _readableChapterText[chapterIndex] ??
          readableBookSourceChapterText(
            content,
            fallbackTitle: _chapters[chapterIndex].title,
          );
    }
    await showReaderAiPanelSheet(
      context: context,
      palette: _readerTheme,
      themeData: _readerThemeData,
      meta: AIRequestMeta(
        bookId: _shelfBookId?.toString() ?? widget.book.id,
        chapterId: _chapters[chapterIndex].id,
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
        bookId: _shelfBookId?.toString() ?? widget.book.id,
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
    _controlsTimer?.cancel();
    final selectedMode = await showModalBottomSheet<BookSourcePageMode>(
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
        pageModeSummary: _pageModeSummary(),
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
        themeLabelFor: _readerThemeName,
        onThemeChanged: (themeId) =>
            unawaited(_updateReadingSettings(themeId: themeId)),
        onCustomThemeTap: _showCustomThemeEditor,
        onPageModeTap: _showPageModeSettings,
        onTopBarStyleTap: _showTopBarStyleSettings,
        onTapZonesTap: () => unawaited(_showTapZoneSettings()),
        onFontSizeChanged: (value) =>
            unawaited(_updateReadingSettings(fontSize: value)),
        onFontWeightChanged: (value) =>
            unawaited(_updateReadingSettings(fontWeight: value)),
        onLineHeightChanged: (value) =>
            unawaited(_updateReadingSettings(lineHeight: value)),
        onLetterSpacingChanged: (value) =>
            unawaited(_updateReadingSettings(letterSpacing: value)),
        onTextAlignmentChanged: (value) =>
            unawaited(_updateReadingSettings(textAlignment: value)),
        onFirstLineIndentChanged: (value) =>
            unawaited(_updateReadingSettings(firstLineIndent: value)),
        onParagraphSpacingChanged: (value) =>
            unawaited(_updateReadingSettings(paragraphSpacing: value)),
        onHorizontalMarginChanged: (value) =>
            unawaited(_updateReadingSettings(horizontalMargin: value)),
        onTopMarginChanged: (value) =>
            unawaited(_updateReadingSettings(topMargin: value)),
        onBottomMarginChanged: (value) =>
            unawaited(_updateReadingSettings(bottomMargin: value)),
        onPullBookmarkChanged: (value) =>
            unawaited(_updateReadingSettings(pullBookmarkEnabled: value)),
        onTapPageAnimationChanged: (value) =>
            unawaited(_updateReadingSettings(tapPageAnimationEnabled: value)),
        onTabletTwoPageChanged: (value) =>
            unawaited(_updateReadingSettings(tabletTwoPageEnabled: value)),
      ),
    );
    if (mounted) _updateReaderState(() => _controlsVisible = false);
    if (!mounted) return;
    await _applyReaderSystemUi();
    if (selectedMode == null || !mounted) return;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _updateReadingSettings(pageMode: selectedMode);
  }

  Future<void> _showReplaceRules() async {
    final restoreProgress = _currentReadingProgress;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ReplaceRulesPage()));
    if (!mounted) return;
    final chapters = _withReplacedChapterTitles(_rawChapters);
    _updateReaderState(() {
      _chapters = chapters;
      _navigationChapters = _navigationFor(chapters);
      _readableChapterText.clear();
      _pagedLayouts.clear();
      _verticalLayouts.clear();
    });
    await _loadChapter(
      _chapterIndex,
      restoreProgress: restoreProgress,
      saveCurrent: false,
    );
  }

  Future<void> _changeBookSource() async {
    await _saveProgress();
    final shelfBook = await _shelfService.findShelfBook(
      sourceId: widget.source.id,
      sourceBookId: widget.book.id,
    );
    if (!mounted) return;
    final result = await Navigator.of(context).push<BookSourceChangeResult>(
      MaterialPageRoute(
        builder: (_) => BookSourceChangePage(
          sourcesFuture: BookSourceRegistry().loadRunnableInBackground(),
          currentSource: widget.source,
          currentBook: widget.book,
          shelfBook: shelfBook,
          service: BookSourceChangeService(
            client: _client,
            shelfService: _shelfService,
            progressStore: widget.progressStore,
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    showSideToast(
      context,
      context.l10n.bookSourceChangeSuccess(result.source.name),
    );
    unawaited(_flushReadingSession());
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BookSourceReaderPage(
          source: result.source,
          book: result.book,
          client: _client,
          progressStore: widget.progressStore,
          shelfService: _shelfService,
          initialTheme: _readerTheme,
        ),
      ),
    );
    if (!mounted) return;
    BookOpenTransition.beginExit();
    _updateReaderState(() => _allowPop = true);
    Navigator.of(context).pop();
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
    final nextThemeId =
        result.selectedThemeId ??
        (ReaderCustomTheme.isCustomThemeId(_readerThemeId) &&
                ReaderThemes.customThemeById(_readerThemeId) == null
            ? ReaderSettings.defaultThemeId
            : _readerThemeId);
    await _updateReadingSettings(themeId: nextThemeId);
    await _applyReaderSystemUi();
  }

  Future<void> _showPageModeSettings() async {
    var previewScrollByChapter = _scrollByChapter;
    final selectedMode = await showModalBottomSheet<BookSourcePageMode>(
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
          hintFor: (mode) => mode == BookSourcePageMode.verticalScroll
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
}
