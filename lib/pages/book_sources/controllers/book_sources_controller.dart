import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_gateway.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';
export 'book_sources_state.dart';

import 'book_sources_state.dart';

class BookSourcesController extends ChangeNotifier {
  BookSourcesController({
    required this.gateway,
    BookSourceRegistry? registry,
    this.maxConcurrentSourceFetches = 8,
    this.largeSourceLibraryThreshold = 40,
    this.maxLatestItemsPerSource = 12,
  }) : _registry = registry ?? BookSourceRegistry(),
       _state = BookSourcesState(
         largeSourceLibraryThreshold: largeSourceLibraryThreshold,
       );

  final BookSourceGateway gateway;
  final BookSourceRegistry _registry;
  final int maxConcurrentSourceFetches;
  final int largeSourceLibraryThreshold;
  final int maxLatestItemsPerSource;
  BookSourcesState _state;
  StreamSubscription<void>? _registrySubscription;
  int _sourceRevision = 0;
  int _sectionRevision = 0;
  int _categoryRevision = 0;
  bool _started = false;
  bool _closed = false;

  BookSourcesState get state => _state;

  Future<void> load() async {
    if (_closed) return;
    if (!_started) {
      _started = true;
      _registrySubscription = _registry.changes.listen((_) {
        unawaited(reload());
      });
    }
    await _loadSources();
  }

  void setListLayout(bool value) {
    if (_closed || _state.listLayout == value) return;
    _sectionRevision++;
    _categoryRevision++;
    if (value) {
      _emit(
        _resetCategory(
          _state.copyWith(
            listLayout: true,
            section: BookSourcesSection.categories,
            selectedSourceId: null,
            expandedListSourceId: null,
            showListDirectory: true,
            caches: {
              ..._state.caches,
              BookSourcesSection.categories: BookSourcesSectionCache.categories(
                _allLoadedListChannels(),
              ),
            },
          ),
        ),
      );
      if (!_state.loadingSources) {
        unawaited(loadSection(BookSourcesSection.categories));
      }
      return;
    }
    _emit(_state.copyWith(listLayout: false));
    if (!_state.loadingSources &&
        _state.section == BookSourcesSection.categories) {
      _autoSelectFirstCategory();
    }
  }

  Future<void> reload() async {
    if (_closed) return;
    _sourceRevision++;
    _sectionRevision++;
    _categoryRevision++;
    _emit(
      _resetCategory(
        _state.copyWith(
          loadingSources: true,
          selectedSourceId: null,
          caches: const {},
          expandedListSourceId: null,
          showListDirectory: true,
          listChannelsBySource: const {},
          loadingListChannelSources: const {},
          listChannelErrors: const {},
        ),
      ),
    );
    await _loadSources();
  }

  Future<void> _loadSources() async {
    final revision = ++_sourceRevision;
    final sources = await _registry.loadRunnableInBackground();
    if (_closed || revision != _sourceRevision) return;
    final sectionSources = _buildSectionSourceIndex(sources);
    final discoveryIds = sectionSources.values
        .expand((items) => items)
        .map((source) => source.id)
        .toSet();
    final discoverySources = sources
        .where((source) => discoveryIds.contains(source.id))
        .toList(growable: false);
    var selectedSourceId = _state.selectedSourceId;
    if (!_state.listLayout &&
        discoverySources.length > largeSourceLibraryThreshold &&
        (selectedSourceId == null ||
            !discoveryIds.contains(selectedSourceId))) {
      selectedSourceId = discoverySources.firstOrNull?.id;
    }
    var next = _state.copyWith(
      sources: sources,
      sectionSources: sectionSources,
      discoverySources: discoverySources,
      selectedSourceId: selectedSourceId,
      loadingSources: false,
      listGroupsRevision: _state.listGroupsRevision + 1,
    );
    if (next.availableSections.isNotEmpty &&
        !next.availableSections.contains(next.section)) {
      next = next.copyWith(section: next.availableSections.first);
    }
    _emit(next);
    await loadSection(_state.section);
  }

  Future<void> changeSourceScope(String? sourceId) async {
    if (_closed || _state.selectedSourceId == sourceId) return;
    var next = _resetCategory(
      _state.copyWith(selectedSourceId: sourceId, caches: const {}),
    );
    if (next.availableSections.isNotEmpty &&
        !next.availableSections.contains(next.section)) {
      next = next.copyWith(section: next.availableSections.first);
    }
    _emit(next);
    await loadSection(_state.section);
  }

  Future<void> changeSection(BookSourcesSection section) async {
    if (_closed) return;
    _categoryRevision++;
    _emit(_resetCategory(_state.copyWith(section: section)));
    await loadSection(section);
  }

