import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:epubx/epubx.dart' hide Image;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/core/reader/horizontal_page_turn_tracker.dart';
import 'package:xxread/core/reader/platform_reader_aloud_media_session.dart';
import 'package:xxread/core/reader/indexed_text_reader.dart';
import 'package:xxread/core/reader/native_text_paginator.dart';
import 'package:xxread/core/reader/reader_annotation.dart';
import 'package:xxread/core/reader/reader_custom_theme.dart';
import 'package:xxread/core/reader/reader_leaf_status.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_margin_settings.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/core/reader/reader_position_save_queue.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_tap_zones.dart';
import 'package:xxread/core/reader/reader_text_characters.dart';
import 'package:xxread/core/reader/reader_text_layout.dart';
import 'package:xxread/core/reader/reader_text_pagination.dart';
import 'package:xxread/core/reader/reader_pagination_cache_codec.dart';
import 'package:xxread/core/reader/reader_theme_order.dart';
import 'package:xxread/core/reader/reader_vertical_paging.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/core/reader/txt_chapter_parser.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/bookmark.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/pages/settings/replace_rules_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/book_note_dao.dart';
import 'package:xxread/services/books/bookmark_dao.dart';
import 'package:xxread/services/books/enhanced_txt_import_service.dart';
import 'package:xxread/services/books/epub_native_parser.dart';
import 'package:xxread/services/books/kindle_book_parser.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';
import 'package:xxread/services/books/web_book_file_store.dart';
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

import 'package:xxread/pages/reader/themes/reader_custom_themes_page.dart';

part 'native_reader_chapter.dart';
part 'native_reader_pagination.dart';
part 'native_reader_pagination_cache.dart';
part 'native_reader_parsers.dart';
part 'native_reader_horizontal_paging.dart';
part 'native_reader_vertical_paging.dart';
part 'native_reader_rendering.dart';
part 'native_reader_loading.dart';
part 'native_reader_configuration.dart';
part 'native_reader_interaction.dart';
part 'native_reader_controls.dart';
part 'native_reader_navigation.dart';
part 'native_reader_page_cache.dart';
part 'native_reader_shell.dart';
part 'native_reader_scaffold.dart';
part 'native_reader_session.dart';
part 'native_reader_horizontal_window.dart';
part 'native_reader_document_parsers.dart';
part 'native_reader_continuous_layout.dart';

typedef NativePageMode = ReaderPageMode;

const int _largeTxtFileThreshold = 16 * 1024 * 1024;
const int _txtChapterCacheVersion = 4;
const double _imagePageGap = 10;
const int _imagePageImageFlex = 5;
const int _imagePageTextFlex = 6;
const Duration _openingLoaderDelay = Duration(milliseconds: 220);
const double _spreadGutter = 24.0;
final Map<String, Future<List<_NativeChapter>>> _bookMemoryCache = {};
final Map<String, List<ReaderNavigationChapter>> _navigationMemoryCache = {};
final Map<String, Map<String, List<_ReaderPageData>>> _paginationMemoryCache =
    {};
final Map<String, Future<void>> _epubFontLoads = <String, Future<void>>{};

Future<void> _registerEpubFonts(Map<String, String> fonts) => Future.wait(
  fonts.entries.map((entry) {
    return _epubFontLoads.putIfAbsent(entry.key, () async {
      try {
        final bytes = await File(entry.value).readAsBytes();
        final loader = FontLoader(entry.key)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
      } catch (error) {
        debugPrint('EPUB font registration failed (${entry.key}): $error');
      }
    });
  }),
);

Future<Directory> _readerCacheDirectory() async {
  try {
    return await getTemporaryDirectory();
  } on MissingPluginException catch (error) {
    debugPrint('EPUB cache uses temporary directory: $error');
    return Directory.systemTemp;
  }
}

