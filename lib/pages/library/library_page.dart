// 文件说明：书库页面，负责书籍列表、筛选、排序和进入阅读。
// 技术要点：Flutter UI、文件系统、渲染层。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/core/reader/native_reader_service.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/pages/book_sources/book_source_change_page.dart';
import 'package:xxread/pages/reader/book_source/book_source_reader_page.dart';
import 'package:xxread/pages/reader/book_source/online_comic_reader_page.dart';
import 'package:xxread/pages/settings/sync/book_file_sync_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/ai_preprocess_task_controller.dart';
import 'package:xxread/services/books/book_services.dart';
import 'package:xxread/services/books/book_text_extraction_service.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/library/library_services.dart';
import 'package:xxread/services/library/download_task_controller.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/layout_helper.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/utils/system_ui_helper.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/app_brand_icon.dart';
import 'package:xxread/widgets/generated_book_cover.dart';
import 'package:xxread/widgets/scrolling_text.dart';
import 'package:xxread/widgets/side_toast.dart';
import 'package:xxread/widgets/source_cover_image.dart';

import 'import_book/import_book_page.dart';
import 'download_tasks_page.dart';
import 'library_grid_book_details.dart';
import 'library_selection_model.dart';

part 'parts/library_book_commands_part.dart';
part 'parts/library_book_deletion_part.dart';
part 'parts/library_book_details_part.dart';
part 'parts/library_book_widgets_part.dart';
part 'parts/library_chrome_part.dart';
part 'parts/library_collection_part.dart';

enum _LibraryFilter { all, reading, finished }

/// 首页壳层顶栏与书库页之间的桥：顶栏按钮触发搜索/筛选，
/// 书库页把筛选是否生效同步回来点亮按钮。
class LibraryPageController {
  _LibraryPageState? _state;

  /// 当前是否有生效的筛选（非“全部”）。顶栏据此点亮筛选按钮。
  final ValueNotifier<bool> filterActive = ValueNotifier<bool>(false);
  final ValueNotifier<LibrarySelectionSnapshot> selection =
      ValueNotifier<LibrarySelectionSnapshot>(
        const LibrarySelectionSnapshot.inactive(),
      );

  void toggleSearch() => _state?._toggleSearchBar();

  Future<void> showFilterMenu(Rect anchor) async =>
      _state?._showFilterMenu(anchor);

  void exitSelection() => _state?._exitSelectionMode();

  void selectAllVisible() => _state?._selectAllVisibleBooks();

  Future<void> deleteSelected() async => _state?._confirmDeleteSelectedBooks();

  void dispose() {
    filterActive.dispose();
    selection.dispose();
  }
}

class LibrarySelectionSnapshot {
  final bool isActive;
  final int selectedCount;

  const LibrarySelectionSnapshot({
    required this.isActive,
    required this.selectedCount,
  });

  const LibrarySelectionSnapshot.inactive()
    : isActive = false,
      selectedCount = 0;

  @override
  bool operator ==(Object other) =>
      other is LibrarySelectionSnapshot &&
      other.isActive == isActive &&
      other.selectedCount == selectedCount;

  @override
  int get hashCode => Object.hash(isActive, selectedCount);
}

class LibraryPage extends StatefulWidget {
  final LibraryPageController? controller;
  final Future<List<Book>> Function()? booksLoader;
  final BookSourceShelfService? sourceShelfService;
  final BookSourceShelfService Function()? sourceShelfServiceFactory;

  const LibraryPage({
    super.key,
    this.controller,
    this.booksLoader,
    this.sourceShelfService,
    this.sourceShelfServiceFactory,
  }) : assert(sourceShelfService == null || sourceShelfServiceFactory == null);

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Book> _books = [];
  int _booksRevision = 0;
  int _visibleBooksCacheRevision = -1;
  _LibraryFilter? _visibleBooksCacheFilter;
  String _visibleBooksCacheQuery = '';
  List<Book> _visibleBooksCache = const [];
  bool _isInitialLoading = true;
  Object? _loadError;
  final _bookDao = BookDao();
  late final BookDeletionService _bookDeletionService;
  late final bool _ownsSourceShelfService = widget.sourceShelfService == null;
  late final BookSourceShelfService _sourceShelfService =
      widget.sourceShelfService ??
      (widget.sourceShelfServiceFactory ?? BookSourceShelfService.new)();
  StreamSubscription<void>? _librarySubscription;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  String _searchQuery = '';
  bool _searchBarVisible = false;
  _LibraryFilter _selectedFilter = _LibraryFilter.all;
  final LibrarySelectionModel _selection = LibrarySelectionModel();
  final Set<String> _exportingBookPaths = <String>{};

  /// 经典封面展开需要在点击和返回时定位书库里的原封面。
  final Map<int, GlobalKey> _coverKeys = <int, GlobalKey>{};

  GlobalKey _coverKeyFor(Book book) =>
      _coverKeys.putIfAbsent(book.id!, () => GlobalKey());