  Future<void> loadSection(
    BookSourcesSection section, {
    bool force = false,
    bool preserveContent = false,
  }) async {
    if (_closed) return;
    final revision = ++_sectionRevision;
    if (!force && _state.caches[section] != null) return;
    final currentCache = _state.caches[section];
    final keepCurrentContent =
        preserveContent &&
        currentCache != null &&
        !currentCache.loading &&
        currentCache.error == null;
    if (force) {
      await gateway.invalidateResponseCaches(_state.scopedSourcesFor(section));
      if (_closed || revision != _sectionRevision) {
        _clearStaleLoading(section);
        return;
      }
    }
    if (section == BookSourcesSection.categories &&
        _state.listLayout &&
        _state.showListDirectory) {
      _setCache(
        section,
        BookSourcesSectionCache.categories(_allLoadedListChannels()),
      );
      return;
    }
    if (!keepCurrentContent) {
      var next = _state.copyWith(
        caches: {
          ..._state.caches,
          section: const BookSourcesSectionCache.loading(),
        },
      );
      if (force && section == BookSourcesSection.categories) {
        next = _resetCategory(next);
      }
      _emit(next);
    }
    BookSourcesSectionCache nextCache;
    try {
      nextCache = switch (section) {
        BookSourcesSection.recommended => BookSourcesSectionCache.shelves(
          await _fetchShelves(),
        ),
        BookSourcesSection.categories => BookSourcesSectionCache.categories(
          await _fetchCategories(),
        ),
        BookSourcesSection.latest => BookSourcesSectionCache.books(
          await _fetchLatest(),
        ),
      };
    } catch (error) {
      nextCache = BookSourcesSectionCache.error(error);
    }
    if (_closed || revision != _sectionRevision) {
      _clearStaleLoading(section);
      return;
    }
    var next = _state.copyWith(caches: {..._state.caches, section: nextCache});
    if (keepCurrentContent &&
        section == BookSourcesSection.categories &&
        nextCache.error == null) {
      next = _resetCategory(next);
    }
    _emit(next);
    if (section == BookSourcesSection.categories &&
        !(_state.listLayout && _state.showListDirectory)) {
      _autoSelectFirstCategory();
    }
  }

  Future<void> selectCategory(SourcedBookCategory category) async {
    if (_closed) return;
    final revision = ++_categoryRevision;
    final supportsBrowse = category.source.capabilities.contains('browse');
    _emit(
      _state.copyWith(
        selectedCategory: category,
        categoryBooks: const [],
        loadingCategoryBooks: supportsBrowse,
        loadingMoreCategoryBooks: false,
        categoryLoadMoreFailed: false,
        categoryLoadError: null,
        categoryHasMore: false,
        categoryPage: 1,
      ),
    );
    if (!supportsBrowse) return;
    try {
      final page = await gateway.browse(
        category.source,
        category: category.id,
        sort: 'popular',
      );
      if (_closed ||
          revision != _categoryRevision ||
          _state.selectedCategory != category) {
        return;
      }
      _emit(
        _state.copyWith(
          categoryBooks: page.items
              .map((book) => SourcedBook(source: category.source, book: book))
              .toList(growable: false),
          loadingCategoryBooks: false,
          categoryPage: page.page,
          categoryHasMore: page.hasMore && page.items.isNotEmpty,
        ),
      );
    } catch (error) {
      if (_closed ||
          revision != _categoryRevision ||
          _state.selectedCategory != category) {
        return;
      }
      _emit(
        _state.copyWith(loadingCategoryBooks: false, categoryLoadError: error),
      );
    }
  }

  Future<void> loadMoreCategory() async {
    final category = _state.selectedCategory;
    if (_closed ||
        category == null ||
        _state.loadingCategoryBooks ||
        _state.loadingMoreCategoryBooks ||
        !_state.categoryHasMore) {
      return;
    }
    final revision = _categoryRevision;
    _emit(
      _state.copyWith(
        loadingMoreCategoryBooks: true,
        categoryLoadMoreFailed: false,
      ),
    );
    try {
      final page = await gateway.browse(
        category.source,
        category: category.id,
        sort: 'popular',
        page: _state.categoryPage + 1,
      );
      if (_closed ||
          revision != _categoryRevision ||
          _state.selectedCategory != category) {
        return;
      }
      final seen = _state.categoryBooks
          .map((item) => '${item.source.id}\u0000${item.book.id}')
          .toSet();
      final appended = page.items
          .map((book) => SourcedBook(source: category.source, book: book))
          .where((item) => seen.add('${item.source.id}\u0000${item.book.id}'))
          .toList(growable: false);
      _emit(
        _state.copyWith(
          categoryBooks: [..._state.categoryBooks, ...appended],
          categoryPage: page.page,
          categoryHasMore:
              page.hasMore && page.items.isNotEmpty && appended.isNotEmpty,
          loadingMoreCategoryBooks: false,
        ),
      );
    } catch (_) {
      if (_closed ||
          revision != _categoryRevision ||
          _state.selectedCategory != category) {
        return;
      }
      _emit(
        _state.copyWith(
          loadingMoreCategoryBooks: false,
          categoryLoadMoreFailed: true,
        ),
      );
    }
  }

