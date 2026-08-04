// 文件说明：跨书源聚合搜索页，由发现页右上角搜索按钮进入。
// 技术要点：Flutter UI、并发书源请求、按源分页加载更多。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

import 'widgets/sourced_book_widgets.dart';

/// 跨已启用书源的聚合搜索页。
///
/// 搜索范围与分页状态都在本页内维护；发现页只负责展示书籍。
class SourceSearchPage extends StatefulWidget {
  final List<RegisteredBookSource> sources;
  final BookSourceClient client;
  final BookSourceShelfService shelfService;
  final int maxConcurrentSearches;
  final Duration perSourceSearchTimeout;

  const SourceSearchPage({
    super.key,
    required this.sources,
    required this.client,
    required this.shelfService,
    this.maxConcurrentSearches = 8,
    this.perSourceSearchTimeout = const Duration(seconds: 6),
  }) : assert(maxConcurrentSearches > 0);

  /// 解析实际参与搜索的书源集合；发现页与测试也复用这份规则。
  static List<RegisteredBookSource> searchTargets(
    Iterable<RegisteredBookSource> sources,
    String? selectedSourceId,
  ) {
    final enabled = sources.where((source) => source.enabled);
    if (selectedSourceId == null) return enabled.toList(growable: false);
    return enabled
        .where((source) => source.id == selectedSourceId)
        .toList(growable: false);
  }

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Set<BookDownloadCancellation> _activeSearchCancellations = {};
  final List<SourcedBook> _results = [];
  final Set<String> _resultKeys = {};
  final Map<String, _SearchPageState> _pageStates = {};
  late final SourcedBookActions _actions = SourcedBookActions(
    context: context,
    client: widget.client,
    shelfService: widget.shelfService,
  );

  String? _selectedSourceId;
  bool _searching = false;
  bool _hasSearched = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  int _failedSourceCount = 0;
  String _activeQuery = '';
  int _searchGeneration = 0;
  int _completedSourceCount = 0;
  int _totalSourceCount = 0;

