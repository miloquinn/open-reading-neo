// 文件说明：发现页，聚合展示已启用书源的推荐、分类与最新书籍。
// 技术要点：Flutter UI、按 Tab 缓存的书源请求、下拉刷新。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'book_source_management_page.dart';
import 'source_search_page.dart';
import 'widgets/sourced_book_widgets.dart';

enum BookSourceDiscoverLayout { standard, list }

/// 发现页布局状态。由首页壳层持有，因此顶部按钮和页面内容始终同步。
class BookSourcesPageController {
  static const preferenceKey = 'book_source_discover_layout_v1';

  final ValueNotifier<BookSourceDiscoverLayout> layout = ValueNotifier(
    BookSourceDiscoverLayout.standard,
  );
  Future<void>? _initialization;
  int _revision = 0;
  bool _disposed = false;

  Future<void> initialize() => _initialization ??= _restore();

  Future<void> _restore() async {
    final revision = _revision;
    final preferences = await SharedPreferences.getInstance();
    if (_disposed || revision != _revision) return;
    final stored = preferences.getString(preferenceKey);
    layout.value = stored == BookSourceDiscoverLayout.list.name
        ? BookSourceDiscoverLayout.list
        : BookSourceDiscoverLayout.standard;
  }

  Future<void> toggleLayout() => setLayout(
    layout.value == BookSourceDiscoverLayout.standard
        ? BookSourceDiscoverLayout.list
        : BookSourceDiscoverLayout.standard,
  );

  Future<void> setLayout(BookSourceDiscoverLayout next) async {
    if (_disposed) return;
    _revision++;
    if (layout.value != next) layout.value = next;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(preferenceKey, next.name);
  }

  void dispose() {
    _disposed = true;
    layout.dispose();
  }
}

/// 发现页：只负责展示书籍内容。
///
/// 搜索收纳在顶栏的搜索按钮里（独立页面），书源配置收纳在管理页。
class BookSourcesPage extends StatefulWidget {
  final BookSourceClient? client;
  final BookSourcesPageController? controller;

  static const int maxLatestItemsPerSource = 12;

  const BookSourcesPage({super.key, this.client, this.controller});

  @visibleForTesting
  static List<RegisteredBookSource> searchTargets(
    Iterable<RegisteredBookSource> sources,
    String? selectedSourceId,
  ) => SourceSearchPage.searchTargets(sources, selectedSourceId);

