// 文件说明：发现页，聚合展示已启用书源的推荐、分类与最新书籍。
// 技术要点：Flutter UI、按 Tab 缓存的书源请求、下拉刷新。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';

import 'book_source_management_page.dart';
import 'controllers/book_sources_controller.dart';
import 'source_search_page.dart';
import 'source_login_page.dart';
import 'widgets/book_source_category_picker.dart';
import 'widgets/book_source_discovery_sections.dart';
import 'widgets/book_source_list_directory.dart';
import 'widgets/book_source_list_reveal.dart';
import 'models/sourced_book.dart';
import 'widgets/sourced_book_actions.dart';
import 'widgets/sourced_book_cards.dart';

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
  final BookSourceShelfService? shelfService;
  final BookSourcesPageController? controller;
  final BookSourceClient Function()? clientFactory;
  final BookSourceShelfService Function(BookSourceClient client)?
  shelfServiceFactory;

  static const int maxLatestItemsPerSource = 12;

  const BookSourcesPage({
    super.key,
    this.client,
    this.shelfService,
    this.controller,
    this.clientFactory,
    this.shelfServiceFactory,
  }) : assert(client == null || clientFactory == null),
       assert(shelfService == null || shelfServiceFactory == null);

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
  }) => mergeLatestSourceBatches(batches, maxItemsPerSource: maxItemsPerSource);

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  final TextEditingController _listSourceSearchController =
      TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final BookSourceClient _client;
  late final BookSourceShelfService _shelfService;
  late final bool _ownsClient;
  late final bool _ownsShelfService;
  late final SourcedBookActions _actions = SourcedBookActions(
    context: context,
    client: _client,
    shelfService: _shelfService,
  );
  late final BookSourcesPageController _layoutController;
  late final bool _ownsLayoutController;
  late final BookSourcesController _controller;
  final Set<String> _revealedListSourceIds = <String>{};
  final Set<String> _revealedBookIds = <String>{};
  String? _bookRevealScope;
  double? _listDirectoryScrollOffset;

  // Remapping every discoverable source into BookSourceListChannels (and
  // then filtering by search query) is O(source count) — cheap once, but
  // this page rebuilds on every controller notification (expanding one row,
  // one source's channels finishing a fetch, a keystroke), and a library can
  // run into the thousands of sources. Recomputing on every rebuild instead
  // of only when the underlying data or query actually changed is what made
  // list view feel like it never finished loading.
  int? _cachedListGroupsRevision;
  List<BookSourceListChannels>? _cachedListGroups;
  int? _cachedFilteredGroupsRevision;
  String? _cachedFilteredGroupsQuery;
  List<BookSourceListChannels>? _cachedFilteredGroups;

  List<BookSourceListChannels> _memoizedListGroups() {
    if (_cachedListGroupsRevision == _state.listGroupsRevision) {
      return _cachedListGroups!;
    }
    final groups = _state.listSourceGroups;
    _cachedListGroupsRevision = _state.listGroupsRevision;
    _cachedListGroups = groups;
    return groups;
  }

  List<BookSourceListChannels> _memoizedFilteredListGroups(
    List<BookSourceListChannels> groups,
  ) {
    final query = _state.listSourceQuery;
    if (_cachedFilteredGroupsRevision == _state.listGroupsRevision &&
        _cachedFilteredGroupsQuery == query) {
      return _cachedFilteredGroups!;
    }
    final filtered = groups
        .where(
          (group) =>
              BookSourcesPage.listSourceMatchesQuery(group.source, query),
        )
        .toList(growable: false);
    _cachedFilteredGroupsRevision = _state.listGroupsRevision;
    _cachedFilteredGroupsQuery = query;
    _cachedFilteredGroups = filtered;
    return filtered;
  }

  BookSourcesState get _state => _controller.state;

  @override
  void initState() {
    super.initState();
    _ownsLayoutController = widget.controller == null;
    _layoutController = widget.controller ?? BookSourcesPageController();
    _layoutController.layout.addListener(_handleLayoutChanged);
    unawaited(_layoutController.initialize());
    _ownsClient = widget.client == null;
    _client = widget.client ?? (widget.clientFactory ?? BookSourceClient.new)();
    _ownsShelfService = widget.shelfService == null;
    _shelfService =
        widget.shelfService ??
        (widget.shelfServiceFactory ??
            (client) => BookSourceShelfService(client: client))(_client);
    _controller = BookSourcesController(gateway: _client)
      ..addListener(_handleControllerChanged);
    _controller.setListLayout(
      _layoutController.layout.value == BookSourceDiscoverLayout.list,
    );
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _layoutController.layout.removeListener(_handleLayoutChanged);
    if (_ownsLayoutController) _layoutController.dispose();
    _listSourceSearchController.dispose();
    _scrollController.dispose();
    unawaited(_closeOwnedResources());
    super.dispose();
  }

  Future<void> _closeOwnedResources() async {
    await _controller.close();
    _controller.dispose();
    if (_ownsShelfService) _shelfService.close();
    if (_ownsClient) _client.close();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleLayoutChanged() {
    if (!mounted) return;
    _controller.setListLayout(
      _layoutController.layout.value == BookSourceDiscoverLayout.list,
    );
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

  Future<void> _openCategoryPicker(List<SourcedBookCategory> categories) async {
    final size = MediaQuery.sizeOf(context);
    final picker = BookSourceCategoryPicker(
      categories: categories,
      selectedCategory: _state.selectedCategory,
      title: context.l10n.discoverCategories,
      searchLabel: context.l10n.search,
      noResultsLabel: context.l10n.bookSourcesNoResults,
    );
    final SourcedBookCategory? selected;
    if (size.width >= 720) {
      selected = await showDialog<SourcedBookCategory>(
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
      selected = await showModalBottomSheet<SourcedBookCategory>(
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
    if (selected != null && mounted && selected != _state.selectedCategory) {
      await _controller.selectCategory(selected);
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSearchPage(
          sources: _state.sources,
          client: _client,
          shelfService: _shelfService,
        ),
      ),
    );
  }

  Future<void> _openSourceLogin(RegisteredBookSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceLoginPage(source: source, client: _client),
      ),
    );
  }

  Future<void> _refreshCurrentLayout() async {
    await _controller.refresh();
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BookSourceManagementPage()),
    );
    if (mounted) await _controller.reload();
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
    final discoverySources = _state.discoverySources;
    final availableSections = _state.availableSections;
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
                    if (useRailNavigation)
                      ValueListenableBuilder<BookSourceDiscoverLayout>(
                        valueListenable: _layoutController.layout,
                        builder: (context, layout, _) => BookSourceRailHeader(
                          title: context.l10n.discover,
                          standardLayout:
                              layout == BookSourceDiscoverLayout.standard,
                          layoutTooltip:
                              layout == BookSourceDiscoverLayout.standard
                              ? context.l10n.bookSourceListLayout
                              : context.l10n.bookSourceStandardLayout,
                          searchTooltip: context.l10n.bookSourcesSearch,
                          managementTooltip:
                              context.l10n.bookSourceManagementTitle,
                          onToggleLayout: () =>
                              unawaited(_layoutController.toggleLayout()),
                          onSearch: _openSearch,
                          onManage: () => unawaited(_openSourceManagement()),
                        ),
                      ),
                    if (!listLayout)
                      BookSourceDiscoveryControls(
                        sources: discoverySources,
                        includeAllSources: !_state.requiresScopedDiscovery,
                        selectedSourceId: _state.selectedSourceId,
                        sections: availableSections,
                        selectedSection: _state.section,
                        allLabel: context.l10n.statsRangeAll,
                        recommendedLabel: context.l10n.discoverRecommended,
                        categoriesLabel: context.l10n.discoverCategories,
                        latestLabel: context.l10n.discoverLatest,
                        onSourceSelected: (sourceId) =>
                            unawaited(_controller.changeSourceScope(sourceId)),
                        onSectionSelected: (section) =>
                            unawaited(_controller.changeSection(section)),
                      ),
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
              ? RawScrollbar(
                  key: const Key('bookSourceDiscoverListScrollbar'),
                  controller: _scrollController,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 4,
                  radius: const Radius.circular(99),
                  minThumbLength: 44,
                  crossAxisMargin: 2,
                  padding: EdgeInsets.only(
                    top: useRailNavigation ? 0 : mobileChrome.topBarHeight,
                    bottom: useRailNavigation
                        ? 0
                        : mobileChrome.navContainerHeight,
                  ),
                  child: scrollView,
                )
              : scrollView,
        ),
      ),
    );
  }

  RegisteredBookSource? get _selectedLoginSource {
    final id = _state.selectedSourceId;
    if (id == null) return null;
    final source = _state.discoverySources
        .where((candidate) => candidate.id == id)
        .firstOrNull;
    if (source?.sourceProtocol != BookSourceProtocolKind.readingSource ||
        '${source?.sourceConfig?['loginUrl'] ?? ''}'.trim().isEmpty) {
      return null;
    }
    return source;
  }

  String? _loginPromptKey;

  void _maybePromptForLogin(Object error) {
    final source = _selectedLoginSource;
    if (source == null || !mounted) return;
    final key = '${source.id}:${error.toString()}';
    if (_loginPromptKey == key) return;
    _loginPromptKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final shouldLogin = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.sourceLoginTitle),
          content: Text(context.l10n.sourceLoginDiscoveryNotice(source.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.login_rounded),
              label: Text(context.l10n.sourceLoginTitle),
            ),
          ],
        ),
      );
      if (shouldLogin == true && mounted) await _openSourceLogin(source);
    });
  }

  List<Widget> _buildSectionSlivers(double bottomPadding) {
    if (_state.loadingSources) {
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
    final cache = _state.caches[_state.section];
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
      _maybePromptForLogin(cache.error!);
      return [
        _paddedSectionSliver(
          BookSourceMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.discoverLoadFailed,
            message: cache.error.toString(),
            actionLabel: context.l10n.discoverRetry,
            onAction: () =>
                _controller.loadSection(_state.section, force: true),
          ),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    if (_layoutController.layout.value == BookSourceDiscoverLayout.list) {
      return _buildListLayoutSlivers(cache, bottomPadding);
    }
    return switch (_state.section) {
      BookSourcesSection.recommended => _buildShelvesSlivers(
        cache,
        bottomPadding,
      ),
      BookSourcesSection.categories => _buildCategoriesSlivers(
        cache,
        bottomPadding,
      ),
      BookSourcesSection.latest => _buildLatestSlivers(cache, bottomPadding),
    };
  }

  List<Widget> _buildShelvesSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding,
  ) {
    final shelves = (cache.shelves ?? const <BookSourceDiscoveryShelf>[])
        .where((shelf) => _state.matchesSelectedSource(shelf.source))
        .toList(growable: false);
    if (shelves.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.recommended).isEmpty
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

  Widget _buildShelf(BookSourceDiscoveryShelf shelf) {
    return BookSourceDiscoveryShelfSection(
      shelf: shelf,
      onBookTap: _actions.showBookDetails,
    );
  }

  List<Widget> _buildCategoriesSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding, {
    bool showChannelStrip = true,
  }) {
    final categories = (cache.categories ?? const <SourcedBookCategory>[])
        .where((category) => _state.matchesSelectedSource(category.source))
        .toList(growable: false);
    if (categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    final selectedCategory = _state.selectedCategory ?? categories.first;
    final slivers = <Widget>[];
    if (showChannelStrip) {
      slivers.add(
        _paddedSectionSliver(
          _buildCategoryChannels(categories, selectedCategory),
          bottomPadding: 18,
        ),
      );
    }
    if (_state.loadingCategoryBooks) {
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
    } else if (_state.categoryLoadError != null) {
      slivers.add(
        _paddedSectionSliver(
          BookSourceMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.bookSourceChannelLoadFailed,
            message: context.l10n.bookSourceChannelLoadFailedMessage(
              _categoryErrorMessage(_state.categoryLoadError!),
            ),
            actionLabel: context.l10n.retry,
            onAction: () => _controller.selectCategory(selectedCategory),
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else if (_state.categoryBooks.isEmpty) {
      slivers.add(
        _paddedSectionSliver(
          BookSourceMessageCard(
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
          _state.categoryBooks,
          bottomPadding:
              _state.categoryHasMore ||
                  _state.loadingMoreCategoryBooks ||
                  _state.categoryLoadMoreFailed
              ? 12
              : bottomPadding,
        ),
      );
      if (_state.categoryHasMore ||
          _state.loadingMoreCategoryBooks ||
          _state.categoryLoadMoreFailed) {
        slivers.add(
          _paddedSectionSliver(
            Center(
              child: _state.loadingMoreCategoryBooks
                  ? const CircularProgressIndicator()
                  : OutlinedButton.icon(
                      key: const Key('bookSourceCategoryLoadMore'),
                      onPressed: _controller.loadMoreCategory,
                      icon: Icon(
                        _state.categoryLoadMoreFailed
                            ? Icons.refresh_rounded
                            : Icons.expand_more_rounded,
                      ),
                      label: Text(
                        _state.categoryLoadMoreFailed
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
    BookSourcesSectionCache cache,
    double bottomPadding,
  ) {
    final categories = _state.listChannelsBySource.values
        .expand((items) => items)
        .toList(growable: false);
    if (!_state.showListDirectory && categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }

    if (_state.showListDirectory || _state.selectedCategory == null) {
      final groups = _memoizedListGroups();
      final filteredGroups = _memoizedFilteredListGroups(groups);
      return [
        BookSourceListDirectory(
          searchController: _listSourceSearchController,
          groups: groups,
          filteredGroups: filteredGroups,
          state: _state,
          searchHint: context.l10n.bookSourcesManagementSearchHint,
          clearSearchTooltip: context.l10n.bookSourcesClearSearch,
          noMatchesLabel: context.l10n.bookSourcesNoMatchingSources,
          resetFiltersLabel: context.l10n.bookSourcesResetFilters,
          retryLabel: context.l10n.retry,
          channelCountLabel: context.l10n.bookSourceChannelCount,
          onQueryChanged: _controller.setListSourceQuery,
          onClearQuery: _clearListSourceSearch,
          onToggleSource: (group) =>
              unawaited(_controller.toggleListSource(group)),
          onExpandSource: (group) =>
              unawaited(_controller.expandListSource(group)),
          onSelectCategory: (category) =>
              unawaited(_selectListCategory(category)),
          shouldAnimateSource: _revealedListSourceIds.add,
        ),
      ];
    }

    return [
      _paddedSectionSliver(
        BookSourceListSelectionHeader(
          category: _state.selectedCategory!,
          changeLabel: context.l10n.bookSourceChangeChannel,
          onChange: _returnToListDirectory,
        ),
        bottomPadding: 12,
      ),
      ..._buildCategoriesSlivers(cache, bottomPadding, showChannelStrip: false),
    ];
  }

  void _clearListSourceSearch() {
    _listSourceSearchController.clear();
    _controller.setListSourceQuery('');
  }

  Future<void> _selectListCategory(SourcedBookCategory category) async {
    if (_scrollController.hasClients) {
      _listDirectoryScrollOffset = _scrollController.offset;
      _scrollController.jumpTo(0);
    }
    await _controller.selectListCategory(category);
  }

  void _returnToListDirectory() {
    if (_scrollController.hasClients && _scrollController.offset != 0) {
      _scrollController.jumpTo(0);
    }
    _controller.returnToListDirectory();
    final target = _listDirectoryScrollOffset;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  Widget _buildCategoryChannels(
    List<SourcedBookCategory> categories,
    SourcedBookCategory selectedCategory,
  ) {
    return BookSourceCategoryChannels(
      categories: categories,
      selectedCategory: selectedCategory,
      pickerLabel: context.l10n.discoverCategories,
      onSelected: (category) => unawaited(_controller.selectCategory(category)),
      onOpenPicker: () => unawaited(_openCategoryPicker(categories)),
    );
  }

  List<Widget> _buildLatestSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding,
  ) {
    final books = (cache.books ?? const <SourcedBook>[])
        .where((result) => _state.matchesSelectedSource(result.source))
        .toList(growable: false);
    if (books.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.latest).isEmpty
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
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, childIndex) {
            if (childIndex.isOdd) return const SizedBox(height: 10);
            final index = childIndex ~/ 2;
            final result = books[index];
            return BookSourceListReveal(
              key: Key(
                'bookSourceBookReveal-${result.source.id}-${result.book.id}',
              ),
              animate: _shouldAnimateBook(result),
              order: index,
              child: _centerSectionChild(
                SourcedBookListTile(
                  result: result,
                  onTap: () => _actions.showBookDetails(result),
                ),
              ),
            );
          },
          childCount: books.isEmpty ? 0 : (books.length * 2) - 1,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }

  bool _shouldAnimateBook(SourcedBook result) {
    final category = _state.selectedCategory;
    final scope = category == null
        ? '${_state.section.name}\u0000${_state.selectedSourceId ?? ''}'
        : '${category.source.id}\u0000${category.id}';
    if (_bookRevealScope != scope) {
      _bookRevealScope = scope;
      _revealedBookIds.clear();
    }
    return _revealedBookIds.add('${result.source.id}\u0000${result.book.id}');
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
    final hasEnabledSources = _state.sources.any((source) => source.enabled);
    return BookSourceMessageCard(
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
    return BookSourceMessageCard(
      icon: Icons.inbox_outlined,
      title: context.l10n.discoverEmptyTitle,
      message: context.l10n.discoverEmptyMessage,
    );
  }
}