  bool get _hasMore => _pageStates.values.any((state) => state.hasMore);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    // 进入搜索页直接聚焦输入框，用户可立即输入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _cancelActiveSearches();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_loadMoreFailed ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > 600) {
      return;
    }
    unawaited(_loadMore());
  }

  List<RegisteredBookSource> get _targets =>
      SourceSearchPage.searchTargets(widget.sources, _selectedSourceId);

  void _cancelActiveSearches() {
    for (final cancellation in _activeSearchCancellations.toList()) {
      cancellation.cancel();
    }
    _activeSearchCancellations.clear();
  }

  Future<_SearchBatch> _searchSource(
    RegisteredBookSource source,
    String query, {
    int page = 1,
  }) async {
    final cancellation = BookDownloadCancellation();
    _activeSearchCancellations.add(cancellation);
    try {
      final result = await widget.client
          .search(source, query, page: page, cancellation: cancellation)
          .timeout(
            widget.perSourceSearchTimeout,
            onTimeout: () {
              cancellation.cancel();
              throw TimeoutException(
                'Book source search timed out: ${source.id}',
              );
            },
          );
      return _SearchBatch(
        source: source,
        items: result.items
            .map((book) => SourcedBook(source: source, book: book))
            .toList(growable: false),
        page: result.page,
        hasMore: result.hasMore && result.items.isNotEmpty,
      );
    } catch (_) {
      return _SearchBatch(source: source, items: const [], failed: true);
    } finally {
      _activeSearchCancellations.remove(cancellation);
    }
  }

  void _mergeBatch(_SearchBatch batch) {
    if (!batch.failed) {
      _pageStates[batch.source.id] = _SearchPageState(
        source: batch.source,
        page: batch.page,
        hasMore: batch.hasMore,
      );
    }
    for (final item in batch.items) {
      final key = '${item.source.id}\u0000${item.book.id}';
      if (_resultKeys.add(key)) _results.add(item);
    }
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    final targetSources = _targets;
    if (query.isEmpty || targetSources.isEmpty) {
      _searchGeneration++;
      _cancelActiveSearches();
      if (_searching && mounted) setState(() => _searching = false);
      return;
    }
    final generation = ++_searchGeneration;
    _cancelActiveSearches();

    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _hasSearched = true;
      _failedSourceCount = 0;
      _activeQuery = query;
      _results.clear();
      _resultKeys.clear();
      _pageStates.clear();
      _loadingMore = false;
      _loadMoreFailed = false;
      _completedSourceCount = 0;
      _totalSourceCount = targetSources.length;
    });

    var nextIndex = 0;
    Future<void> worker() async {
      while (mounted && generation == _searchGeneration) {
        final index = nextIndex++;
        if (index >= targetSources.length) return;
        final batch = await _searchSource(targetSources[index], query);
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _mergeBatch(batch);
          _completedSourceCount++;
          if (batch.failed) _failedSourceCount++;
        });
        // Synchronously failing sources must still yield so a large registry
        // cannot starve Flutter's next frame.
        await Future<void>.delayed(Duration.zero);
      }
    }

    final concurrency = targetSources.length < widget.maxConcurrentSearches
        ? targetSources.length
        : widget.maxConcurrentSearches;
    await Future.wait(List.generate(concurrency, (_) => worker()));

    if (!mounted || generation != _searchGeneration) return;
    setState(() => _searching = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
  }

  Future<void> _loadMore() async {
    if (_searching || _loadingMore || !_hasSearched || _activeQuery.isEmpty) {
      return;
    }
    final targets = _pageStates.values
        .where((state) => state.hasMore)
        .toList(growable: false);
    if (targets.isEmpty) return;

    final query = _activeQuery;
    final generation = _searchGeneration;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });

    var anyFailed = false;
    var nextIndex = 0;
    Future<void> worker() async {
      while (mounted &&
          generation == _searchGeneration &&
          query == _activeQuery) {
        final index = nextIndex++;
        if (index >= targets.length) return;
        final state = targets[index];
        final batch = await _searchSource(
          state.source,
          query,
          page: state.page + 1,
        );
        if (!mounted ||
            generation != _searchGeneration ||
            query != _activeQuery) {
          return;
        }
        setState(() {
          anyFailed = anyFailed || batch.failed;
          if (!batch.failed) _mergeBatch(batch);
          _loadMoreFailed = anyFailed;
        });
        await Future<void>.delayed(Duration.zero);
      }
    }

    final concurrency = targets.length < widget.maxConcurrentSearches
        ? targets.length
        : widget.maxConcurrentSearches;
    await Future.wait(List.generate(concurrency, (_) => worker()));

    if (!mounted || generation != _searchGeneration || query != _activeQuery) {
      return;
    }
    setState(() => _loadingMore = false);
  }

  void _clearSearch() {
    _searchGeneration++;
    _cancelActiveSearches();
    _queryController.clear();
    setState(() {
      _results.clear();
      _resultKeys.clear();
      _pageStates.clear();
      _hasSearched = false;
      _failedSourceCount = 0;
      _activeQuery = '';
      _searching = false;
      _loadingMore = false;
      _loadMoreFailed = false;
      _completedSourceCount = 0;
      _totalSourceCount = 0;
    });
    _queryFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final enabledSources = widget.sources
        .where((source) => source.enabled)
        .toList(growable: false);
    return FloatingSubpageScaffold(
      title: context.l10n.bookSourcesSearch,
      tools: _buildQueryField(enabledSources),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (enabledSources.isNotEmpty) _buildScopeChips(enabledSources),
          Expanded(child: _buildBody(enabledSources)),
        ],
      ),
    );
  }

  Widget _buildQueryField(List<RegisteredBookSource> enabledSources) {
    final canSearch = enabledSources.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: TextField(
        key: const Key('bookSourceQueryControl'),
        controller: _queryController,
        focusNode: _queryFocus,
        enabled: canSearch,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          hintText: context.l10n.bookSourcesSearchHint,
          border: InputBorder.none,
          suffixIcon: _queryController.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('bookSourceSearchClearButton'),
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).deleteButtonTooltip,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _clearSearch,
                ),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildScopeChips(List<RegisteredBookSource> enabledSources) {
    return SizedBox(
      key: const Key('bookSourceScopeControl'),
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: enabledSources.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return ChoiceChip(
              selected: _selectedSourceId == null,
              label: Text(context.l10n.statsRangeAll),
              onSelected: (_) => _changeScope(null),
            );
          }
          final source = enabledSources[index - 1];
          return ChoiceChip(
            selected: _selectedSourceId == source.id,
            label: Text(source.name),
            onSelected: (_) => _changeScope(source.id),
          );
        },
      ),
    );
  }

  void _changeScope(String? sourceId) {
    if (_selectedSourceId == sourceId) return;
    _searchGeneration++;
    _cancelActiveSearches();
    setState(() {
      _selectedSourceId = sourceId;
      if (_hasSearched) {
        _searching = false;
        _results.clear();
        _resultKeys.clear();
        _pageStates.clear();
      }
    });
    if (_hasSearched && _activeQuery.isNotEmpty) {
      _queryController.text = _activeQuery;
      unawaited(_search());
    }
  }

  Widget _buildBody(List<RegisteredBookSource> enabledSources) {
    final scheme = Theme.of(context).colorScheme;
    if (enabledSources.isEmpty) {
      return _buildMessage(
        icon: Icons.travel_explore_outlined,
        title: context.l10n.bookSourcesNoSourcesTitle,
        message: context.l10n.bookSourcesNoSourcesDescription,
      );
    }
    if (!_hasSearched) {
      return _buildMessage(
        icon: Icons.manage_search_rounded,
        title: context.l10n.bookSourcesSearch,
        message: context.l10n.bookSourcesSearchHint,
      );
    }
    if (_results.isEmpty) {
      if (_searching) {
        return _buildSearchingMessage();
      }
      return _buildMessage(
        icon: Icons.search_off_rounded,
        title: context.l10n.bookSourcesNoResults,
        message: _failedSourceCount > 0
            ? context.l10n.bookSourcesFailedCount(_failedSourceCount)
            : '',
      );
    }
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${context.l10n.bookSourcesSearch}'
                    ' · ${_scopeLabel()} · ${_results.length}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_searching) ...[
                  Text('$_completedSourceCount/$_totalSourceCount'),
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_failedSourceCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.bookSourcesFailedCount(_failedSourceCount),
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          sliver: SliverList.separated(
            itemCount: _results.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final result = _results[index];
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1048),
                  child: SourcedBookListTile(
                    result: result,
                    onTap: () => _actions.showBookDetails(result),
                  ),
                ),
              );
            },
          ),
        ),
        if (_hasMore || _loadingMore || _loadMoreFailed)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : OutlinedButton.icon(
                        key: const Key('bookSourceLoadMoreButton'),
                        onPressed: _loadMore,
                        icon: Icon(
                          _loadMoreFailed
                              ? Icons.refresh_rounded
                              : Icons.expand_more_rounded,
                        ),
                        label: Text(
                          _loadMoreFailed
                              ? context.l10n.retry
                              : context.l10n.bookSourcesLoadMore,
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  String _scopeLabel() {
    for (final source in widget.sources) {
      if (source.id == _selectedSourceId) return source.name;
    }
    return context.l10n.statsRangeAll;
  }

  Widget _buildSearchingMessage() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            '${context.l10n.bookSourcesSearch} '
            '$_completedSourceCount/$_totalSourceCount',
          ),
        ],
      ),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String message,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 42,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchBatch {
  final RegisteredBookSource source;
  final List<SourcedBook> items;
  final bool failed;
  final int page;
  final bool hasMore;

  const _SearchBatch({
    required this.source,
    required this.items,
    this.failed = false,
    this.page = 1,
    this.hasMore = false,
  });
}

class _SearchPageState {
  final RegisteredBookSource source;
  final int page;
  final bool hasMore;

  const _SearchPageState({
    required this.source,
    required this.page,
    required this.hasMore,
  });
}