  @visibleForTesting
  static bool listSourceMatchesQuery(
    RegisteredBookSource source,
    String query,
  ) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    final group = source.sourceConfig?['bookSourceGroup'];
    final searchable = [
      source.name,
      source.description,
      source.id,
      source.manifestUrl.toString(),
      source.apiBaseUrl.toString(),
      if (source.websiteUrl != null) source.websiteUrl.toString(),
      if (group is String) group,
    ];
    return searchable.any((value) => value.toLowerCase().contains(normalized));
  }

  /// 保留每个书源自己的 latest 顺序，再按来源轮流穿插。
  ///
  /// 首轮优先展示头部更新时间较新的书源；随后每轮每源最多贡献一本，
  /// 避免单一书源依靠时间戳或返回数量占满聚合列表。
  @visibleForTesting
  static List<SourcedBook> interleaveLatestBatches(
    Iterable<List<SourcedBook>> batches, {
    int maxItemsPerSource = maxLatestItemsPerSource,
  }) {
    if (maxItemsPerSource <= 0) return const [];
    final queues = batches
        .where((batch) => batch.isNotEmpty)
        .map((batch) => batch.take(maxItemsPerSource).toList(growable: false))
        .toList();
    queues.sort((left, right) {
      final leftTime = left.first.book.updatedAt;
      final rightTime = right.first.book.updatedAt;
      if (leftTime != null && rightTime != null) {
        final byTime = rightTime.compareTo(leftTime);
        if (byTime != 0) return byTime;
      } else if (leftTime != null) {
        return -1;
      } else if (rightTime != null) {
        return 1;
      }
      return left.first.source.name.compareTo(right.first.source.name);
    });

    final results = <SourcedBook>[];
    for (var index = 0; index < maxItemsPerSource; index++) {
      var added = false;
      for (final queue in queues) {
        if (index >= queue.length) continue;
        results.add(queue[index]);
        added = true;
      }
      if (!added) break;
    }
    return results;
  }

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  static const int _maxConcurrentSourceFetches = 8;
  static const int _largeSourceLibraryThreshold = 40;

  final BookSourceRegistry _registry = BookSourceRegistry();
  final TextEditingController _listSourceSearchController =
      TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final BookSourceClient _client;
  late final BookSourceShelfService _shelfService = BookSourceShelfService(
    client: _client,
  );
  late final SourcedBookActions _actions = SourcedBookActions(
    context: context,
    client: _client,
    shelfService: _shelfService,
  );
  StreamSubscription<void>? _registrySubscription;
  late final BookSourcesPageController _layoutController;
  late final bool _ownsLayoutController;

  List<RegisteredBookSource> _sources = const [];
  Map<_DiscoverSection, List<RegisteredBookSource>> _sectionSources = const {};
  List<RegisteredBookSource> _discoverySourcesCache = const [];
  bool _loadingSources = true;
  int _sourceLoadRevision = 0;
  int _sectionLoadRevision = 0;
  _DiscoverSection _section = _DiscoverSection.recommended;
  String? _selectedSourceId;

  // 每个 Tab 的内容独立缓存，切换回来不再重新请求。
  final Map<_DiscoverSection, _SectionCache> _cache = {};
  _SourcedCategory? _selectedCategory;
  List<SourcedBook> _categoryBooks = const [];
  bool _loadingCategoryBooks = false;
  bool _loadingMoreCategoryBooks = false;
  bool _categoryLoadMoreFailed = false;
  String? _categoryLoadError;
  bool _categoryHasMore = false;
  int _categoryPage = 1;
  String? _expandedListSourceId;
  String _listSourceQuery = '';
  bool _showListDirectory = true;
  final Map<String, List<_SourcedCategory>> _listChannelsBySource = {};
  final Set<String> _loadingListChannelSources = {};
  final Map<String, String> _listChannelErrors = {};

  @override
  void initState() {
    super.initState();
    _ownsLayoutController = widget.controller == null;
    _layoutController = widget.controller ?? BookSourcesPageController();
    _layoutController.layout.addListener(_handleLayoutChanged);
    unawaited(_layoutController.initialize());
    _client = widget.client ?? BookSourceClient();
    _registrySubscription = _registry.changes.listen((_) => _reloadAll());
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    _registrySubscription?.cancel();
    _layoutController.layout.removeListener(_handleLayoutChanged);
    if (_ownsLayoutController) _layoutController.dispose();
    _listSourceSearchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleLayoutChanged() {
    if (!mounted) return;
    final listLayout =
        _layoutController.layout.value == BookSourceDiscoverLayout.list;
    setState(() {
      if (listLayout) {
        _sectionLoadRevision++;
        _section = _DiscoverSection.categories;
        _selectedSourceId = null;
        _expandedListSourceId = null;
        _showListDirectory = true;
        _cache[_DiscoverSection.categories] = _SectionCache.categories(
          _listChannelsBySource.values
              .expand((items) => items)
              .toList(growable: false),
        );
        _resetCategorySelection();
      }
    });
    if (listLayout && !_loadingSources) {
      unawaited(_loadSection(_DiscoverSection.categories));
    } else if (!listLayout &&
        !_loadingSources &&
        _section == _DiscoverSection.categories) {
      _autoSelectFirstCategory();
    }
  }

  Future<void> _loadSources() async {
    final revision = ++_sourceLoadRevision;
    final sources = await _registry.loadRunnableInBackground();
    if (!mounted || revision != _sourceLoadRevision) return;
    final sectionSources = _buildSectionSourceIndex(sources);
    final discoveryIds = sectionSources.values
        .expand((items) => items)
        .map((source) => source.id)
        .toSet();
    final discoverySources = sources
        .where((source) => discoveryIds.contains(source.id))
        .toList(growable: false);
    setState(() {
      _sources = sources;
      _sectionSources = sectionSources;
      _discoverySourcesCache = discoverySources;
      if (_layoutController.layout.value == BookSourceDiscoverLayout.standard &&
          discoverySources.length > _largeSourceLibraryThreshold &&
          (_selectedSourceId == null ||
              !discoveryIds.contains(_selectedSourceId))) {
        // Aggregating thousands of third-party sources on page entry would
        // create a request storm. Large libraries start scoped to one source;
        // the source strip remains lazy and lets the user switch instantly.
        _selectedSourceId = discoverySources.firstOrNull?.id;
      }
      _loadingSources = false;
    });
    final availableSections = _availableSections;
    if (availableSections.isNotEmpty && !availableSections.contains(_section)) {
      setState(() => _section = availableSections.first);
    }
    await _loadSection(_section);
  }

  Future<void> _reloadAll() async {
    _sourceLoadRevision++;
    _sectionLoadRevision++;
    _cache.clear();
    _selectedSourceId = null;
    _selectedCategory = null;
    _categoryBooks = const [];
    _loadingCategoryBooks = false;
    _loadingMoreCategoryBooks = false;
    _categoryLoadMoreFailed = false;
    _categoryLoadError = null;
    _categoryHasMore = false;
    _categoryPage = 1;
    _listChannelsBySource.clear();
    _loadingListChannelSources.clear();
    _listChannelErrors.clear();
    await _loadSources();
  }

  String _capabilityFor(_DiscoverSection section) => switch (section) {
    _DiscoverSection.recommended => 'discover',
    _DiscoverSection.categories => 'categories',
    _DiscoverSection.latest => 'browse',
  };

  Map<_DiscoverSection, List<RegisteredBookSource>> _buildSectionSourceIndex(
    List<RegisteredBookSource> sources,
  ) {
    final result = <_DiscoverSection, List<RegisteredBookSource>>{};
    for (final section in _DiscoverSection.values) {
      final capability = _capabilityFor(section);
      result[section] = sources
          .where((source) => source.enabled)
          .where((source) => source.capabilities.contains(capability))
          .where(
            (source) =>
                section != _DiscoverSection.latest ||
                source.sourceProtocol == BookSourceProtocolKind.orsp,
          )
          .toList(growable: false);
    }
    return Map.unmodifiable(result);
  }

  List<RegisteredBookSource> _sourcesFor(_DiscoverSection section) =>
      _sectionSources[section] ?? const [];

  List<RegisteredBookSource> _scopedSourcesFor(_DiscoverSection section) =>
      _sourcesFor(
        section,
      ).where(_matchesSelectedSource).toList(growable: false);

  List<RegisteredBookSource> get _discoverySources => _discoverySourcesCache;

  bool get _requiresScopedDiscovery =>
      _discoverySourcesCache.length > _largeSourceLibraryThreshold;

  List<_DiscoverSection> get _availableSections => _DiscoverSection.values
      .where(
        (section) => _sourcesFor(
          section,
        ).any((source) => _matchesSelectedSource(source)),
      )
      .toList(growable: false);

  bool _matchesSelectedSource(RegisteredBookSource source) =>
      _selectedSourceId == null || source.id == _selectedSourceId;

  Future<void> _loadSection(
    _DiscoverSection section, {
    bool force = false,
    bool preserveContent = false,
  }) async {
    final revision = ++_sectionLoadRevision;
    if (!force && _cache[section] != null) return;
    final currentCache = _cache[section];
    final keepCurrentContent =
        preserveContent &&
        currentCache != null &&
        !currentCache.loading &&
        currentCache.error == null;
    if (force) {
      await _client.invalidateResponseCaches(_scopedSourcesFor(section));
      if (!mounted || revision != _sectionLoadRevision) return;
    }
    final listDirectory =
        section == _DiscoverSection.categories &&
        _layoutController.layout.value == BookSourceDiscoverLayout.list &&
        _showListDirectory;
    if (listDirectory) {
      setState(
        () => _cache[section] = _SectionCache.categories(
          _listChannelsBySource.values
              .expand((items) => items)
              .toList(growable: false),
        ),
      );
      return;
    }
    if (!keepCurrentContent) {
      setState(() {
        _cache[section] = const _SectionCache.loading();
        if (force && section == _DiscoverSection.categories) {
          _resetCategorySelection();
        }
      });
    }
    _SectionCache next;
    try {
      next = switch (section) {
        _DiscoverSection.recommended => _SectionCache.shelves(
          await _fetchShelves(),
        ),
        _DiscoverSection.categories => _SectionCache.categories(
          await _fetchCategories(),
        ),
        _DiscoverSection.latest => _SectionCache.books(await _fetchLatest()),
      };
    } catch (error) {
      next = _SectionCache.error(error.toString());
    }
    if (!mounted || revision != _sectionLoadRevision) return;
    setState(() {
      _cache[section] = next;
      if (keepCurrentContent &&
          section == _DiscoverSection.categories &&
          next.error == null) {
        _resetCategorySelection();
      }
    });
    if (section == _DiscoverSection.categories &&
        !(_layoutController.layout.value == BookSourceDiscoverLayout.list &&
            _showListDirectory)) {
      _autoSelectFirstCategory();
    }
  }

  Future<List<_DiscoveryShelf>> _fetchShelves() async {
    final batches = await _fetchSourceBatches(
      _scopedSourcesFor(_DiscoverSection.recommended),
      (source) async {
        final page = await _client.getDiscovery(source);
        return page.sections
            .where((section) => section.items.isNotEmpty)
            .map(
              (section) => _DiscoveryShelf(
                source: source,
                title: section.title,
                items: section.items,
              ),
            )
            .toList(growable: false);
      },
    );
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<_SourcedCategory>> _fetchCategories() async {
    final batches = await _fetchSourceBatches(
      _scopedSourcesFor(_DiscoverSection.categories),
      (source) async {
        final categories = await _client.getCategories(source);
        return _uniqueSourcedCategories(source, categories);
      },
    );
    return batches.expand((items) => items).toList(growable: false);
  }

  List<_SourcedCategory> _uniqueSourcedCategories(
    RegisteredBookSource source,
    Iterable<BookSourceCategory> categories,
  ) {
    final seenIds = <String>{};
    final uniqueCategories = <_SourcedCategory>[];
    for (final category in categories) {
      if (!seenIds.add(category.id)) continue;
      uniqueCategories.add(
        _SourcedCategory(source: source, id: category.id, name: category.name),
      );
    }
    return uniqueCategories;
  }

  Future<List<SourcedBook>> _fetchLatest() async {
    final batches = await _fetchSourceBatches(
      _scopedSourcesFor(_DiscoverSection.latest),
      (source) async {
        final page = await _client.browse(source, sort: 'latest');
        return page.items
            .map((book) => SourcedBook(source: source, book: book))
            .toList(growable: false);
      },
    );
    return BookSourcesPage.interleaveLatestBatches(batches);
  }

  Future<List<List<T>>> _fetchSourceBatches<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(RegisteredBookSource source) fetch,
  ) async {
    if (sources.isEmpty) return const [];
    final results = List<_SourceFetchResult<T>?>.filled(sources.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < sources.length) {
        final index = nextIndex++;
        final source = sources[index];
        try {
          results[index] = _SourceFetchResult<T>.success(
            source,
            await fetch(source),
          );
        } catch (error) {
          results[index] = _SourceFetchResult<T>.failure(source, error);
        }
      }
    }

    await Future.wait(
      List.generate(
        sources.length.clamp(1, _maxConcurrentSourceFetches),
        (_) => worker(),
      ),
    );
    final completed = results.whereType<_SourceFetchResult<T>>().toList(
      growable: false,
    );
    final batches = completed
        .where((result) => result.error == null)
        .map((result) => result.items)
        .toList(growable: false);
    final hasContent = batches.any((items) => items.isNotEmpty);
    final failures = completed.where((result) => result.error != null).toList();
    if (!hasContent && failures.isNotEmpty) {
      throw BookSourceProtocolException(
        failures
            .map((failure) => '${failure.source.name}: ${failure.error}')
            .join('\n'),
      );
    }
    return batches;
  }

  void _autoSelectFirstCategory() {
    final cache = _cache[_DiscoverSection.categories];
    final categories = (cache?.categories ?? const <_SourcedCategory>[])
        .where((category) => _matchesSelectedSource(category.source))
        .toList(growable: false);
    if (_selectedCategory != null || categories.isEmpty) return;
    unawaited(_selectCategory(categories.first));
  }

  void _resetCategorySelection() {
    _selectedCategory = null;
    _categoryBooks = const [];
    _loadingCategoryBooks = false;
    _loadingMoreCategoryBooks = false;
    _categoryLoadMoreFailed = false;
    _categoryLoadError = null;
    _categoryHasMore = false;
    _categoryPage = 1;
  }

  Future<void> _changeSourceScope(String? sourceId) async {
    if (_selectedSourceId == sourceId) return;
    setState(() {
      _selectedSourceId = sourceId;
      _cache.clear();
      _resetCategorySelection();
      final availableSections = _availableSections;
      if (availableSections.isNotEmpty &&
          !availableSections.contains(_section)) {
        _section = availableSections.first;
      }
    });
    await _loadSection(_section);
    if (_section == _DiscoverSection.categories) {
      _autoSelectFirstCategory();
    }
  }

  Future<void> _changeSection(_DiscoverSection section) async {
    setState(() {
      _section = section;
      _resetCategorySelection();
    });
    await _loadSection(section);
    if (mounted && section == _DiscoverSection.categories) {
      _autoSelectFirstCategory();
    }
  }

  Future<void> _selectCategory(_SourcedCategory category) async {
    setState(() {
      _selectedCategory = category;
      _categoryBooks = const [];
      _loadingCategoryBooks = category.source.capabilities.contains('browse');
      _loadingMoreCategoryBooks = false;
      _categoryLoadMoreFailed = false;
      _categoryLoadError = null;
      _categoryHasMore = false;
      _categoryPage = 1;
    });
    if (!category.source.capabilities.contains('browse')) return;
    try {
      final page = await _client.browse(
        category.source,
        category: category.id,
        sort: 'popular',
      );
      if (!mounted || _selectedCategory != category) return;
      setState(() {
        _categoryBooks = page.items
            .map((book) => SourcedBook(source: category.source, book: book))
            .toList(growable: false);
        _loadingCategoryBooks = false;
        _categoryPage = page.page;
        _categoryHasMore = page.hasMore && page.items.isNotEmpty;
      });
    } catch (error) {
      if (!mounted || _selectedCategory != category) return;
      setState(() {
        _loadingCategoryBooks = false;
        _categoryLoadError = _categoryErrorMessage(error);
      });
    }
  }

  String _categoryErrorMessage(Object error) {
    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^[^:]+Exception:\s*'), '')
        .trim();
    if (raw.contains('Could not connect to the reading source')) {
      return context.l10n.bookSourceConnectionFailed;
    }
    if (raw.contains('redirected too many times') ||
        raw.contains('entered a redirect loop')) {
      return context.l10n.bookSourceRedirectFailed;
    }
    final status = RegExp(r'HTTP (\d{3})').firstMatch(raw)?.group(1);
    if (status != null) {
      return context.l10n.bookSourceHttpFailed(int.parse(status));
    }
    return raw.replaceAll(
      RegExp('reading source', caseSensitive: false),
      context.l10n.bookSources,
    );
  }

  Future<void> _loadMoreCategory() async {
    final category = _selectedCategory;
    if (category == null ||
        _loadingCategoryBooks ||
        _loadingMoreCategoryBooks ||
        !_categoryHasMore) {
      return;
    }
    setState(() {
      _loadingMoreCategoryBooks = true;
      _categoryLoadMoreFailed = false;
    });
    try {
      final page = await _client.browse(
        category.source,
        category: category.id,
        sort: 'popular',
        page: _categoryPage + 1,
      );
      if (!mounted || _selectedCategory != category) return;
      final seen = _categoryBooks
          .map((item) => '${item.source.id}\u0000${item.book.id}')
          .toSet();
      final appended = page.items
          .map((book) => SourcedBook(source: category.source, book: book))
          .where((item) => seen.add('${item.source.id}\u0000${item.book.id}'))
          .toList(growable: false);
      setState(() {
        _categoryBooks = [..._categoryBooks, ...appended];
        _categoryPage = page.page;
        _categoryHasMore =
            page.hasMore && page.items.isNotEmpty && appended.isNotEmpty;
        _loadingMoreCategoryBooks = false;
      });
    } catch (_) {
      if (!mounted || _selectedCategory != category) return;
      setState(() {
        _loadingMoreCategoryBooks = false;
        _categoryLoadMoreFailed = true;
      });
    }
  }

  Future<void> _openCategoryPicker(List<_SourcedCategory> categories) async {
    final size = MediaQuery.sizeOf(context);
    final picker = _CategoryPickerPanel(
      categories: categories,
      selectedCategory: _selectedCategory,
      title: context.l10n.discoverCategories,
      searchLabel: context.l10n.search,
      noResultsLabel: context.l10n.bookSourcesNoResults,
    );
    final _SourcedCategory? selected;
    if (size.width >= 720) {
      selected = await showDialog<_SourcedCategory>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: (size.width - 48).clamp(320, 520).toDouble(),
            height: (size.height - 48).clamp(320, 680).toDouble(),
            child: picker,
          ),
        ),
      );
    } else {
      selected = await showModalBottomSheet<_SourcedCategory>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        clipBehavior: Clip.antiAlias,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: picker,
          ),
        ),
      );
    }
    if (selected != null && mounted && selected != _selectedCategory) {
      await _selectCategory(selected);
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSearchPage(
          sources: _sources,
          client: _client,
          shelfService: _shelfService,
        ),
      ),
    );
  }

  Future<void> _refreshCurrentLayout() async {
    if (_layoutController.layout.value == BookSourceDiscoverLayout.list) {
      setState(() {
        _section = _DiscoverSection.categories;
        _selectedSourceId = null;
        _expandedListSourceId = null;
        _showListDirectory = true;
        _listChannelsBySource.clear();
        _loadingListChannelSources.clear();
        _listChannelErrors.clear();
        _resetCategorySelection();
      });
      await _loadSection(_DiscoverSection.categories, force: true);
      return;
    }
    await _loadSection(_section, force: true, preserveContent: true);
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BookSourceManagementPage()),
    );
    if (mounted) await _reloadAll();
  }

  @override
  Widget build(BuildContext context) {
    final useRailNavigation =
        NavigationContext.of(context)?.useRailNavigation ?? false;
    final mobileChrome = HomeMobileChromeScope.of(context);
    final bottomPadding = useRailNavigation
        ? 32.0
        : mobileChrome.pageBottomPadding;
    final listLayout =
        _layoutController.layout.value == BookSourceDiscoverLayout.list;
    final discoverySources = _discoverySources;
    final availableSections = _availableSections;
    final scrollView = CustomScrollView(
      key: const Key('bookSourceDiscoverScrollView'),
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  useRailNavigation ? 16 : mobileChrome.pageTopPadding,
                  16,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (useRailNavigation) _buildRailHeader(),
                    if (!listLayout && discoverySources.isNotEmpty)
                      _buildSourceScope(discoverySources),
                    if (!listLayout &&
                        discoverySources.isNotEmpty &&
                        availableSections.length > 1)
                      const SizedBox(height: 8),
                    if (!listLayout && availableSections.length > 1)
                      _buildSectionTabs(availableSections),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
        ..._buildSectionSlivers(bottomPadding),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: SafeArea(
        top: useRailNavigation,
        bottom: false,
        child: RefreshIndicator(
          edgeOffset: useRailNavigation ? 90 : mobileChrome.topBarHeight,
          onRefresh: _refreshCurrentLayout,
          child: listLayout
              ? Scrollbar(
                  key: const Key('bookSourceDiscoverListScrollbar'),
                  controller: _scrollController,
                  thumbVisibility: true,
                  interactive: true,
                  child: scrollView,
                )
              : scrollView,
        ),
      ),
    );
  }

  Widget _buildRailHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.l10n.discover,
              style: TextStyle(
                fontSize: 36,
                height: 1.05,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          ValueListenableBuilder<BookSourceDiscoverLayout>(
            valueListenable: _layoutController.layout,
            builder: (context, layout, _) => IconButton.filledTonal(
              key: const Key('bookSourceDiscoverLayoutToggle'),
              tooltip: layout == BookSourceDiscoverLayout.standard
                  ? context.l10n.bookSourceListLayout
                  : context.l10n.bookSourceStandardLayout,
              onPressed: () => unawaited(_layoutController.toggleLayout()),
              icon: Icon(
                layout == BookSourceDiscoverLayout.standard
                    ? Icons.view_list_rounded
                    : Icons.dashboard_outlined,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            key: const Key('bookSourceSearchEntry'),
            tooltip: context.l10n.bookSourcesSearch,
            onPressed: _openSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: context.l10n.bookSourceManagementTitle,
            onPressed: _openSourceManagement,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTabs(List<_DiscoverSection> sections) {
    final scheme = Theme.of(context).colorScheme;
    return SegmentedButton<_DiscoverSection>(
      showSelectedIcon: false,
      segments: sections.map(_sectionSegment).toList(growable: false),
      selected: {_section},
      onSelectionChanged: (selection) {
        if (selection.isEmpty) return;
        unawaited(_changeSection(selection.first));
      },
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 48)),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      ),
    );
  }

  ButtonSegment<_DiscoverSection> _sectionSegment(_DiscoverSection section) =>
      switch (section) {
        _DiscoverSection.recommended => ButtonSegment(
          value: section,
          icon: const Icon(Icons.auto_awesome_outlined),
          label: Text(context.l10n.discoverRecommended),
        ),
        _DiscoverSection.categories => ButtonSegment(
          value: section,
          icon: const Icon(Icons.category_outlined),
          label: Text(context.l10n.discoverCategories),
        ),
        _DiscoverSection.latest => ButtonSegment(
          value: section,
          icon: const Icon(Icons.update_rounded),
          label: Text(context.l10n.discoverLatest),
        ),
      };

  Widget _buildSourceScope(List<RegisteredBookSource> sources) {
    final includeAll = !_requiresScopedDiscovery;
    final itemCount = sources.length + (includeAll ? 1 : 0);
    return SizedBox(
      key: const Key('bookSourceDiscoverScopeControl'),
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (includeAll && index == 0) {
            return ChoiceChip(
              key: const Key('bookSourceDiscoverScopeAll'),
              selected: _selectedSourceId == null,
              label: Text(context.l10n.statsRangeAll),
              onSelected: (_) => unawaited(_changeSourceScope(null)),
            );
          }
          final source = sources[index - (includeAll ? 1 : 0)];
          return ChoiceChip(
            key: Key('bookSourceDiscoverScope-${source.id}'),
            selected: _selectedSourceId == source.id,
            label: Text(source.name),
            onSelected: (_) => unawaited(_changeSourceScope(source.id)),
          );
        },
      ),
    );
  }

  List<Widget> _buildSectionSlivers(double bottomPadding) {
    if (_loadingSources) {
      return [
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(
              child: CircularProgressIndicator(
                key: Key('bookSourceDiscoverSectionLoadingIndicator'),
              ),
            ),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    final cache = _cache[_section];
    if (cache == null || cache.loading) {
      return [
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(
              child: CircularProgressIndicator(
                key: Key('bookSourceDiscoverSectionLoadingIndicator'),
              ),
            ),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    if (cache.error != null) {
      return [
        _paddedSectionSliver(
          _buildMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.discoverLoadFailed,
            message: cache.error!,
            actionLabel: context.l10n.discoverRetry,
            onAction: () => _loadSection(_section, force: true),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    if (_layoutController.layout.value == BookSourceDiscoverLayout.list) {
      return _buildListLayoutSlivers(cache, bottomPadding);
    }
    return switch (_section) {
      _DiscoverSection.recommended => _buildShelvesSlivers(
        cache,
        bottomPadding,
      ),
      _DiscoverSection.categories => _buildCategoriesSlivers(
        cache,
        bottomPadding,
      ),
      _DiscoverSection.latest => _buildLatestSlivers(cache, bottomPadding),
    };
  }

  List<Widget> _buildShelvesSlivers(_SectionCache cache, double bottomPadding) {
    final shelves = (cache.shelves ?? const <_DiscoveryShelf>[])
        .where((shelf) => _matchesSelectedSource(shelf.source))
        .toList(growable: false);
    if (shelves.isEmpty) {
      return [
        _paddedSectionSliver(
          _sourcesFor(_DiscoverSection.recommended).isEmpty
              ? _buildUnsupportedMessage('discover')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
        sliver: SliverList.builder(
          itemCount: shelves.length,
          itemBuilder: (context, index) =>
              _centerSectionChild(_buildShelf(shelves[index])),
        ),
      ),
    ];
  }

  Widget _buildShelf(_DiscoveryShelf shelf) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shelf.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              _buildSourceBadge(shelf.source.name),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 242,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: shelf.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final result = SourcedBook(
                  source: shelf.source,
                  book: shelf.items[index],
                );
                return SourcedBookCard(
                  result: result,
                  onTap: () => _actions.showBookDetails(result),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCategoriesSlivers(
    _SectionCache cache,
    double bottomPadding, {
    bool showChannelStrip = true,
  }) {
    final categories = (cache.categories ?? const <_SourcedCategory>[])
        .where((category) => _matchesSelectedSource(category.source))
        .toList(growable: false);
    if (categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _sourcesFor(_DiscoverSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    final selectedCategory = _selectedCategory ?? categories.first;
    final slivers = <Widget>[];
    if (showChannelStrip) {
      slivers.add(
        _paddedSectionSliver(
          _buildCategoryChannels(categories, selectedCategory),
          bottomPadding: 18,
        ),
      );
    }
    if (_loadingCategoryBooks) {
      slivers.add(
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: CircularProgressIndicator()),
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else if (_categoryLoadError != null) {
      slivers.add(
        _paddedSectionSliver(
          _buildMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.bookSourceChannelLoadFailed,
            message: context.l10n.bookSourceChannelLoadFailedMessage(
              _categoryLoadError!,
            ),
            actionLabel: context.l10n.retry,
            onAction: () => _selectCategory(selectedCategory),
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else if (_categoryBooks.isEmpty) {
      slivers.add(
        _paddedSectionSliver(
          _buildMessageCard(
            icon: Icons.menu_book_outlined,
            title: context.l10n.bookSourcesNoResults,
            message: context.l10n.discoverCategoryEmpty,
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else {
      slivers.add(
        _bookListSliver(
          _categoryBooks,
          bottomPadding:
              _categoryHasMore ||
                  _loadingMoreCategoryBooks ||
                  _categoryLoadMoreFailed
              ? 12
              : bottomPadding,
        ),
      );
      if (_categoryHasMore ||
          _loadingMoreCategoryBooks ||
          _categoryLoadMoreFailed) {
        slivers.add(
          _paddedSectionSliver(
            Center(
              child: _loadingMoreCategoryBooks
                  ? const CircularProgressIndicator()
                  : OutlinedButton.icon(
                      key: const Key('bookSourceCategoryLoadMore'),
                      onPressed: _loadMoreCategory,
                      icon: Icon(
                        _categoryLoadMoreFailed
                            ? Icons.refresh_rounded
                            : Icons.expand_more_rounded,
                      ),
                      label: Text(
                        _categoryLoadMoreFailed
                            ? context.l10n.retry
                            : context.l10n.bookSourcesLoadMore,
                      ),
                    ),
            ),
            topPadding: 0,
            bottomPadding: bottomPadding,
          ),
        );
      }
    }
    return slivers;
  }

  List<Widget> _buildListLayoutSlivers(
    _SectionCache cache,
    double bottomPadding,
  ) {
    final categories = _listChannelsBySource.values
        .expand((items) => items)
        .toList(growable: false);
    if (!_showListDirectory && categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _sourcesFor(_DiscoverSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }

    if (_showListDirectory || _selectedCategory == null) {
      final groups = _sourcesFor(_DiscoverSection.categories)
          .map(
            (source) => _ListSourceChannels(
              source: source,
              channels:
                  _listChannelsBySource[source.id] ??
                  const <_SourcedCategory>[],
            ),
          )
          .toList(growable: false);
      final filteredGroups = groups
          .where(
            (group) => BookSourcesPage.listSourceMatchesQuery(
              group.source,
              _listSourceQuery,
            ),
          )
          .toList(growable: false);
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          sliver: SliverToBoxAdapter(
            child: _centerSectionChild(
              _buildListSourceSearch(groups, filteredGroups),
            ),
          ),
        ),
        if (filteredGroups.isEmpty)
          _paddedSectionSliver(
            _buildListSourceSearchEmpty(),
            bottomPadding: bottomPadding,
            topPadding: 0,
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
            sliver: SliverList.separated(
              key: const Key('bookSourceListLayoutDirectory'),
              itemCount: filteredGroups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _centerSectionChild(
                _buildListSourceEntry(filteredGroups[index]),
              ),
            ),
          ),
      ];
    }

    return [
      _paddedSectionSliver(
        _buildListSelectionHeader(_selectedCategory!),
        bottomPadding: 12,
      ),
      ..._buildCategoriesSlivers(cache, bottomPadding, showChannelStrip: false),
    ];
  }

  Widget _buildListSourceSearch(
    List<_ListSourceChannels> groups,
    List<_ListSourceChannels> filteredGroups,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      key: const Key('bookSourceListSourceSearch'),
      controller: _listSourceSearchController,
      textInputAction: TextInputAction.search,
      onChanged: (value) => setState(() => _listSourceQuery = value),
      onSubmitted: (_) {
        if (filteredGroups.isEmpty) return;
        unawaited(_expandListSource(filteredGroups.first));
      },
      decoration: InputDecoration(
        hintText: context.l10n.bookSourcesManagementSearchHint,
        prefixIcon: const Icon(Icons.manage_search_rounded),
        suffixIconConstraints: const BoxConstraints(minHeight: 48),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${filteredGroups.length}/${groups.length}',
              key: const Key('bookSourceListSearchCount'),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_listSourceQuery.isNotEmpty)
              IconButton(
                key: const Key('bookSourceListSourceSearchClear'),
                tooltip: context.l10n.bookSourcesClearSearch,
                onPressed: _clearListSourceSearch,
                icon: const Icon(Icons.close_rounded, size: 20),
              )
            else
              const SizedBox(width: 16),
          ],
        ),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildListSourceSearchEmpty() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('bookSourceListSourceSearchEmpty'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: bookSourcePanelDecoration(context, radius: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 34, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            context.l10n.bookSourcesNoMatchingSources,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _clearListSourceSearch,
            child: Text(context.l10n.bookSourcesResetFilters),
          ),
        ],
      ),
    );
  }

  void _clearListSourceSearch() {
    _listSourceSearchController.clear();
    setState(() => _listSourceQuery = '');
  }

  Future<void> _toggleListSource(_ListSourceChannels group) async {
    if (_expandedListSourceId == group.source.id) {
      setState(() => _expandedListSourceId = null);
      return;
    }
    await _expandListSource(group);
  }

  Future<void> _expandListSource(_ListSourceChannels group) async {
    setState(() => _expandedListSourceId = group.source.id);
    if (_listChannelsBySource.containsKey(group.source.id) ||
        _loadingListChannelSources.contains(group.source.id)) {
      return;
    }
    final revision = _sourceLoadRevision;
    setState(() {
      _loadingListChannelSources.add(group.source.id);
      _listChannelErrors.remove(group.source.id);
    });
    try {
      final channels = await _client.getCategories(group.source);
      if (!mounted || revision != _sourceLoadRevision) return;
      setState(() {
        _listChannelsBySource[group.source.id] = _uniqueSourcedCategories(
          group.source,
          channels,
        );
        _loadingListChannelSources.remove(group.source.id);
        _listChannelErrors.remove(group.source.id);
        _cache[_DiscoverSection.categories] = _SectionCache.categories(
          _listChannelsBySource.values
              .expand((items) => items)
              .toList(growable: false),
        );
      });
    } catch (error) {
      if (!mounted || revision != _sourceLoadRevision) return;
      setState(() {
        _loadingListChannelSources.remove(group.source.id);
        _listChannelErrors[group.source.id] = _categoryErrorMessage(error);
      });
    }
  }

  Widget _buildListSourceEntry(_ListSourceChannels group) {
    final expanded = _expandedListSourceId == group.source.id;
    final loading = _loadingListChannelSources.contains(group.source.id);
    final error = _listChannelErrors[group.source.id];
    final loaded = _listChannelsBySource.containsKey(group.source.id);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Container(
        key: Key('bookSourceListSource-${group.source.id}'),
        decoration: bookSourcePanelDecoration(context, radius: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => unawaited(_toggleListSource(group)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 15,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.rss_feed_rounded, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              group.source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              loaded
                                  ? context.l10n.bookSourceChannelCount(
                                      group.channels.length,
                                    )
                                  : group.source.apiBaseUrl.host,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              else if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () => unawaited(_expandListSource(group)),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(context.l10n.retry),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final channel in group.channels)
                        ActionChip(
                          key: Key(
                            'bookSourceListChannel-${channel.source.id}-${channel.id}',
                          ),
                          label: Text(channel.name),
                          onPressed: () =>
                              unawaited(_selectListCategory(channel)),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _selectListCategory(_SourcedCategory category) async {
    setState(() {
      _selectedSourceId = category.source.id;
      _showListDirectory = false;
    });
    await _selectCategory(category);
  }

  Widget _buildListSelectionHeader(_SourcedCategory category) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('bookSourceListSelectionHeader'),
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: bookSourcePanelDecoration(
        context,
        radius: 18,
        stronger: true,
      ),
      child: Row(
        children: [
          Icon(Icons.rss_feed_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const Key('bookSourceListChangeChannel'),
            onPressed: _returnToListDirectory,
            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
            label: Text(context.l10n.bookSourceChangeChannel),
          ),
        ],
      ),
    );
  }

  void _returnToListDirectory() {
    final sourceId = _selectedCategory?.source.id;
    setState(() {
      _expandedListSourceId = sourceId;
      _selectedSourceId = null;
      _showListDirectory = true;
      _resetCategorySelection();
    });
  }

  Widget _buildCategoryChannels(
    List<_SourcedCategory> categories,
    _SourcedCategory selectedCategory,
  ) {
    final orderedCategories = [
      selectedCategory,
      ...categories.where((category) => category != selectedCategory),
    ];
    return SizedBox(
      key: const Key('bookSourceDiscoveryChannels'),
      height: 42,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: orderedCategories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = orderedCategories[index];
                return ChoiceChip(
                  key: Key(
                    'bookSourceDiscoveryChannel-${category.source.id}-${category.id}',
                  ),
                  selected: category == selectedCategory,
                  label: Text(category.name),
                  onSelected: (_) => unawaited(_selectCategory(category)),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          ActionChip(
            key: const Key('bookSourceCategoryPickerButton'),
            avatar: const Icon(Icons.tune_rounded, size: 18),
            label: Text(context.l10n.discoverCategories),
            onPressed: () => _openCategoryPicker(categories),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildLatestSlivers(_SectionCache cache, double bottomPadding) {
    final books = (cache.books ?? const <SourcedBook>[])
        .where((result) => _matchesSelectedSource(result.source))
        .toList(growable: false);
    if (books.isEmpty) {
      return [
        _paddedSectionSliver(
          _sourcesFor(_DiscoverSection.latest).isEmpty
              ? _buildUnsupportedMessage('browse')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    return [_bookListSliver(books, bottomPadding: bottomPadding)];
  }

  Widget _bookListSliver(
    List<SourcedBook> books, {
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
      sliver: SliverList.separated(
        itemCount: books.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final result = books[index];
          return _centerSectionChild(
            SourcedBookListTile(
              result: result,
              onTap: () => _actions.showBookDetails(result),
            ),
          );
        },
      ),
    );
  }

  Widget _paddedSectionSliver(
    Widget child, {
    double topPadding = 8,
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      sliver: SliverToBoxAdapter(child: _centerSectionChild(child)),
    );
  }

  Widget _centerSectionChild(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1048),
      child: child,
    ),
  );

  Widget _buildUnsupportedMessage(String capability) {
    final hasEnabledSources = _sources.any((source) => source.enabled);
    return _buildMessageCard(
      icon: hasEnabledSources
          ? Icons.extension_off_outlined
          : Icons.travel_explore_outlined,
      title: hasEnabledSources
          ? context.l10n.discoverUnsupportedTitle
          : context.l10n.bookSourcesNoSourcesTitle,
      message: hasEnabledSources
          ? context.l10n.discoverUnsupportedMessage(capability)
          : context.l10n.bookSourcesNoSourcesDescription,
      actionLabel: context.l10n.bookSourceManagementTitle,
      onAction: _openSourceManagement,
    );
  }

  Widget _buildEmptyMessage() {
    return _buildMessageCard(
      icon: Icons.inbox_outlined,
      title: context.l10n.discoverEmptyTitle,
      message: context.l10n.discoverEmptyMessage,
    );
  }

  Widget _buildMessageCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    FutureOr<void> Function()? onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: bookSourcePanelDecoration(context, radius: 22),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => onAction(),
              icon: const Icon(Icons.tune_rounded),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceBadge(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

enum _DiscoverSection { recommended, categories, latest }

/// 一个 Tab 的缓存态：loading / error / 三种内容之一。
class _SectionCache {
  final bool loading;
  final String? error;
  final List<_DiscoveryShelf>? shelves;
  final List<_SourcedCategory>? categories;
  final List<SourcedBook>? books;

  const _SectionCache.loading()
    : loading = true,
      error = null,
      shelves = null,
      categories = null,
      books = null;

  const _SectionCache.error(String this.error)
    : loading = false,
      shelves = null,
      categories = null,
      books = null;

  const _SectionCache.shelves(List<_DiscoveryShelf> this.shelves)
    : loading = false,
      error = null,
      categories = null,
      books = null;

  const _SectionCache.categories(List<_SourcedCategory> this.categories)
    : loading = false,
      error = null,
      shelves = null,
      books = null;

  const _SectionCache.books(List<SourcedBook> this.books)
    : loading = false,
      error = null,
      shelves = null,
      categories = null;
}

class _SourceFetchResult<T> {
  final List<T> items;
  final RegisteredBookSource source;
  final Object? error;

  const _SourceFetchResult.success(this.source, this.items) : error = null;

  const _SourceFetchResult.failure(this.source, this.error) : items = const [];
}

class _DiscoveryShelf {
  final RegisteredBookSource source;
  final String title;
  final List<BookSourceBook> items;

  const _DiscoveryShelf({
    required this.source,
    required this.title,
    required this.items,
  });
}

class _SourcedCategory {
  final RegisteredBookSource source;
  final String id;
  final String name;

  const _SourcedCategory({
    required this.source,
    required this.id,
    required this.name,
  });

  @override
  bool operator ==(Object other) =>
      other is _SourcedCategory &&
      other.source.id == source.id &&
      other.id == id;

  @override
  int get hashCode => Object.hash(source.id, id);
}

class _ListSourceChannels {
  final RegisteredBookSource source;
  final List<_SourcedCategory> channels;

  const _ListSourceChannels({required this.source, required this.channels});
}

class _CategoryPickerPanel extends StatefulWidget {
  final List<_SourcedCategory> categories;
  final _SourcedCategory? selectedCategory;
  final String title;
  final String searchLabel;
  final String noResultsLabel;

  const _CategoryPickerPanel({
    required this.categories,
    required this.selectedCategory,
    required this.title,
    required this.searchLabel,
    required this.noResultsLabel,
  });

  @override
  State<_CategoryPickerPanel> createState() => _CategoryPickerPanelState();
}

class _CategoryPickerPanelState extends State<_CategoryPickerPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_CategoryPickerEntry> _entries() {
    final query = _query.trim().toLowerCase();
    final matches = widget.categories.where((category) {
      if (query.isEmpty) return true;
      return category.name.toLowerCase().contains(query) ||
          category.source.name.toLowerCase().contains(query);
    });
    final entries = <_CategoryPickerEntry>[];
    String? sourceId;
    for (final category in matches) {
      if (category.source.id != sourceId) {
        sourceId = category.source.id;
        entries.add(_CategoryPickerEntry.header(category.source.name));
      }
      entries.add(_CategoryPickerEntry.category(category));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              key: const Key('bookSourceCategorySearchField'),
              controller: _searchController,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: widget.searchLabel,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      widget.noResultsLabel,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    key: const Key('bookSourceCategoryLazyList'),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final category = entry.category;
                      if (category == null) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                          child: Text(
                            entry.header!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        );
                      }
                      final selected = category == widget.selectedCategory;
                      return ListTile(
                        key: Key(
                          'bookSourceCategory-${category.source.id}-${category.id}',
                        ),
                        selected: selected,
                        title: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected
                            ? Icon(Icons.check_rounded, color: scheme.primary)
                            : null,
                        onTap: () => Navigator.of(context).pop(category),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CategoryPickerEntry {
  final String? header;
  final _SourcedCategory? category;

  const _CategoryPickerEntry.header(this.header) : category = null;

  const _CategoryPickerEntry.category(this.category) : header = null;
}