  bool get _isMaterial3Style {
    return Theme.of(
          context,
        ).extension<UiStyleThemeExtension>()?.isMaterial3Style ??
        false;
  }

  Future<void> _openBook(
    Book book, {
    required LibraryBookOpenAnimation libraryAnimation,
    required LibraryBookOpenAnimationPace animationPace,
    BookOpenAnimation? animation,
  }) async {
    final openingActivity = BookOpenTransition.beginActivity();
    final initialThemeFuture = ReaderThemes.loadSavedPalette();
    try {
      final fullBook = await _bookDao.getBookById(book.id!);
      if (fullBook == null || !mounted) return;
      final initialTheme = await initialThemeFuture;
      if (!mounted) return;
      if (fullBook.isOnline) {
        try {
          final source = _sourceShelfService.sourceFrom(fullBook);
          final sourceBook = _sourceShelfService.sourceBookFrom(fullBook);
          final reader = isOnlineComicSource(source, sourceBook)
              ? OnlineComicReaderPage(
                  source: source,
                  book: sourceBook,
                  shelfService: _sourceShelfService,
                  initialTheme: initialTheme,
                )
              : BookSourceReaderPage(
                  source: source,
                  book: sourceBook,
                  shelfService: _sourceShelfService,
                  initialTheme: initialTheme,
                );
          final route = BookOpenTransition.createRoute<void>(
            reader,
            animation: animation,
            libraryAnimation: animation == null ? libraryAnimation : null,
            animationPace: animationPace,
            readerBackgroundColor: initialTheme.background,
            waitForReaderReady: true,
          );
          await BookOpenTransition.push<void>(context, route);
        } catch (error) {
          if (mounted) {
            showSideToast(
              context,
              context.l10n.bookSourceOnlineDataBroken('$error'),
              kind: SideToastKind.error,
            );
          }
        }
      } else {
        await NativeReaderService.openBook(
          context,
          fullBook,
          animation: animation,
          libraryAnimation: animation == null ? libraryAnimation : null,
          animationPace: animationPace,
          initialTheme: initialTheme,
        );
      }
      if (mounted) _loadBooks();
    } finally {
      openingActivity.dispose();
    }
  }

  Future<void> _openBookWithSelectedAnimation(
    Book book, {
    required GlobalKey coverKey,
    required BorderRadius radius,
    required WidgetBuilder coverBuilder,
  }) {
    final settings = context.read<AppSettingsNotifier>();
    final selected = settings.libraryBookOpenAnimation;
    final animation = selected == LibraryBookOpenAnimation.classicCover
        ? BookOpenAnimation.fromCoverKey(
            coverKey,
            radius: radius,
            coverBuilder: coverBuilder,
          )
        : null;
    return _openBook(
      book,
      libraryAnimation: selected,
      animationPace: settings.libraryBookOpenAnimationPace,
      animation: animation,
    );
  }

