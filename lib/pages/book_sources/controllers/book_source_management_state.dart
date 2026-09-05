part of 'book_source_management_controller.dart';

@immutable
class BookSourceManagementState {
  factory BookSourceManagementState({
    List<RegisteredBookSource> sources = const [],
    List<String> groupOrder = const [],
    bool loading = true,
    String query = '',
    BookSourceManagementFilter filter = BookSourceManagementFilter.all,
    String? selectedGroup,
    int displayLimit = 24,
    bool selectionMode = false,
    Set<String> selectedSourceIds = const {},
    BookSourceHealthProgress? healthProgress,
    BookSourceManagementMutation? mutation,
    Object? failure,
    int sourcesRevision = 0,
  }) => BookSourceManagementState._(
    _LazyValue(),
    _LazyValue(),
    sources: List.unmodifiable(sources),
    groupOrder: List.unmodifiable(groupOrder),
    loading: loading,
    query: query,
    filter: filter,
    selectedGroup: selectedGroup,
    displayLimit: displayLimit,
    selectionMode: selectionMode,
    selectedSourceIds: Set.unmodifiable(selectedSourceIds),
    healthProgress: healthProgress,
    mutation: mutation,
    failure: failure,
    sourcesRevision: sourcesRevision,
  );

  const BookSourceManagementState._(
    this._visibleSourcesCache,
    this._availableGroupsCache, {
    required this.sources,
    required this.groupOrder,
    required this.loading,
    required this.query,
    required this.filter,
    required this.selectedGroup,
    required this.displayLimit,
    required this.selectionMode,
    required this.selectedSourceIds,
    required this.healthProgress,
    required this.mutation,
    required this.failure,
    required this.sourcesRevision,
  });

  final List<RegisteredBookSource> sources;
  final List<String> groupOrder;

  /// Bumped only when [sources] is actually replaced with a new list (a
  /// load, a mutation, a health-check merge) — never on an unrelated change
  /// like [query] or [healthProgress] ticking during a batch check.
  /// [visibleSources]/[availableGroups] memoize their full-list work and carry
  /// those caches across state copies that don't change their inputs.
  final int sourcesRevision;
  final bool loading;
  final String query;
  final BookSourceManagementFilter filter;
  final String? selectedGroup;
  final int displayLimit;
  final bool selectionMode;
  final Set<String> selectedSourceIds;
  final BookSourceHealthProgress? healthProgress;
  final BookSourceManagementMutation? mutation;
  final Object? failure;
  final _LazyValue<List<RegisteredBookSource>> _visibleSourcesCache;
  final _LazyValue<List<String>> _availableGroupsCache;

  List<RegisteredBookSource> get visibleSources =>
      _visibleSourcesCache.getOrCreate(_buildVisibleSources);

  List<RegisteredBookSource> _buildVisibleSources() {
    final normalizedQuery = query.trim().toLowerCase();
    return List.unmodifiable(
      sources.where((source) {
        final groups = bookSourceGroups(source);
        final matchesState = switch (filter) {
          BookSourceManagementFilter.all => true,
          BookSourceManagementFilter.favorites => source.isFavorite,
          BookSourceManagementFilter.enabled => source.enabled,
          BookSourceManagementFilter.disabled => !source.enabled,
          BookSourceManagementFilter.runnable => source.capabilities.isNotEmpty,
          BookSourceManagementFilter.pending => source.capabilities.isEmpty,
          BookSourceManagementFilter.requiresLogin => sourceRequiresLogin(
            source,
          ),
        };
        if (!matchesState) return false;
        if (selectedGroup case final selected?) {
          if (!groups.contains(selected)) return false;
        }
        if (normalizedQuery.isEmpty) return true;
        return source.name.toLowerCase().contains(normalizedQuery) ||
            source.description.toLowerCase().contains(normalizedQuery) ||
            source.apiBaseUrl.toString().toLowerCase().contains(
              normalizedQuery,
            ) ||
            groups.any(
              (group) => group.toLowerCase().contains(normalizedQuery),
            );
      }),
    );
  }

  List<String> get availableGroups =>
      _availableGroupsCache.getOrCreate(_buildAvailableGroups);

  List<String> _buildAvailableGroups() {
    final groups = <String>{...groupOrder};
    for (final source in sources) {
      groups.addAll(bookSourceGroups(source));
    }
    final remaining = groups.difference(groupOrder.toSet()).toList()..sort();
    return List.unmodifiable([...groupOrder, ...remaining]);
  }

  List<RegisteredBookSource> get displayedSources =>
      List.unmodifiable(visibleSources.take(displayLimit));

  bool get allVisibleSelected {
    final ids = visibleSources.map((source) => source.id).toSet();
    return ids.isNotEmpty && selectedSourceIds.containsAll(ids);
  }

  BookSourceManagementState copyWith({
    List<RegisteredBookSource>? sources,
    List<String>? groupOrder,
    bool? loading,
    String? query,
    BookSourceManagementFilter? filter,
    Object? selectedGroup = _unchanged,
    int? displayLimit,
    bool? selectionMode,
    Set<String>? selectedSourceIds,
    Object? healthProgress = _unchanged,
    Object? mutation = _unchanged,
    Object? failure = _unchanged,
  }) {
    final keepsSources = sources == null;
    final keepsVisibleSources =
        keepsSources &&
        query == null &&
        filter == null &&
        identical(selectedGroup, _unchanged);
    return BookSourceManagementState._(
      keepsVisibleSources ? _visibleSourcesCache : _LazyValue(),
      keepsSources && groupOrder == null ? _availableGroupsCache : _LazyValue(),
      sources: keepsSources ? this.sources : List.unmodifiable(sources),
      groupOrder: groupOrder == null
          ? this.groupOrder
          : List.unmodifiable(groupOrder),
      loading: loading ?? this.loading,
      query: query ?? this.query,
      filter: filter ?? this.filter,
      selectedGroup: identical(selectedGroup, _unchanged)
          ? this.selectedGroup
          : selectedGroup as String?,
      displayLimit: displayLimit ?? this.displayLimit,
      selectionMode: selectionMode ?? this.selectionMode,
      selectedSourceIds: selectedSourceIds == null
          ? this.selectedSourceIds
          : Set.unmodifiable(selectedSourceIds),
      healthProgress: identical(healthProgress, _unchanged)
          ? this.healthProgress
          : healthProgress as BookSourceHealthProgress?,
      mutation: identical(mutation, _unchanged)
          ? this.mutation
          : mutation as BookSourceManagementMutation?,
      failure: identical(failure, _unchanged) ? this.failure : failure,
      sourcesRevision: sources == null ? sourcesRevision : sourcesRevision + 1,
    );
  }
}

const _unchanged = Object();

class _LazyValue<T> {
  T? _value;

  T getOrCreate(T Function() create) => _value ??= create();
}