@visibleForTesting
Future<bool> waitForReaderOpeningRouteToSettle({
  required Animation<double>? routeAnimation,
  required bool routeEntranceCompleted,
  required bool Function() isMounted,
}) async {
  // The live animation status is authoritative. A completed flag captured
  // before the route's first forward tick must not cancel active opening.
  if (routeAnimation == null ||
      routeAnimation.status == AnimationStatus.completed) {
    return isMounted();
  }

  final completed = Completer<bool>();
  var sawRouteMotion =
      routeAnimation.status == AnimationStatus.forward ||
      routeAnimation.status == AnimationStatus.reverse;
  void handleStatus(AnimationStatus status) {
    if (completed.isCompleted) return;
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      sawRouteMotion = true;
      return;
    }
    if (status == AnimationStatus.completed) completed.complete(true);
    // A newly pushed route is briefly `dismissed` before its first forward
    // tick. Only treat dismissed as cancellation after motion has actually
    // started; otherwise every large TXT returns an empty chapter list.
    if (status == AnimationStatus.dismissed && sawRouteMotion) {
      completed.complete(false);
    }
  }

  routeAnimation.addStatusListener(handleStatus);
  handleStatus(routeAnimation.status);
  final routeOpened = await completed.future;
  routeAnimation.removeStatusListener(handleStatus);
  return routeOpened && isMounted();
}

class NativeReaderPage extends StatefulWidget {
  const NativeReaderPage({
    super.key,
    required this.book,
    this.initialTheme,
    @visibleForTesting this.onPaginationCacheMiss,
    @visibleForTesting this.paginationCacheDao,
    @visibleForTesting this.usePaginationMemoryCache = true,
    @visibleForTesting this.imagePrecacher,
  });

  final Book book;
  final ReaderThemePalette? initialTheme;
  final ValueChanged<int>? onPaginationCacheMiss;
  final PaginationCacheDao? paginationCacheDao;
  final bool usePaginationMemoryCache;
  final Future<void> Function(ImageProvider image)? imagePrecacher;

  @override
  State<NativeReaderPage> createState() => _NativeReaderPageState();
}

