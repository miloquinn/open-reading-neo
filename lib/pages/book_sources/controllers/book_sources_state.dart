import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';

enum BookSourcesSection { recommended, categories, latest }

class BookSourceDiscoveryShelf {
  final RegisteredBookSource source;
  final String title;
  final List<BookSourceBook> items;

  BookSourceDiscoveryShelf({
    required this.source,
    required this.title,
    required List<BookSourceBook> items,
  }) : items = List.unmodifiable(items);
}

class SourcedBookCategory {
  final RegisteredBookSource source;
  final String id;
  final String name;

  const SourcedBookCategory({
    required this.source,
    required this.id,
    required this.name,
  });

  @override
  bool operator ==(Object other) =>
      other is SourcedBookCategory &&
      other.source.id == source.id &&
      other.id == id;

  @override
  int get hashCode => Object.hash(source.id, id);
}

class BookSourceListChannels {
  final RegisteredBookSource source;
  final List<SourcedBookCategory> channels;

  BookSourceListChannels({
    required this.source,
    required List<SourcedBookCategory> channels,
  }) : channels = List.unmodifiable(channels);
}

class BookSourcesSectionCache {
  final bool loading;
  final Object? error;
  final List<BookSourceDiscoveryShelf>? shelves;
  final List<SourcedBookCategory>? categories;
  final List<SourcedBook>? books;

  const BookSourcesSectionCache.loading()
    : loading = true,
      error = null,
      shelves = null,
      categories = null,
      books = null;

  const BookSourcesSectionCache.error(this.error)
    : loading = false,
      shelves = null,
      categories = null,
      books = null;

  BookSourcesSectionCache.shelves(List<BookSourceDiscoveryShelf> shelves)
    : loading = false,
      error = null,
      shelves = List.unmodifiable(shelves),
      categories = null,
      books = null;

  BookSourcesSectionCache.categories(List<SourcedBookCategory> categories)
    : loading = false,
      error = null,
      shelves = null,
      categories = List.unmodifiable(categories),
      books = null;

  BookSourcesSectionCache.books(List<SourcedBook> books)
    : loading = false,
      error = null,
      shelves = null,
      categories = null,
      books = List.unmodifiable(books);
}

class BookSourcesState {
  static const _unset = Object();

  final List<RegisteredBookSource> sources;
  final Map<BookSourcesSection, List<RegisteredBookSource>> sectionSources;
  final List<RegisteredBookSource> discoverySources;
  final bool loadingSources;
  final BookSourcesSection section;
  final String? selectedSourceId;
  final Map<BookSourcesSection, BookSourcesSectionCache> caches;
  final SourcedBookCategory? selectedCategory;
  final List<SourcedBook> categoryBooks;
  final bool loadingCategoryBooks;
  final bool loadingMoreCategoryBooks;
  final bool categoryLoadMoreFailed;
  final Object? categoryLoadError;
  final bool categoryHasMore;
  final int categoryPage;
  final String? expandedListSourceId;
  final String listSourceQuery;
  final bool showListDirectory;
  final Map<String, List<SourcedBookCategory>> listChannelsBySource;
  final Set<String> loadingListChannelSources;
  final Map<String, Object> listChannelErrors;
  final bool listLayout;
  final int largeSourceLibraryThreshold;

  /// Bumped only when [sectionSources] or [listChannelsBySource] actually
  /// change (a real source load, or one source's channels finishing a
  /// fetch) — never on every unrelated state change. [listSourceGroups]
  /// remaps every discoverable source into a wrapper object, which is cheap
  /// once but not something a source library running into the thousands
  /// should pay for on every rebuild; callers memoize it keyed on this.
  final int listGroupsRevision;

  BookSourcesState({
    List<RegisteredBookSource> sources = const [],
    Map<BookSourcesSection, List<RegisteredBookSource>> sectionSources =
        const {},
    List<RegisteredBookSource> discoverySources = const [],
    this.loadingSources = true,
    this.section = BookSourcesSection.recommended,
    this.selectedSourceId,
    Map<BookSourcesSection, BookSourcesSectionCache> caches = const {},
    this.selectedCategory,
    List<SourcedBook> categoryBooks = const [],
    this.loadingCategoryBooks = false,
    this.loadingMoreCategoryBooks = false,
    this.categoryLoadMoreFailed = false,
    this.categoryLoadError,
    this.categoryHasMore = false,
    this.categoryPage = 1,
    this.expandedListSourceId,
    this.listSourceQuery = '',
    this.showListDirectory = true,
    Map<String, List<SourcedBookCategory>> listChannelsBySource = const {},
    Set<String> loadingListChannelSources = const {},
    Map<String, Object> listChannelErrors = const {},
    this.listLayout = false,
    this.largeSourceLibraryThreshold = 40,
    this.listGroupsRevision = 0,
  }) : sources = List.unmodifiable(sources),
       sectionSources = _freezeListMap(sectionSources),
       discoverySources = List.unmodifiable(discoverySources),
       caches = Map.unmodifiable(caches),
       categoryBooks = List.unmodifiable(categoryBooks),
       listChannelsBySource = _freezeListMap(listChannelsBySource),
       loadingListChannelSources = Set.unmodifiable(loadingListChannelSources),
       listChannelErrors = Map.unmodifiable(listChannelErrors);