  Future<void> refresh() async {
    if (_state.listLayout) {
      _sectionRevision++;
      _categoryRevision++;
      _emit(
        _resetCategory(
          _state.copyWith(
            section: BookSourcesSection.categories,
            selectedSourceId: null,
            expandedListSourceId: null,
            showListDirectory: true,
            listChannelsBySource: const {},
            loadingListChannelSources: const {},
            listChannelErrors: const {},
          ),
        ),
      );
      await loadSection(BookSourcesSection.categories, force: true);
      return;
    }
    await loadSection(_state.section, force: true, preserveContent: true);
  }

  void setListSourceQuery(String query) {
    if (_closed || query == _state.listSourceQuery) return;
    _emit(_state.copyWith(listSourceQuery: query));
  }

  Future<void> toggleListSource(BookSourceListChannels group) async {
    if (_state.expandedListSourceId == group.source.id) {
      _emit(_state.copyWith(expandedListSourceId: null));
      return;
    }
    await expandListSource(group);
  }

  Future<void> expandListSource(BookSourceListChannels group) async {
    if (_closed) return;
    _emit(_state.copyWith(expandedListSourceId: group.source.id));
    if (_state.listChannelsBySource.containsKey(group.source.id) ||
        _state.loadingListChannelSources.contains(group.source.id)) {
      return;
    }
    final revision = _sourceRevision;
    final errors = {..._state.listChannelErrors}..remove(group.source.id);
    _emit(
      _state.copyWith(
        loadingListChannelSources: {
          ..._state.loadingListChannelSources,
          group.source.id,
        },
        listChannelErrors: errors,
      ),
    );
    try {
      final channels = await gateway.getCategories(group.source);
      if (_closed || revision != _sourceRevision) return;
      final loaded = {
        ..._state.listChannelsBySource,
        group.source.id: _uniqueSourcedCategories(group.source, channels),
      };
      final loading = {..._state.loadingListChannelSources}
        ..remove(group.source.id);
      final errors = {..._state.listChannelErrors}..remove(group.source.id);
      _emit(
        _state.copyWith(
          listChannelsBySource: loaded,
          loadingListChannelSources: loading,
          listChannelErrors: errors,
          caches: {
            ..._state.caches,
            BookSourcesSection.categories: BookSourcesSectionCache.categories(
              loaded.values.expand((items) => items).toList(growable: false),
            ),
          },
          listGroupsRevision: _state.listGroupsRevision + 1,
        ),
      );
    } catch (error) {
      if (_closed || revision != _sourceRevision) return;
      final loading = {..._state.loadingListChannelSources}
        ..remove(group.source.id);
      _emit(
        _state.copyWith(
          loadingListChannelSources: loading,
          listChannelErrors: {
            ..._state.listChannelErrors,
            group.source.id: error,
          },
        ),
      );
    }
  }

  Future<void> selectListCategory(SourcedBookCategory category) async {
    _emit(
      _state.copyWith(
        selectedSourceId: category.source.id,
        showListDirectory: false,
      ),
    );
    await selectCategory(category);
  }

