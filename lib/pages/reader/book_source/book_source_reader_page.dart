import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/book_sources/services/book_source_chapter_text.dart';
import 'package:xxread/book_sources/services/source_cover_cache.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/book_source_text_paginator.dart';
import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/core/reader/platform_reader_aloud_media_session.dart';
import 'package:xxread/core/reader/native_text_paginator.dart';
import 'package:xxread/core/reader/reader_annotation.dart';
import 'package:xxread/core/reader/reader_custom_theme.dart';
import 'package:xxread/core/reader/reader_leaf_status.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_margin_settings.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_tap_zones.dart';
import 'package:xxread/core/reader/reader_text_pagination.dart';
import 'package:xxread/core/reader/reader_theme_order.dart';
import 'package:xxread/core/reader/reader_vertical_paging.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/bookmark.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/pages/book_sources/book_source_change_page.dart';
import 'package:xxread/pages/settings/replace_rules_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/books/book_note_dao.dart';
import 'package:xxread/services/books/bookmark_dao.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/reading/reading_resume_service.dart';
import 'package:xxread/services/reading/reading_stats_dao.dart';
import 'package:xxread/services/tts_service.dart';
import 'package:xxread/services/reader_aloud_service.dart';
import 'package:xxread/services/reader_aloud_session.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/font_catalog_helper.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/utils/system_ui_helper.dart';
import 'package:xxread/widgets/reader_ai_panel.dart';
import 'package:xxread/widgets/reader_annotated_text_page.dart';
import 'package:xxread/widgets/reader_aloud_panel.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';
import 'package:xxread/widgets/reader_cover_page_turn.dart';
import 'package:xxread/widgets/reader_chapter_title_page.dart';
import 'package:xxread/widgets/reader_navigation_sheet.dart';
import 'package:xxread/widgets/reader_opening_loader.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/widgets/reader_pull_bookmark.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';
import 'package:xxread/widgets/reader_shader_page_curl.dart';
import 'package:xxread/widgets/reader_tap_observer.dart';
import 'package:xxread/widgets/reader_tap_zone_editor.dart';
import 'package:xxread/widgets/reader_theme_background.dart';
import 'package:xxread/widgets/reader_top_information_bar.dart';
import 'package:xxread/widgets/reader_vertical_paging_surface.dart';
import 'package:xxread/widgets/side_toast.dart';

import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/pages/reader/themes/reader_custom_themes_page.dart';

part 'book_source_reader_vertical_paging.dart';
part 'book_source_reader_pagination_rendering.dart';
part 'book_source_reader_basic_turning.dart';
part 'book_source_reader_curl_rendering.dart';
part 'book_source_reader_catalog_loading.dart';
part 'book_source_reader_chapter_loading.dart';
part 'book_source_reader_navigation.dart';
part 'book_source_reader_settings.dart';
part 'book_source_reader_aloud_actions.dart';
part 'book_source_reader_shell.dart';

const double _bookSourceSpreadGutter = 24;
const int _bookSourceReadableChapterTextLimit = 8;
const _bookSourceOpeningLoaderDelay = Duration(milliseconds: 220);

typedef BookSourcePageMode = ReaderPageMode;

/// Immersive reader for chapters streamed from an Open Reading book source.
class BookSourceReaderPage extends StatefulWidget {
  final RegisteredBookSource source;
  final BookSourceBook book;
  final BookSourceClient? client;
  final BookSourceReadingProgressStore progressStore;
  final BookSourceShelfService? shelfService;
  final BookSourceClient Function()? clientFactory;
  final BookSourceShelfService Function(BookSourceClient client)?
  shelfServiceFactory;
  final ReaderThemePalette? initialTheme;
  final SourceCoverCache? remoteImageCache;

  const BookSourceReaderPage({
    super.key,
    required this.source,
    required this.book,
    this.client,
    this.progressStore = const BookSourceReadingProgressStore(),
    this.shelfService,
    this.clientFactory,
    this.shelfServiceFactory,
    this.initialTheme,
    this.remoteImageCache,
  }) : assert(client == null || clientFactory == null),
       assert(shelfService == null || shelfServiceFactory == null);

  @override
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageState();
}