  BoxDecoration _panelDecoration({
    double radius = 16,
    bool stronger = false,
    bool addShadow = false,
    double borderAlpha = 0.12,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = PageStyleHelper.palette(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMaterial3Style = _isMaterial3Style;
    return BoxDecoration(
      color:
          color ??
          (isMaterial3Style
              ? (stronger
                    ? scheme.surfaceContainer
                    : scheme.surfaceContainerLow)
              : (stronger ? palette.cardStrong : palette.card)),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: scheme.outline.withValues(
          alpha: isMaterial3Style ? 0.22 : borderAlpha,
        ),
        width: 0.9,
      ),
      boxShadow: addShadow
          ? [
              BoxShadow(
                color: scheme.shadow.withValues(
                  alpha: isMaterial3Style
                      ? (isDark ? 0.16 : 0.07)
                      : (isDark ? 0.24 : 0.09),
                ),
                blurRadius: isMaterial3Style ? 12 : 16,
                offset: Offset(0, isMaterial3Style ? 6 : 8),
              ),
            ]
          : null,
    );
  }

  @override
  void initState() {
    super.initState();
    _bookDeletionService = BookDeletionService(bookDao: _bookDao);
    widget.controller?._state = this;
    _loadBooks();
    _librarySubscription = LibraryEventBus().stream.listen((_) {
      if (mounted) {
        _loadBooks();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setupThemeBasedImmersiveMode();
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    final librarySubscription = _librarySubscription;
    _librarySubscription = null;
    _booksRevision++;
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    unawaited(_closeOwnedResources(librarySubscription));
    super.dispose();
  }

  Future<void> _closeOwnedResources(
    StreamSubscription<void>? librarySubscription,
  ) async {
    await librarySubscription?.cancel();
    if (_ownsSourceShelfService) _sourceShelfService.close();
  }

  void _toggleSearchBar() {
    setState(() {
      _searchBarVisible = !_searchBarVisible;
      if (_searchBarVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      } else {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  Future<void> _showFilterMenu(Rect anchor) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final selected = await showMenu<_LibraryFilter>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      initialValue: _selectedFilter,
      items: [
        _buildFilterMenuItem(
          _LibraryFilter.all,
          context.l10n.libraryFilterAll(_books.length),
        ),
        _buildFilterMenuItem(
          _LibraryFilter.reading,
          context.l10n.libraryFilterReading(
            _books.where(_isReadingBook).length,
          ),
        ),
        _buildFilterMenuItem(
          _LibraryFilter.finished,
          context.l10n.libraryFilterFinished(
            _books.where(_isFinishedBook).length,
          ),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    setState(() => _selectedFilter = selected);
    _syncFilterActive();
  }

  PopupMenuItem<_LibraryFilter> _buildFilterMenuItem(
    _LibraryFilter filter,
    String label,
  ) {
    final selected = _selectedFilter == filter;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem<_LibraryFilter>(
      value: filter,
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 18,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  void _syncFilterActive() {
    widget.controller?.filterActive.value =
        _selectedFilter != _LibraryFilter.all;
  }

  void _syncSelection() {
    widget.controller?.selection.value = LibrarySelectionSnapshot(
      isActive: _selection.isActive,
      selectedCount: _selection.selectedIds.length,
    );
  }

  void _updateState(VoidCallback mutation) => setState(mutation);

  void _enterSelectionMode(Book book) {
    final id = book.id;
    if (id == null) return;
    setState(() => _selection.enter(id));
    _syncSelection();
  }

  void _toggleBookSelection(Book book) {
    final id = book.id;
    if (id == null) return;
    setState(() => _selection.toggle(id));
    _syncSelection();
  }

  void _selectAllVisibleBooks() {
    final visibleIds = _visibleBooks.map((book) => book.id).nonNulls;
    setState(() => _selection.selectAllVisible(visibleIds));
    _syncSelection();
  }

  void _exitSelectionMode() {
    if (!_selection.isActive) return;
    setState(_selection.exit);
    _syncSelection();
  }

  bool _isBookSelected(Book book) {
    final id = book.id;
    return id != null && _selection.selectedIds.contains(id);
  }

  Future<void> _handleBookTap(
    Book book, {
    required Future<void> Function() openBook,
  }) async {
    if (_selection.isActive) {
      _toggleBookSelection(book);
      return;
    }
    await openBook();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_searchQuery == value) return;
      setState(() => _searchQuery = value);
    });
  }

  bool _shouldApplySystemUI() {
    final route = ModalRoute.of(context);
    return route?.isCurrent ?? true;
  }

  void _setupThemeBasedImmersiveMode() {
    if (!_shouldApplySystemUI()) {
      return;
    }
    final overlayStyle = SystemUiHelper.overlayStyleForBrightness(
      Theme.of(context).brightness,
    );
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);
  }

  Future<void> _loadBooks() async {
    try {
      final books =
          await (widget.booksLoader?.call() ?? _bookDao.getAllBooks());
      if (mounted) {
        setState(() {
          _books = books;
          _booksRevision++;
          _loadError = null;
          _selection.retainOnly(books.map((book) => book.id).nonNulls.toSet());
          _isInitialLoading = false;
        });
        _syncSelection();
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to load library books: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _loadError = error;
          _isInitialLoading = false;
        });
      }
    }
  }

  void _retryLoadBooks() {
    setState(() {
      _isInitialLoading = true;
      _loadError = null;
    });
    unawaited(_loadBooks());
  }

  @override
  Widget build(BuildContext context) {
    // 检查是否在侧边导航栏模式下
    final navContext = NavigationContext.of(context);
    final useRailNavigation = navContext?.useRailNavigation ?? false;
    final scheme = Theme.of(context).colorScheme;
    final appBarColor = _isMaterial3Style ? scheme.surface : Colors.transparent;

    // 在侧边导航栏模式下，不显示 Scaffold 和 AppBar
    if (useRailNavigation) {
      return Stack(
        children: [
          _buildContent(context, useRailNavigation: useRailNavigation),
          if (_selection.isActive) _buildRailSelectionBottomBar(),
        ],
      );
    }

    // 手机模式：显示完整的 Scaffold + AppBar
    return PopScope(
      canPop: !_selection.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.isActive) _exitSelectionMode();
      },
      child: Scaffold(
        extendBody: true, // 让内容延伸到导航区，配合手势小白条
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: appBarColor,
          elevation: 0,
          toolbarHeight: 0,
          surfaceTintColor: appBarColor,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiHelper.overlayStyleForBrightness(
            Theme.of(context).brightness,
          ),
        ),
        body: _buildContent(context, useRailNavigation: useRailNavigation),
        // 手机端改为顶部“+”按钮入口，宽屏继续保留FAB
        floatingActionButton:
            LayoutHelper.getNavigationType(context) == NavigationType.rail
            ? _buildFloatingActionButton()
            : null,
      ),
    );
  }
}