  List<RegisteredBookSource> sourcesFor(BookSourcesSection section) =>
      sectionSources[section] ?? const [];

  bool matchesSelectedSource(RegisteredBookSource source) =>
      selectedSourceId == null || source.id == selectedSourceId;

  List<RegisteredBookSource> scopedSourcesFor(BookSourcesSection section) =>
      sourcesFor(section).where(matchesSelectedSource).toList(growable: false);

  List<BookSourcesSection> get availableSections => BookSourcesSection.values
      .where((section) => sourcesFor(section).any(matchesSelectedSource))
      .toList(growable: false);

  bool get requiresScopedDiscovery =>
      discoverySources.length > largeSourceLibraryThreshold;

  List<BookSourceListChannels> get listSourceGroups =>
      sourcesFor(BookSourcesSection.categories)
          .map(
            (source) => BookSourceListChannels(
              source: source,
              channels: listChannelsBySource[source.id] ?? const [],
            ),
          )
          .toList(growable: false);

  BookSourcesState copyWith({
    List<RegisteredBookSource>? sources,
    Map<BookSourcesSection, List<RegisteredBookSource>>? sectionSources,
    List<RegisteredBookSource>? discoverySources,
    bool? loadingSources,
    BookSourcesSection? section,
    Object? selectedSourceId = _unset,
    Map<BookSourcesSection, BookSourcesSectionCache>? caches,
    Object? selectedCategory = _unset,
    List<SourcedBook>? categoryBooks,
    bool? loadingCategoryBooks,
    bool? loadingMoreCategoryBooks,
    bool? categoryLoadMoreFailed,
    Object? categoryLoadError = _unset,
    bool? categoryHasMore,
    int? categoryPage,
    Object? expandedListSourceId = _unset,
    String? listSourceQuery,
    bool? showListDirectory,
    Map<String, List<SourcedBookCategory>>? listChannelsBySource,
    Set<String>? loadingListChannelSources,
    Map<String, Object>? listChannelErrors,
    bool? listLayout,
    int? listGroupsRevision,
  }) => BookSourcesState(
    sources: List.unmodifiable(sources ?? this.sources),
    sectionSources: sectionSources ?? this.sectionSources,
    discoverySources: List.unmodifiable(
      discoverySources ?? this.discoverySources,
    ),
    loadingSources: loadingSources ?? this.loadingSources,
    section: section ?? this.section,
    selectedSourceId: identical(selectedSourceId, _unset)
        ? this.selectedSourceId
        : selectedSourceId as String?,
    caches: caches ?? this.caches,
    selectedCategory: identical(selectedCategory, _unset)
        ? this.selectedCategory
        : selectedCategory as SourcedBookCategory?,
    categoryBooks: List.unmodifiable(categoryBooks ?? this.categoryBooks),
    loadingCategoryBooks: loadingCategoryBooks ?? this.loadingCategoryBooks,
    loadingMoreCategoryBooks:
        loadingMoreCategoryBooks ?? this.loadingMoreCategoryBooks,
    categoryLoadMoreFailed:
        categoryLoadMoreFailed ?? this.categoryLoadMoreFailed,
    categoryLoadError: identical(categoryLoadError, _unset)
        ? this.categoryLoadError
        : categoryLoadError,
    categoryHasMore: categoryHasMore ?? this.categoryHasMore,
    categoryPage: categoryPage ?? this.categoryPage,
    expandedListSourceId: identical(expandedListSourceId, _unset)
        ? this.expandedListSourceId
        : expandedListSourceId as String?,
    listSourceQuery: listSourceQuery ?? this.listSourceQuery,
    showListDirectory: showListDirectory ?? this.showListDirectory,
    listChannelsBySource: listChannelsBySource ?? this.listChannelsBySource,
    loadingListChannelSources:
        loadingListChannelSources ?? this.loadingListChannelSources,
    listChannelErrors: listChannelErrors ?? this.listChannelErrors,
    listLayout: listLayout ?? this.listLayout,
    largeSourceLibraryThreshold: largeSourceLibraryThreshold,
    listGroupsRevision: listGroupsRevision ?? this.listGroupsRevision,
  );
}

Map<K, List<V>> _freezeListMap<K, V>(Map<K, List<V>> source) =>
    Map<K, List<V>>.unmodifiable(
      source.map(
        (key, value) => MapEntry<K, List<V>>(key, List<V>.unmodifiable(value)),
      ),
    );
