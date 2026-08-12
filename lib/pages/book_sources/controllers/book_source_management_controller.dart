import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_client.dart';
import '../../../book_sources/services/book_source_health_check_service.dart';
import '../../../book_sources/services/book_source_registry.dart';
import '../../../book_sources/source_engine/source_health_checker.dart';

enum BookSourceManagementFilter {
  all,
  enabled,
  disabled,
  runnable,
  pending,
  requiresLogin,
}

enum BookSourceManagementMutation { enable, refresh, remove, health, cleanup }

@immutable
class BookSourceCleanupSweepResult {
  const BookSourceCleanupSweepResult({
    required this.fullyAvailable,
    required this.needsAttention,
  });

  final List<RegisteredBookSource> fullyAvailable;
  final List<RegisteredBookSource> needsAttention;

  static const empty = BookSourceCleanupSweepResult(
    fullyAvailable: [],
    needsAttention: [],
  );
}

@immutable
class BookSourceHealthProgress {
  const BookSourceHealthProgress({
    required this.completed,
    required this.total,
  });

  final int completed;
  final int total;
}

@immutable
class BookSourceManagementState {
  BookSourceManagementState({
    List<RegisteredBookSource> sources = const [],
    this.loading = true,
    this.query = '',
    this.filter = BookSourceManagementFilter.all,
    this.selectedGroup,
    this.displayLimit = 24,
    this.selectionMode = false,
    Set<String> selectedSourceIds = const {},
    this.healthProgress,
    this.mutation,
    this.failure,
    this.sourcesRevision = 0,
  }) : sources = List.unmodifiable(sources),
       selectedSourceIds = Set.unmodifiable(selectedSourceIds);

  final List<RegisteredBookSource> sources;

  /// Bumped only when [sources] is actually replaced with a new list (a
  /// load, a mutation, a health-check merge) — never on an unrelated change
  /// like [query] or [healthProgress] ticking during a batch check.
  /// [visibleSources]/[availableGroups] re-filter every source and parse
  /// each one's group tags with a regex; a library running into the
  /// thousands shouldn't pay for that on every rebuild, so callers memoize
  /// those getters keyed on this revision instead of calling them directly.
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