  void returnToListDirectory() {
    final sourceId = _state.selectedCategory?.source.id;
    _categoryRevision++;
    _emit(
      _resetCategory(
        _state.copyWith(
          expandedListSourceId: sourceId,
          selectedSourceId: null,
          showListDirectory: true,
        ),
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sourceRevision++;
    _sectionRevision++;
    _categoryRevision++;
    final subscription = _registrySubscription;
    _registrySubscription = null;
    await subscription?.cancel();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  Map<BookSourcesSection, List<RegisteredBookSource>> _buildSectionSourceIndex(
    List<RegisteredBookSource> sources,
  ) {
    final result = <BookSourcesSection, List<RegisteredBookSource>>{};
    for (final section in BookSourcesSection.values) {
      final capability = switch (section) {
        BookSourcesSection.recommended => 'discover',
        BookSourcesSection.categories => 'categories',
        BookSourcesSection.latest => 'browse',
      };
      result[section] = sources
          .where((source) => source.enabled)
          .where((source) => source.capabilities.contains(capability))
          .where(
            (source) =>
                section != BookSourcesSection.latest ||
                source.sourceProtocol == BookSourceProtocolKind.orsp,
          )
          .toList(growable: false);
    }
    return Map.unmodifiable(result);
  }

  Future<List<BookSourceDiscoveryShelf>> _fetchShelves() async {
    final batches = await _fetchSourceBatches(
      _state.scopedSourcesFor(BookSourcesSection.recommended),
      (source) async {
        final page = await gateway.getDiscovery(source);
        return page.sections
            .where((section) => section.items.isNotEmpty)
            .map(
              (section) => BookSourceDiscoveryShelf(
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

  Future<List<SourcedBookCategory>> _fetchCategories() async {
    final batches = await _fetchSourceBatches(
      _state.scopedSourcesFor(BookSourcesSection.categories),
      (source) async =>
          _uniqueSourcedCategories(source, await gateway.getCategories(source)),
    );
    return batches.expand((items) => items).toList(growable: false);
  }

  Future<List<SourcedBook>> _fetchLatest() async {
    final batches = await _fetchSourceBatches(
      _state.scopedSourcesFor(BookSourcesSection.latest),
      (source) async {
        final page = await gateway.browse(source, sort: 'latest');
        return page.items
            .map((book) => SourcedBook(source: source, book: book))
            .toList(growable: false);
      },
    );
    return mergeLatestSourceBatches(
      batches,
      maxItemsPerSource: maxLatestItemsPerSource,
    );
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
          results[index] = _SourceFetchResult.success(
            source,
            await fetch(source),
          );
        } catch (error) {
          results[index] = _SourceFetchResult.failure(source, error);
        }
      }
    }

    await Future.wait(
      List.generate(
        sources.length.clamp(1, maxConcurrentSourceFetches),
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
    final failures = completed.where((result) => result.error != null).toList();
    if (!batches.any((items) => items.isNotEmpty) && failures.isNotEmpty) {
      throw BookSourceProtocolException(
        failures
            .map((failure) => '${failure.source.name}: ${failure.error}')
            .join('\n'),
      );
    }
    return batches;
  }

  List<SourcedBookCategory> _uniqueSourcedCategories(
    RegisteredBookSource source,
    Iterable<BookSourceCategory> categories,
  ) {
    final seen = <String>{};
    return categories
        .where((category) => seen.add(category.id))
        .map(
          (category) => SourcedBookCategory(
            source: source,
            id: category.id,
            name: category.name,
          ),
        )
        .toList(growable: false);
  }

  void _autoSelectFirstCategory() {
    final categories =
        (_state.caches[BookSourcesSection.categories]?.categories ?? const [])
            .where((category) => _state.matchesSelectedSource(category.source))
            .toList(growable: false);
    if (_state.selectedCategory == null && categories.isNotEmpty) {
      unawaited(selectCategory(categories.first));
    }
  }

  BookSourcesState _resetCategory(BookSourcesState state) => state.copyWith(
    selectedCategory: null,
    categoryBooks: const [],
    loadingCategoryBooks: false,
    loadingMoreCategoryBooks: false,
    categoryLoadMoreFailed: false,
    categoryLoadError: null,
    categoryHasMore: false,
    categoryPage: 1,
  );

  List<SourcedBookCategory> _allLoadedListChannels() => _state
      .listChannelsBySource
      .values
      .expand((items) => items)
      .toList(growable: false);

  void _setCache(BookSourcesSection section, BookSourcesSectionCache cache) {
    _emit(_state.copyWith(caches: {..._state.caches, section: cache}));
  }

  void _clearStaleLoading(BookSourcesSection section) {
    if (_closed ||
        _state.section == section ||
        _state.caches[section]?.loading != true) {
      return;
    }
    final caches = {..._state.caches}..remove(section);
    _emit(_state.copyWith(caches: caches));
  }

  void _emit(BookSourcesState next) {
    if (_closed) return;
    _state = next;
    notifyListeners();
  }
}

List<SourcedBook> mergeLatestSourceBatches(
  Iterable<List<SourcedBook>> batches, {
  required int maxItemsPerSource,
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

class _SourceFetchResult<T> {
  final RegisteredBookSource source;
  final List<T> items;
  final Object? error;

  const _SourceFetchResult.success(this.source, this.items) : error = null;

  const _SourceFetchResult.failure(this.source, this.error) : items = const [];
}