class _BookSourceReaderPageState extends State<BookSourceReaderPage>
    with WidgetsBindingObserver {
  late final bool _ownsClient = widget.client == null;
  late final BookSourceClient _client =
      widget.client ?? (widget.clientFactory ?? BookSourceClient.new)();
  late final bool _ownsShelfService = widget.shelfService == null;
  late final BookSourceShelfService _shelfService =
      widget.shelfService ??
      (widget.shelfServiceFactory ??
          (client) => BookSourceShelfService(client: client))(_client);
  late final SourceCoverCache _remoteImageCache =
      widget.remoteImageCache ?? SourceCoverCache.instance;
  PageController _pageController = PageController();
  final ItemScrollController _verticalPageScrollController =
      ItemScrollController();
  final ItemPositionsListener _verticalPagePositionsListener =
      ItemPositionsListener.create();
  final ItemScrollController _verticalChapterScrollController =
      ItemScrollController();
  final ScrollOffsetController _verticalChapterOffsetController =
      ScrollOffsetController();
  final ItemPositionsListener _verticalChapterPositionsListener =
      ItemPositionsListener.create();
  final ReaderPageCurlController _pageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlController _spreadForwardPageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlController _spreadBackwardPageCurlController =
      ReaderPageCurlController();
  final ReaderPageCurlCoordinator _spreadPageCurlCoordinator =
      ReaderPageCurlCoordinator(gutterWidth: _bookSourceSpreadGutter);
  final ReaderCoverPageTurnController _coverPageTurnController =
      ReaderCoverPageTurnController();
  final ValueNotifier<double> _scrollProgress = ValueNotifier(0);
  final ReaderLeafStatusController _leafStatusController =
      ReaderLeafStatusController();

  List<BookSourceChapter> _rawChapters = const [];
  List<BookSourceChapter> _chapters = const [];
  List<ReaderNavigationChapter> _navigationChapters = const [];
  ReaderNavigationCatalog? _navigationCatalog;
  BookSourceChapterContent? _content;
  int _chapterIndex = 0;
  bool _loadingCatalog = true;
  bool _loadingContent = false;
  bool _controlsVisible = false;
  Object? _error;
  double _fontSize = 19;
  int _fontWeight = ReaderSettings.defaultFontWeight;
  double _lineHeight = 1.75;
  double _letterSpacing = ReaderSettings.defaultLetterSpacing;
  ReaderTextAlignment _textAlignment = ReaderSettings.defaultTextAlignment;
  int _firstLineIndent = ReaderSettings.defaultFirstLineIndent;
  int _paragraphSpacing = ReaderSettings.defaultParagraphSpacing;
  FontOption _readerFont = FontCatalog.defaultReaderFont;
  bool _readerFontReady = true;
  double _horizontalMargin = ReaderSettings.defaultHorizontalMargin;
  double _topMargin = ReaderMarginSettings.defaultTop;
  double _bottomMargin = ReaderMarginSettings.defaultBottom;
  String _readerThemeId = ReaderThemes.day.id;
  BookSourcePageMode _pageMode = ReaderSettings.defaultPageMode;
  bool _pullBookmarkEnabled = false;
  bool _tapPageAnimationEnabled = true;
  ReaderTapZones _tapZones = ReaderTapZones.defaults;
  bool _tapZoneEditorVisible = false;
  bool _tabletTwoPageEnabled = ReaderSettings.defaultTabletTwoPageEnabled;
  int _pageIndex = 0;
  bool _usesTwoPageLayout = false;
  int _pageCount = 1;
  int _verticalPageIndex = 0;
  int _verticalPageCount = 1;
  int _pageViewLeading = 0;
  bool _ignoreSlidePageChanges = true;
  int? _pendingSlideChapterIndex;
  int? _pendingSlideBoundaryViewIndex;
  double _pendingSlideRestoreProgress = 0;
  bool _slideChapterCommitCheckScheduled = false;
  double _restorePageProgress = 0;
  bool _restorePagedPosition = false;
  int? _restoreTextOffset;
  int? _verticalCanonicalOffset;
  String? _paginationKey;
  List<BookSourceTextPage> _paginatedPages = const [];
  int _chapterLoadSerial = 0;
  final Map<int, BookSourceChapterContent> _prefetchedContent = {};
  final Map<int, String> _readableChapterText = {};
  final Map<int, Future<BookSourceChapterContent>> _continuousContentLoads = {};
  final Map<int, _BookSourcePagedLayout> _pagedLayouts = {};
  final Set<int> _queuedPagedLayoutWarms = {};
  final Set<int> _warmedPagedLayoutIndexes = {};
  final Map<int, _BookSourceVerticalLayout> _verticalLayouts = {};
  final Map<String, GlobalKey> _verticalPartKeys = {};
  Future<void> _progressSaveQueue = Future<void>.value();
  bool _scrollByChapter = false;
  Size _pagedViewportSize = Size.zero;
  Size _verticalViewportSize = Size.zero;
  bool _exitPromptVisible = false;
  bool _allowPop = false;
  int? _shelfBookId;
  Timer? _progressSaveTimer;
  Timer? _controlsTimer;
  Timer? _pagedLayoutWarmTimer;
  int? _pagedLayoutWarmTimerIndex;
  final ReadingStatsDao _readingStatsDao = ReadingStatsDao();
  final BookmarkDao _bookmarkDao = BookmarkDao();
  final BookNoteDao _bookNoteDao = BookNoteDao();
  final ReaderSettingsStore _readerSettingsStore = const ReaderSettingsStore();
  final ReaderCustomThemeStore _customThemeStore =
      const ReaderCustomThemeStore();
  final ReaderThemeOrderStore _themeOrderStore = const ReaderThemeOrderStore();
  List<Bookmark> _bookmarks = const [];
  bool _bookmarkBusy = false;
  List<BookNote> _annotations = const [];
  bool _annotationBusy = false;
  bool _annotationInteractionActive = false;
  int _annotationRevision = 0;
  DateTime? _readingSessionStartedAt;
  int _sessionPagesRead = 0;
  bool _readerSystemUiApplied = false;
  bool _showOpeningLoader = false;
  bool _openingContentReadyScheduled = false;
  Timer? _openingLoaderTimer;
  ReaderTopBarStyle _topBarStyle = ReaderTopBarStyle.reader;
  ReaderAloudController? _readerAloudController;
  bool _readerAloudActive = false;
  ReaderAloudHighlight? _readerAloudHighlight;
  bool _readerAloudPositionRevealInProgress = false;
  int _readerAloudPositionRevealGeneration = 0;

  ReaderThemePalette get _readerTheme =>
      _loadingCatalog && widget.initialTheme != null
      ? widget.initialTheme!
      : ReaderThemes.byId(_readerThemeId);

  bool get _canPopWithoutPrompt => _allowPop || _shelfBookId != null;

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

  bool _shouldUseTwoPageLayout(Size size) =>
      _tabletTwoPageEnabled &&
      _pageMode == BookSourcePageMode.pageCurl &&
      ReaderLayoutBreakpoints.supportsTwoPageLayout(size);

  Size _paginationViewport(Size viewport, bool usesTwoPageLayout) =>
      usesTwoPageLayout
      ? Size((viewport.width - _bookSourceSpreadGutter) / 2, viewport.height)
      : viewport;

  int _spreadStartForPage(int pageIndex) => (pageIndex ~/ 2) * 2;

  int _lastVisiblePagedIndex(int pageIndex, int pageCount) {
    if (pageCount <= 0) return 0;
    final clamped = pageIndex.clamp(0, pageCount - 1);
    if (!_usesTwoPageLayout) return clamped;
    return math.min(_spreadStartForPage(clamped) + 1, pageCount - 1);
  }

  double _pagedReadingProgress(int pageIndex, int pageCount) => pageCount <= 1
      ? 1
      : (_lastVisiblePagedIndex(pageIndex, pageCount) / (pageCount - 1)).clamp(
          0.0,
          1.0,
        );

  void _updateReaderState(VoidCallback update) => setState(update);

  @override
  void initState() {
    super.initState();
    unawaited(ReplaceRuleService.instance.load());
    _showOpeningLoader = widget.initialTheme == null;
    if (!_showOpeningLoader) {
      _openingLoaderTimer = Timer(_bookSourceOpeningLoaderDelay, () {
        if (mounted) setState(() => _showOpeningLoader = true);
      });
    }
    WidgetsBinding.instance.addObserver(this);
    _leafStatusController
      ..addListener(_onLeafStatusChanged)
      ..start();
    unawaited(ReaderKeepScreenOnController.activate(this));
    _startReadingSession();
    _verticalPagePositionsListener.itemPositions.addListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.addListener(
      _onVerticalChapterPositionsChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _readerSystemUiApplied) return;
      final topBarStyle = await ReaderSystemUiController.applySavedPreference(
        overlayStyle: _readerSystemUiOverlayStyle,
      );
      if (!mounted) return;
      setState(() {
        _topBarStyle = topBarStyle;
        _readerSystemUiApplied = true;
      });
    });
    unawaited(_initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var nextReaderFont = FontCatalog.defaultReaderFont;
    var nextReaderFontReady = true;
    try {
      final appSettings = context.watch<AppSettingsNotifier>();
      nextReaderFontReady = appSettings.isInitialized;
      if (nextReaderFontReady) nextReaderFont = appSettings.readerFont;
    } on ProviderNotFoundException {
      // Reader widgets remain embeddable in tests and isolated previews.
    }
    _readerFontReady = nextReaderFontReady;
    if (_readerFont.id == nextReaderFont.id) return;
    _readerFont = nextReaderFont;
    _paginationKey = null;
    _paginatedPages = const [];
    _pagedLayouts.clear();
    _warmedPagedLayoutIndexes.clear();
    _verticalLayouts.clear();
    _restorePagedPosition = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startReadingSession();
      unawaited(ReaderKeepScreenOnController.reapply(this));
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
      if (!_loadingCatalog && _error == null) {
        unawaited(_syncVolumeKeyPaging());
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress());
      unawaited(_flushReadingSession());
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted && _readerThemeId == ReaderThemes.systemId) {
      setState(() {});
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
    }
  }

  void _startReadingSession() {
    _readingSessionStartedAt ??= DateTime.now();
  }

  Future<void> _flushReadingSession() async {
    final startedAt = _readingSessionStartedAt;
    if (startedAt == null) return;

    final endedAt = DateTime.now();
    final pagesRead = _sessionPagesRead;
    _readingSessionStartedAt = null;
    _sessionPagesRead = 0;

    try {
      await _readingStatsDao.recordReadingSession(
        startTime: startedAt,
        endTime: endedAt,
        bookId: _shelfBookId,
        pagesRead: pagesRead,
      );
    } catch (error) {
      debugPrint('record source reading session failed: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openingLoaderTimer?.cancel();
    _progressSaveTimer?.cancel();
    _controlsTimer?.cancel();
    _pagedLayoutWarmTimer?.cancel();
    _readerAloudController?.removeListener(_onReaderAloudChanged);
    _chapterLoadSerial++;
    unawaited(_saveProgress());
    unawaited(_flushReadingSession());
    _verticalPagePositionsListener.itemPositions.removeListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.removeListener(
      _onVerticalChapterPositionsChanged,
    );
    _pageController.dispose();
    _scrollProgress.dispose();
    _spreadPageCurlCoordinator.dispose();
    _leafStatusController
      ..removeListener(_onLeafStatusChanged)
      ..dispose();
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    unawaited(ReaderSystemUiController.restore());
    unawaited(ReadingResumeService.markClosed(_shelfBookId));
    _closeOwnedResources();
    super.dispose();
  }

  void _closeOwnedResources() {
    if (_ownsShelfService) _shelfService.close();
    if (_ownsClient) _client.close();
  }

  SystemUiOverlayStyle get _readerSystemUiOverlayStyle =>
      SystemUiHelper.overlayStyleForBackground(
        _readerTheme.background,
        transparentSystemBars: !GlassEffectConfig.shouldDisableBlur,
      );

  Future<void> _applyReaderSystemUi() => ReaderSystemUiController.apply(
    style: _topBarStyle,
    overlayStyle: _readerSystemUiOverlayStyle,
  );

  void _onLeafStatusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => _buildReaderShell();
}

class _BookSourcePagedLayout {
  const _BookSourcePagedLayout({
    required this.fingerprint,
    required this.pages,
  });

  final String fingerprint;
  final List<BookSourceTextPage> pages;
}

class _BookSourceVerticalLayout {
  const _BookSourceVerticalLayout({
    required this.fingerprint,
    required this.pages,
  });

  final String fingerprint;
  final List<BookSourceTextPage> pages;
}