  List<RegisteredBookSource> get visibleSources {
    final normalizedQuery = query.trim().toLowerCase();
    return List.unmodifiable(
      sources.where((source) {
        final groups = bookSourceGroups(source);
        final matchesState = switch (filter) {
          BookSourceManagementFilter.all => true,
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

  List<String> get availableGroups {
    final groups = <String>{};
    for (final source in sources) {
      groups.addAll(bookSourceGroups(source));
    }
    return List.unmodifiable(groups.toList()..sort());
  }

  List<RegisteredBookSource> get displayedSources =>
      List.unmodifiable(visibleSources.take(displayLimit));

  bool get allVisibleSelected {
    final ids = visibleSources.map((source) => source.id).toSet();
    return ids.isNotEmpty && selectedSourceIds.containsAll(ids);
  }

  BookSourceManagementState copyWith({
    List<RegisteredBookSource>? sources,
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
    return BookSourceManagementState(
      sources: List.unmodifiable(sources ?? this.sources),
      loading: loading ?? this.loading,
      query: query ?? this.query,
      filter: filter ?? this.filter,
      selectedGroup: identical(selectedGroup, _unchanged)
          ? this.selectedGroup
          : selectedGroup as String?,
      displayLimit: displayLimit ?? this.displayLimit,
      selectionMode: selectionMode ?? this.selectionMode,
      selectedSourceIds: Set.unmodifiable(
        selectedSourceIds ?? this.selectedSourceIds,
      ),
      healthProgress: identical(healthProgress, _unchanged)
          ? this.healthProgress
          : healthProgress as BookSourceHealthProgress?,
      mutation: identical(mutation, _unchanged)
          ? this.mutation
          : mutation as BookSourceManagementMutation?,
      failure: identical(failure, _unchanged) ? this.failure : failure,
      // Every call site only ever passes `sources:` when it genuinely has a
      // new list, so bumping whenever it's non-null (rather than hunting
      // down each mutation method individually) can't miss a real change.
      sourcesRevision: sources == null ? sourcesRevision : sourcesRevision + 1,
    );
  }
}

const _unchanged = Object();

List<String> bookSourceGroups(RegisteredBookSource source) {
  final raw = source.sourceConfig?['bookSourceGroup'];
  if (raw is! String || raw.trim().isEmpty) return const [];
  return List.unmodifiable(
    raw
        .split(RegExp(r'[,;，；\n]'))
        .map((group) => group.trim())
        .where((group) => group.isNotEmpty),
  );
}

/// Whether this source declares its own login flow (a Legado-style
/// `loginUrl` script), as opposed to needing no authentication at all.
bool sourceRequiresLogin(RegisteredBookSource source) =>
    source.sourceProtocol == BookSourceProtocolKind.readingSource &&
    '${source.sourceConfig?['loginUrl'] ?? ''}'.trim().isNotEmpty;

class BookSourceManagementController extends ChangeNotifier {
  BookSourceManagementController({
    BookSourceRegistry? registry,
    BookSourceClient? client,
    BookSourceClient Function()? clientFactory,
    BookSourceHealthCheckService? healthService,
    BookSourceHealthCheckService Function(BookSourceRegistry)?
    healthServiceFactory,
    this._additionalProtocolsEnabled = false,
    this.initialDisplayLimit = 24,
    this.displayBatchSize = 24,
  }) : assert(client == null || clientFactory == null),
       assert(healthService == null || healthServiceFactory == null),
       _registry = registry ?? BookSourceRegistry(),
       _client = client,
       _clientFactory = clientFactory ?? BookSourceClient.new,
       _ownsClient = client == null,
       _healthService = healthService,
       _healthServiceFactory =
           healthServiceFactory ??
           ((registry) => BookSourceHealthCheckService(registry: registry)),
       _state = BookSourceManagementState(displayLimit: initialDisplayLimit);

  final BookSourceRegistry _registry;
  BookSourceClient? _client;
  final BookSourceClient Function() _clientFactory;
  final bool _ownsClient;
  BookSourceHealthCheckService? _healthService;
  final BookSourceHealthCheckService Function(BookSourceRegistry)
  _healthServiceFactory;
  final int initialDisplayLimit;
  final int displayBatchSize;

  BookSourceManagementState _state;
  bool _additionalProtocolsEnabled;
  bool _disposed = false;
  int _loadRevision = 0;
  int _mutationRevision = 0;
  int _healthRevision = 0;
  bool _cleanupCancelRequested = false;

  BookSourceManagementState get state => _state;

  BookSourceClient get _sourceClient => _client ??= _clientFactory();
  BookSourceHealthCheckService get _sourceHealthService =>
      _healthService ??= _healthServiceFactory(_registry);

  Future<void> load() async {
    _mutationRevision++;
    _healthRevision++;
    final revision = ++_loadRevision;
    _emit(
      _state.copyWith(
        loading: true,
        mutation: null,
        healthProgress: null,
        failure: null,
      ),
    );
    try {
      final sources = await _registry.loadInBackground();
      if (!_isCurrentLoad(revision)) return;
      _emit(
        _state.copyWith(
          sources: sources,
          loading: false,
          displayLimit: initialDisplayLimit,
          failure: null,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentLoad(revision)) return;
      _emit(_state.copyWith(loading: false, failure: error));
    }
  }

  void setAdditionalProtocolsEnabled(bool enabled) {
    _additionalProtocolsEnabled = enabled;
  }

  void setQuery(String query) => _resetView(_state.copyWith(query: query));

  void setFilter(BookSourceManagementFilter filter) =>
      _resetView(_state.copyWith(filter: filter));

  void setGroup(String? group) =>
      _resetView(_state.copyWith(selectedGroup: group));

  void resetFilters() => _resetView(
    _state.copyWith(
      query: '',
      filter: BookSourceManagementFilter.all,
      selectedGroup: null,
    ),
  );

  void loadMore() {
    final count = _state.visibleSources.length;
    if (_state.displayLimit >= count) return;
    _emit(
      _state.copyWith(
        displayLimit: (_state.displayLimit + displayBatchSize).clamp(0, count),
      ),
    );
  }

  void toggleSelectionMode() {
    _emit(
      _state.copyWith(
        selectionMode: !_state.selectionMode,
        selectedSourceIds: const {},
      ),
    );
  }

  void toggleSourceSelection(String id) {
    final selected = _state.selectedSourceIds.toSet();
    if (!selected.add(id)) selected.remove(id);
    _emit(_state.copyWith(selectedSourceIds: selected));
  }

  void toggleSelectAllVisible() {
    final visibleIds = _state.visibleSources.map((source) => source.id).toSet();
    final allSelected =
        visibleIds.isNotEmpty &&
        _state.selectedSourceIds.containsAll(visibleIds);
    _emit(
      _state.copyWith(selectedSourceIds: allSelected ? const {} : visibleIds),
    );
  }

  Future<void> setSourceEnabled(
    RegisteredBookSource source,
    bool enabled,
  ) async {
    if (enabled && !_canEnable(source)) return;
    await _runMutation(
      BookSourceManagementMutation.enable,
      () => _registry.setEnabled(source.id, enabled),
    );
  }

  Future<void> setSelectedSourcesEnabled(bool enabled) async {
    final ids = _state.sources
        .where(
          (source) =>
              _state.selectedSourceIds.contains(source.id) &&
              (!enabled || _canEnable(source)),
        )
        .map((source) => source.id);
    await _runMutation(
      BookSourceManagementMutation.enable,
      () => _registry.setEnabledAll(ids, enabled),
    );
  }

  Future<bool> refreshSource(RegisteredBookSource source) async {
    try {
      return await _runMutation(
        BookSourceManagementMutation.refresh,
        () => _registry.refresh(source, _sourceClient),
      );
    } on Object {
      return false;
    }
  }

  Future<void> removeSource(String id) async {
    await _runMutation(
      BookSourceManagementMutation.remove,
      () => _registry.remove(id),
    );
  }

  Future<void> removeSelectedSources() async {
    final selected = _state.selectedSourceIds;
    _loadRevision++;
    _healthRevision++;
    final revision = ++_mutationRevision;
    _emit(
      _state.copyWith(
        mutation: BookSourceManagementMutation.remove,
        healthProgress: null,
        failure: null,
      ),
    );
    try {
      final sources = await _registry.removeAll(selected);
      if (!_isCurrentMutation(revision)) return;
      _emit(
        _state.copyWith(
          sources: sources,
          mutation: null,
          selectedSourceIds: const {},
          selectionMode: false,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentMutation(revision)) return;
      _emit(_state.copyWith(mutation: null, failure: error));
      rethrow;
    }
  }

  Future<List<RegisteredBookSource>> checkSelectedSourcesHealth() async {
    final targets = _state.sources
        .where((source) => _state.selectedSourceIds.contains(source.id))
        .toList(growable: false);
    if (targets.isEmpty || _state.healthProgress != null) return const [];
    _loadRevision++;
    _mutationRevision++;
    final revision = ++_healthRevision;
    _emit(
      _state.copyWith(
        mutation: BookSourceManagementMutation.health,
        healthProgress: BookSourceHealthProgress(
          completed: 0,
          total: targets.length,
        ),
        failure: null,
      ),
    );
    try {
      final updated = await _sourceHealthService.checkAll(
        targets,
        onProgress: (completed, total) {
          if (!_isCurrentHealth(revision)) return;
          _emit(
            _state.copyWith(
              healthProgress: BookSourceHealthProgress(
                completed: completed,
                total: total,
              ),
            ),
          );
        },
      );
      if (!_isCurrentHealth(revision)) return const [];
      _mergeSources(updated);
      _emit(_state.copyWith(mutation: null, healthProgress: null));
      return updated;
    } on Object catch (error) {
      if (!_isCurrentHealth(revision)) return const [];
      _emit(
        _state.copyWith(mutation: null, healthProgress: null, failure: error),
      );
      rethrow;
    }
  }

  Future<RegisteredBookSource?> checkSourceHealth(
    RegisteredBookSource source,
  ) async {
    _loadRevision++;
    _mutationRevision++;
    final revision = ++_healthRevision;
    _emit(
      _state.copyWith(
        mutation: BookSourceManagementMutation.health,
        healthProgress: null,
        failure: null,
      ),
    );
    try {
      final updated = await _sourceHealthService.checkOne(source);
      if (!_isCurrentHealth(revision)) return null;
      _mergeSources([updated]);
      _emit(_state.copyWith(mutation: null));
      return updated;
    } on Object catch (error) {
      if (!_isCurrentHealth(revision)) return null;
      _emit(_state.copyWith(mutation: null, failure: error));
      rethrow;
    }
  }

  /// Stops a running [runCleanupSweep] from starting any more checks. Sources
  /// already in flight still finish (bounded by the cleanup sweep's own
  /// timeout), and whatever was checked before this call is still persisted
  /// and included in the result — a library of thousands of sources can take
  /// a long time, so cancelling must never discard progress already made.
  void cancelCleanupSweep() {
    _cleanupCancelRequested = true;
  }

  /// Runs [BookSourceHealthCheckService.checkAllForCleanup] over every
  /// `readingSource`-protocol source and buckets the results, so a caller can
  /// offer to disable whatever didn't come back fully available.
  Future<BookSourceCleanupSweepResult> runCleanupSweep() async {
    final targets = _state.sources
        .where(
          (source) =>
              source.sourceProtocol == BookSourceProtocolKind.readingSource,
        )
        .toList(growable: false);
    if (targets.isEmpty || _state.healthProgress != null) {
      return BookSourceCleanupSweepResult.empty;
    }
    _loadRevision++;
    _mutationRevision++;
    final revision = ++_healthRevision;
    _cleanupCancelRequested = false;
    _emit(
      _state.copyWith(
        mutation: BookSourceManagementMutation.cleanup,
        healthProgress: BookSourceHealthProgress(
          completed: 0,
          total: targets.length,
        ),
        failure: null,
      ),
    );
    try {
      final updated = await _sourceHealthService.checkAllForCleanup(
        targets,
        onProgress: (completed, total) {
          if (!_isCurrentHealth(revision)) return;
          _emit(
            _state.copyWith(
              healthProgress: BookSourceHealthProgress(
                completed: completed,
                total: total,
              ),
            ),
          );
        },
        isCancelled: () =>
            _cleanupCancelRequested || !_isCurrentHealth(revision),
      );
      if (!_isCurrentHealth(revision)) {
        return BookSourceCleanupSweepResult.empty;
      }
      _mergeSources(updated);
      _emit(_state.copyWith(mutation: null, healthProgress: null));
      final fullyAvailable = <RegisteredBookSource>[];
      final needsAttention = <RegisteredBookSource>[];
      for (final source in updated) {
        final result = sourceHealthCheckResultOf(source);
        (result?.fullyAvailable == true ? fullyAvailable : needsAttention).add(
          source,
        );
      }
      return BookSourceCleanupSweepResult(
        fullyAvailable: List.unmodifiable(fullyAvailable),
        needsAttention: List.unmodifiable(needsAttention),
      );
    } on Object catch (error) {
      if (!_isCurrentHealth(revision)) {
        return BookSourceCleanupSweepResult.empty;
      }
      _emit(
        _state.copyWith(mutation: null, healthProgress: null, failure: error),
      );
      rethrow;
    }
  }

  /// Disables every source in [ids] in one write — used to apply a cleanup
  /// sweep's "needs attention" bucket after the user reviews it.
  Future<void> disableSources(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    await _runMutation(
      BookSourceManagementMutation.enable,
      () => _registry.setEnabledAll(idSet, false),
    );
  }

  void replaceSources(List<RegisteredBookSource> sources) {
    _loadRevision++;
    _mutationRevision++;
    _healthRevision++;
    _emit(
      _state.copyWith(
        sources: sources,
        displayLimit: initialDisplayLimit,
        mutation: null,
        healthProgress: null,
        failure: null,
      ),
    );
  }

  bool _canEnable(RegisteredBookSource source) {
    return source.capabilities.isNotEmpty &&
        (source.sourceProtocol == BookSourceProtocolKind.orsp ||
            _additionalProtocolsEnabled);
  }

  Future<bool> _runMutation(
    BookSourceManagementMutation mutation,
    Future<List<RegisteredBookSource>> Function() operation,
  ) async {
    _loadRevision++;
    _healthRevision++;
    final revision = ++_mutationRevision;
    _emit(
      _state.copyWith(mutation: mutation, healthProgress: null, failure: null),
    );
    try {
      final sources = await operation();
      if (!_isCurrentMutation(revision)) return false;
      _emit(_state.copyWith(sources: sources, mutation: null));
      return true;
    } on Object catch (error) {
      if (!_isCurrentMutation(revision)) return false;
      _emit(_state.copyWith(mutation: null, failure: error));
      rethrow;
    }
  }

  void _mergeSources(List<RegisteredBookSource> updated) {
    if (updated.isEmpty) return;
    final byId = {for (final source in updated) source.id: source};
    _emit(
      _state.copyWith(
        sources: [
          for (final source in _state.sources) byId[source.id] ?? source,
        ],
      ),
    );
  }

  void _resetView(BookSourceManagementState state) {
    _emit(state.copyWith(displayLimit: initialDisplayLimit));
  }

  bool _isCurrentLoad(int revision) => !_disposed && revision == _loadRevision;
  bool _isCurrentMutation(int revision) =>
      !_disposed && revision == _mutationRevision;
  bool _isCurrentHealth(int revision) =>
      !_disposed && revision == _healthRevision;

  void _emit(BookSourceManagementState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadRevision++;
    _mutationRevision++;
    _healthRevision++;
    if (_ownsClient) _client?.close();
    super.dispose();
  }
}