class _NativeReaderPageState extends State<NativeReaderPage>
    with WidgetsBindingObserver {
  late Future<List<_NativeChapter>> _chaptersFuture;
  PageController? _pageController;
  int _pageControllerGeneration = 0;
  bool _horizontalChapterJumpPending = false;
  bool _horizontalChapterJumpRevealScheduled = false;
  bool _horizontalBackwardExpansionPending = false;
  bool _horizontalBackwardExpansionWarmPending = false;
  bool _horizontalForwardExpansionPending = false;
  bool _horizontalForwardContractionPending = false;
  final HorizontalPageTurnTracker<_BookPageRef> _horizontalPageTurnTracker =
      HorizontalPageTurnTracker<_BookPageRef>();
  PendingHorizontalPage<_BookPageRef>? get _pendingHorizontalPage =>
      _horizontalPageTurnTracker.pending;
  _PendingHorizontalForwardBoundary? _pendingHorizontalForwardBoundary;
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
      ReaderPageCurlCoordinator(gutterWidth: _spreadGutter);
  final ReaderCoverPageTurnController _coverPageTurnController =
      ReaderCoverPageTurnController();
  final ValueNotifier<double> _verticalScrollProgress = ValueNotifier(0);
  final ReaderLeafStatusController _leafStatusController =
      ReaderLeafStatusController();
  final Set<String> _queuedHorizontalPaginationWarms = {};
  String? _scheduledImagePrecacheKey;
  final Map<String, GlobalKey> _continuousPartKeys = {};
  final Map<String, List<_ContinuousReaderPart>> _continuousPartCache = {};
  late Map<String, List<_ReaderPageData>> _pageCache;
  late final PaginationCacheDao _paginationCacheDao =
      widget.paginationCacheDao ?? PaginationCacheDao();
  final Map<String, Uint8List> _persistedPaginationPayloads = {};
  Future<void> _paginationCacheLoadFuture = Future<void>.value();
  Future<void> _paginationCacheWriteQueue = Future<void>.value();
  List<_NativeChapter> _loadedChapters = const [];
  List<ReaderNavigationChapter> _navigationChapters = const [];
  ReaderNavigationCatalog? _navigationCatalog;
  int? _lastNavigationJumpPosition;
  bool _readerDependenciesInitialized = false;
  int _chapterIndex = 0;
  int _chapterLoadSerial = 0;
  int _horizontalFirstChapter = 0;
  int _horizontalLastChapter = 0;
  final _horizontalPageIndexMap = _HorizontalPageIndexMap();
  int _pageIndex = 0;
  int? _anchorOffset;
  int? _verticalCanonicalOffset;
  double? _replacementRestoreChapterProgress;
  String? _savedChapterId;
  bool _savedChapterResolved = false;
  bool _restoreAnchorAfterLayout = true;
  bool _initialPositionRestored = false;
  bool _initialPositionRestoreScheduled = false;
  bool _exitInProgress = false;
  bool _exitPositionCommitted = false;
  String? _lastSavedLocation;
  late final ReaderPositionSaveQueue _positionSaveQueue =
      ReaderPositionSaveQueue(
        onError: (error, stackTrace) {
          debugPrint('save reader position failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        },
      );
  bool _openPreviousChapterAtLastPage = false;
  bool _controlsVisible = false;
  NativePageMode _pageMode = ReaderSettings.defaultPageMode;
  bool _scrollByChapter = false;
  double _fontSize = 19;
  int _fontWeight = ReaderSettings.defaultFontWeight;
  double _lineHeight = 1.75;
  double _letterSpacing = ReaderSettings.defaultLetterSpacing;
  ReaderTextAlignment _textAlignment = ReaderSettings.defaultTextAlignment;
  int _firstLineIndent = ReaderSettings.defaultFirstLineIndent;
  int _paragraphSpacing = ReaderSettings.defaultParagraphSpacing;
  double _horizontalMargin = 18;
  double _topMargin = ReaderMarginSettings.defaultTop;
  double _bottomMargin = ReaderMarginSettings.defaultBottom;
  FontOption _readerFont = FontCatalog.defaultReaderFont;
  String _readerThemeId = ReaderThemes.day.id;
  bool _pullBookmarkEnabled = false;
  bool _tapPageAnimationEnabled = true;
  ReaderTapZones _tapZones = ReaderTapZones.defaults;
  bool _tapZoneEditorVisible = false;
  bool _tabletTwoPageEnabled = ReaderSettings.defaultTabletTwoPageEnabled;
  bool _txtChapterTitlePageEnabled = true;
  bool _readerSettingsLoaded = false;
  bool _readerFontReady = true;
  bool _readerSystemUiApplied = false;
  bool _readerSystemUiApplyScheduled = false;
  bool _routeEntranceCompleted = false;
  ValueListenable<bool>? _openingFlightSettled;
  ValueListenable<bool>? _openingCoverHoldReached;
  bool _showOpeningLoader = false;
  bool _openingContentReadyScheduled = false;
  Timer? _openingLoaderTimer;
  ReaderTopBarStyle _topBarStyle = ReaderTopBarStyle.reader;
  ReaderAloudController? _readerAloudController;
  bool _readerAloudActive = false;
  ReaderAloudHighlight? _readerAloudHighlight;
  bool _readerAloudPositionRevealInProgress = false;
  int _readerAloudPositionRevealGeneration = 0;
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
  List<_ReaderPageData> _visiblePages = const [];
  List<_ContinuousReaderPart> _visibleContinuousParts = const [];
  List<_NativeChapter> _visibleChapters = const [];
  int _visibleChapterCount = 0;
  bool _visibleUsesTwoPageLayout = false;
  Size _verticalViewportSize = Size.zero;
  TextDirection _verticalTextDirection = TextDirection.ltr;
  TextScaler _verticalTextScaler = TextScaler.noScaling;
  Size _lastPaginationSize = Size.zero;
  Size _readerViewportSize = Size.zero;
  bool? _lastUsesTwoPageLayout;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    unawaited(ReplaceRuleService.instance.load());
    _showOpeningLoader = widget.initialTheme == null;
    if (!_showOpeningLoader) {
      _openingLoaderTimer = Timer(_openingLoaderDelay, () {
        if (mounted) setState(() => _showOpeningLoader = true);
      });
    }
    WidgetsBinding.instance.addObserver(this);
    _leafStatusController
      ..addListener(_onLeafStatusChanged)
      ..start();
    unawaited(ReaderKeepScreenOnController.activate(this));
    unawaited(ReadingResumeService.markReading(widget.book.id));
    _startReadingSession();
    _chapterIndex = widget.book.currentPage;
    _resetHorizontalPagingWindow(_chapterIndex);
    final savedLocator = widget.book.toCanonicalLocator();
    _anchorOffset = savedLocator?.textAnchor?.startOffsetUtf16;
    _verticalCanonicalOffset = _anchorOffset;
    _savedChapterId =
        savedLocator?.chapterId ?? savedLocator?.textAnchor?.chapterId;
    _initialPositionRestored = _anchorOffset == null;
    _verticalPagePositionsListener.itemPositions.addListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.addListener(
      _onVerticalChapterPositionsChanged,
    );
    unawaited(_loadPageMode());
    unawaited(_loadBookmarks());
    unawaited(_loadAnnotations());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startReadingSession();
      unawaited(ReaderKeepScreenOnController.reapply(this));
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
      if (_readerSettingsLoaded) unawaited(_syncVolumeKeyPaging());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_flushReadingSession());
      unawaited(_persistCurrentReaderPosition(reason: 'lifecycle'));
      unawaited(_flushPendingPositionSave());
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted && _readerThemeId == ReaderThemes.systemId) {
      setState(() {});
      if (_readerSystemUiApplied) unawaited(_applyReaderSystemUi());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRouteAnimation();
    _bindOpeningFlightSettled();
    _bindOpeningCoverHold();
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
    if (_readerFont.id != nextReaderFont.id) {
      _readerFont = nextReaderFont;
      if (_readerDependenciesInitialized) {
        _pageCache.clear();
        _restoreAnchorAfterLayout = true;
      }
    }
    _initializeReaderDependencies();
    if (_routeEntranceCompleted) _scheduleInitialReaderSystemUi();
  }

  /// 打开动画（封面飞行 + 正文渐显）是否已完全结束。
  ///
  /// 路由动画结束时正文渐显往往仍在播放；相邻章节的整章排版、系统栏切换
  /// 都等待该信号，避免这些主线程重活掉帧落在动画后半段。
  bool get _openingFlightSettledNow => _openingFlightSettled?.value ?? true;

  void _bindOpeningFlightSettled() {
    final next = BookOpenTransition.openingFlightSettledListenableOf(context);
    if (identical(next, _openingFlightSettled)) return;
    _openingFlightSettled?.removeListener(_onOpeningFlightSettledChanged);
    _openingFlightSettled = next;
    if (next != null && !next.value) {
      next.addListener(_onOpeningFlightSettledChanged);
    }
  }

  void _onOpeningFlightSettledChanged() {
    _openingFlightSettled?.removeListener(_onOpeningFlightSettledChanged);
    if (!mounted) return;
    _scheduleInitialReaderSystemUi();
    setState(() {});
  }

  /// 封面飞行路由动画是否已完全结束（或本就没有封面飞行）。
  ///
  /// 底层路由动画请求新帧会一直持续到 100%，即使封面在视觉上早就静止；
  /// 这期间执行整章排版（一次 50~100ms）仍会挤占帧预算、拖慢同时播放
  /// 的其它动画（如首页悬浮导航收起），实测会掉帧。等到路由动画彻底
  /// 停止请求新帧才是真正的无感知窗口。
  bool get _openingCoverHoldReachedNow =>
      _openingCoverHoldReached?.value ?? true;

  void _bindOpeningCoverHold() {
    final next = BookOpenTransition.openingCoverHoldListenableOf(context);
    if (identical(next, _openingCoverHoldReached)) return;
    _openingCoverHoldReached?.removeListener(_onOpeningCoverHoldChanged);
    _openingCoverHoldReached = next;
    if (next != null && !next.value) {
      next.addListener(_onOpeningCoverHoldChanged);
    }
  }

  void _onOpeningCoverHoldChanged() {
    _openingCoverHoldReached?.removeListener(_onOpeningCoverHoldChanged);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _waitForOpeningCoverHold() {
    final listenable = _openingCoverHoldReached;
    if (listenable == null || listenable.value) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    late final VoidCallback onChanged;
    onChanged = () {
      if (!listenable.value) return;
      listenable.removeListener(onChanged);
      if (!completer.isCompleted) completer.complete();
    };
    listenable.addListener(onChanged);
    return completer.future;
  }

  void _bindRouteAnimation() {
    final nextAnimation = ModalRoute.of(context)?.animation;
    if (identical(_routeAnimation, nextAnimation)) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatusChanged);
    _routeAnimation = nextAnimation;
    if (nextAnimation == null ||
        nextAnimation.status == AnimationStatus.completed) {
      _routeEntranceCompleted = true;
      return;
    }
    _routeEntranceCompleted = false;
    nextAnimation.addStatusListener(_onRouteAnimationStatusChanged);
  }

  void _onRouteAnimationStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatusChanged);
    _routeEntranceCompleted = true;
    _scheduleInitialReaderSystemUi();
    setState(() {});
  }

  void _scheduleInitialReaderSystemUi() {
    if (!_routeEntranceCompleted ||
        !_openingFlightSettledNow ||
        _readerSystemUiApplied ||
        _readerSystemUiApplyScheduled) {
      return;
    }
    _readerSystemUiApplyScheduled = true;
    // Changing window insets while the cover flight or the reveal crossfade
    // is still playing forces the live reader route to relayout mid-flight.
    // Wait for the whole visible opening animation to settle, then apply the
    // saved reader chrome on the following frame.
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
  }

  String get _bookCacheKey =>
      '${widget.book.format.toLowerCase() == 'txt' ? 'txt-parser-v5:' : ''}'
      '${widget.book.contentHash ?? widget.book.filePath}:'
      '${widget.book.fileModifiedTime ?? (kIsWeb ? 0 : File(widget.book.filePath).lastModifiedSync().millisecondsSinceEpoch)}:'
      '${widget.book.textEncoding ?? 'auto'}';

  bool get _isLargeTxtBook {
    if (widget.book.format.toLowerCase() != 'txt') return false;
    if (kIsWeb) return false;
    try {
      return File(widget.book.filePath).lengthSync() > _largeTxtFileThreshold;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openingLoaderTimer?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatusChanged);
    _openingFlightSettled?.removeListener(_onOpeningFlightSettledChanged);
    _openingCoverHoldReached?.removeListener(_onOpeningCoverHoldChanged);
    _readerAloudController?.removeListener(_onReaderAloudChanged);
    unawaited(_flushReadingSession());
    unawaited(_flushPendingPositionSave());
    _pageController?.dispose();
    _verticalPagePositionsListener.itemPositions.removeListener(
      _onVerticalPagePositionsChanged,
    );
    _verticalChapterPositionsListener.itemPositions.removeListener(
      _onVerticalChapterPositionsChanged,
    );
    _verticalScrollProgress.dispose();
    _spreadPageCurlCoordinator.dispose();
    _leafStatusController
      ..removeListener(_onLeafStatusChanged)
      ..dispose();
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    unawaited(ReaderSystemUiController.restore());
    unawaited(ReadingResumeService.markClosed(widget.book.id));
    super.dispose();
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

  Future<void> _saveCanonicalProgress(
    _NativeChapter chapter,
    _ReaderPageData page,
    int chapterIndex,
  ) {
    _anchorOffset = page.startOffset;
    final bookId = widget.book.id;
    if (bookId == null) return Future<void>.value();
    final excerptEnd = (page.startOffset + 72).clamp(
      0,
      chapter.plainText.length,
    );
    final excerpt = chapter.plainText.substring(page.startOffset, excerptEnd);
    final locator = CanonicalLocator.fromComponents(
      format: BookFormat.fromFileExtension(widget.book.format),
      chapterId: chapter.id,
      offset: page.startOffset,
      excerpt: excerpt,
      progression: chapter.plainText.isEmpty
          ? 0
          : page.startOffset / chapter.plainText.length,
    );
    final chapterProgress = chapter.plainText.isEmpty
        ? 1.0
        : (page.endOffset / chapter.plainText.length).clamp(0.0, 1.0);
    final chapterCount = _loadedChapters.length;
    final readingProgress = chapterCount <= 0
        ? null
        : ((chapterIndex + chapterProgress) / chapterCount).clamp(0.0, 1.0);
    final canonicalLocator = LocatorCodec.encodeCanonicalLocator(locator);
    unawaited(
      ReadingResumeService.recordPosition(
        bookId: bookId,
        canonicalLocator: canonicalLocator,
        chapterIndex: chapterIndex,
      ),
    );
    return _queuePositionWrite(
      () => BookDao().updateBookCanonicalLocator(
        bookId,
        canonicalLocator,
        null,
        _layoutSignature,
        chapterIndex,
        readingProgress: readingProgress,
      ),
    );
  }

  Future<void> _queueBookProgress(int bookId, int chapterIndex) {
    return _queuePositionWrite(
      () => BookDao().updateBookProgress(bookId, chapterIndex),
    );
  }

  Future<void> _queuePositionWrite(Future<void> Function() write) {
    return _positionSaveQueue.enqueue(write);
  }

  void _setReaderState(VoidCallback callback) => setState(callback);

  Future<void> _setPageMode(NativePageMode mode) async {
    if (_pageMode == mode) return;
    final previousPageController = _pageController;
    _pageController = null;
    _pageControllerGeneration++;
    setState(() {
      _pageMode = mode;
      _pageIndex = 0;
      _restoreAnchorAfterLayout = true;
      _lastSavedLocation = null;
      _resetHorizontalPagingWindow(
        _chapterIndex,
        chapterCount: _loadedChapters.length,
      );
      _controlsVisible = false;
    });
    if (previousPageController != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => previousPageController.dispose(),
      );
    }
    unawaited(_syncVolumeKeyPaging());
    await _readerSettingsStore.save(_readerSettings);
  }

  Future<void> _setScrollByChapter(bool value) async {
    if (_scrollByChapter == value) return;
    setState(() {
      _scrollByChapter = value;
      _controlsVisible = false;
    });
    await _readerSettingsStore.saveScrollByChapter(value);
  }

  void _resolveSavedChapter(List<_NativeChapter> chapters) {
    if (_savedChapterResolved) return;
    _savedChapterResolved = true;
    final savedChapterId = _savedChapterId;
    if (savedChapterId == null || savedChapterId.isEmpty) return;
    final resolvedIndex = chapters.indexWhere(
      (chapter) => chapter.id == savedChapterId,
    );
    if (resolvedIndex < 0) return;
    _chapterIndex = resolvedIndex;
    _resetHorizontalPagingWindow(resolvedIndex, chapterCount: chapters.length);
  }

  @override
  Widget build(BuildContext context) => _buildReaderPage(context);
}
