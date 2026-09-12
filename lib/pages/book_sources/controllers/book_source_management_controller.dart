import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../book_sources/dedupe/book_source_dedupe_engine.dart';
import '../../../book_sources/dedupe/book_source_dedupe_models.dart';
import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_client.dart';
import '../../../book_sources/services/book_source_health_check_service.dart';
import '../../../book_sources/services/book_source_registry.dart';
import '../../../book_sources/source_engine/source_health_checker.dart';

part 'book_source_management_state.dart';

enum BookSourceManagementFilter {
  all,
  favorites,
  enabled,
  disabled,
  runnable,
  pending,
  requiresLogin,
}

enum BookSourceManagementMutation { enable, refresh, remove, health }

enum _BookSourcePreferenceField { enabled, favorite }

typedef _BookSourcePreferenceKey = ({
  String sourceId,
  _BookSourcePreferenceField field,
});

@immutable
class BookSourceInstalledDedupeResult {
  const BookSourceInstalledDedupeResult({
    required this.result,
    required this.sourcesByIndex,
  });

  final BookSourceDedupeResult result;
  final Map<int, RegisteredBookSource> sourcesByIndex;
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

List<String> bookSourceGroups(RegisteredBookSource source) => source.groups;

/// Whether this source declares its own login flow (a reading-source-style
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
  int _organizationRevision = 0;
  int _mutationRevision = 0;
  int _healthRevision = 0;
  int _nextPreferenceRevision = 0;
  final Map<_BookSourcePreferenceKey, int> _preferenceRevisions = {};
  final Map<_BookSourcePreferenceKey, int> _settledPreferenceRevisions = {};
  final Map<_BookSourcePreferenceKey, bool> _pendingPreferenceValues = {};
  final Map<_BookSourcePreferenceKey, bool> _confirmedPreferenceValues = {};
  Timer? _healthProgressTimer;
  BookSourceHealthProgress? _pendingHealthProgress;

  BookSourceManagementState get state => _state;
  BookSourceRegistry get registry => _registry;

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
      final groups = await _registry.loadGroups();
      if (!_isCurrentLoad(revision)) return;
      _emit(
        _state.copyWith(
          sources: sources,
          groupOrder: groups,
          selectedGroup: groups.contains(_state.selectedGroup)
              ? _state.selectedGroup
              : null,
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

  /// Refreshes local organization without cancelling checks or resetting selection.
  Future<void> reloadOrganization() async {
    final revision = ++_organizationRevision;
    try {
      final sources = await _registry.loadInBackground();
      final groups = await _registry.loadGroups();
      if (_disposed || revision != _organizationRevision) return;
      final organizationById = {
        for (final source in sources) source.id: source,
      };
      _emit(
        _state.copyWith(
          sources: [
            for (final current in _state.sources)
              if (organizationById[current.id] case final updated?)
                current.copyWith(
                  isFavorite: updated.isFavorite,
                  groups: updated.groups,
                )
              else
                current,
          ],
          groupOrder: groups,
          selectedGroup: groups.contains(_state.selectedGroup)
              ? _state.selectedGroup
              : null,
          failure: null,
        ),
      );
    } on Object catch (error) {
      if (_disposed || revision != _organizationRevision) return;
      _emit(_state.copyWith(failure: error));
      rethrow;
    }
  }

  Future<void> setSourceFavorite(RegisteredBookSource source) async {
    final current = _sourceWithId(source.id);
    if (current == null) return;
    final favorite = !current.isFavorite;
    await _persistSourcePreference(
      sourceId: current.id,
      field: _BookSourcePreferenceField.favorite,
      value: favorite,
      operation: () => _registry.setFavorite(current.id, favorite),
    );
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
    final current = _sourceWithId(source.id);
    if (current == null || (enabled && !_canEnable(current))) return;
    await _persistSourcePreference(
      sourceId: current.id,
      field: _BookSourcePreferenceField.enabled,
      value: enabled,
      operation: () => _registry.setEnabled(current.id, enabled),
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
      refreshGroups: true,
    );
  }

  /// Removes an explicit result-page selection without changing the selection
  /// owned by the management page.
  Future<void> removeSources(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    final applied = await _runMutation(
      BookSourceManagementMutation.remove,
      () => _registry.removeAll(selected),
      refreshGroups: true,
    );
    if (!applied) return;
    final remainingIds = _state.sources.map((source) => source.id).toSet();
    _emit(
      _state.copyWith(
        selectedSourceIds: _state.selectedSourceIds.intersection(remainingIds),
      ),
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
      final groups = await _registry.loadGroups();
      if (!_isCurrentMutation(revision)) return;
      _emit(
        _state.copyWith(
          sources: sources,
          groupOrder: groups,
          selectedGroup: groups.contains(_state.selectedGroup)
              ? _state.selectedGroup
              : null,
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
          _queueHealthProgress(
            BookSourceHealthProgress(completed: completed, total: total),
            revision,
          );
        },
      );
      if (!_isCurrentHealth(revision)) return const [];
      _clearPendingHealthProgress();
      _emit(
        _state.copyWith(
          sources: updated.isEmpty ? null : _mergedHealthSources(updated),
          mutation: null,
          healthProgress: null,
        ),
      );
      return updated;
    } on Object catch (error) {
      if (!_isCurrentHealth(revision)) return const [];
      _clearPendingHealthProgress();
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
      _emit(
        _state.copyWith(
          sources: _mergedHealthSources([updated]),
          mutation: null,
        ),
      );
      return updated;
    } on Object catch (error) {
      if (!_isCurrentHealth(revision)) return null;
      _emit(_state.copyWith(mutation: null, failure: error));
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

  Future<BookSourceInstalledDedupeResult> findDuplicateSourcesInBackground({
    BookSourceDedupeMode mode = BookSourceDedupeMode.standard,
    Set<String>? sourceIds,
    Set<String> referencedSourceIds = const {},
  }) async {
    // Candidate deep copies, identity normalization and health inspection all
    // belong to the worker, not the caller's first frame.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_disposed) throw StateError('Source management was closed.');
      final revision = _state.sourcesRevision;
      final prepared = await compute(_prepareAndAnalyzeInstalledSources, (
        sources: _state.sources,
        mode: mode,
        sourceIds: sourceIds,
        referencedSourceIds: referencedSourceIds,
      ));
      if (_disposed) throw StateError('Source management was closed.');
      if (revision == _state.sourcesRevision) {
        return _resolveDedupeResult(prepared);
      }
    }
    throw StateError(
      'Sources changed while checking duplicates. Please retry.',
    );
  }

  BookSourceInstalledDedupeResult _resolveDedupeResult(
    _InstalledDedupeSnapshot snapshot,
  ) {
    final byId = {for (final source in _state.sources) source.id: source};
    return BookSourceInstalledDedupeResult(
      result: snapshot.result,
      sourcesByIndex: {
        for (final entry in snapshot.sourceIdsByIndex.entries)
          entry.key: byId[entry.value]!,
      },
    );
  }

  /// Applies health evidence without reverting user edits made during a check.
  void mergeExternalHealthResults(List<RegisteredBookSource> checked) {
    final results = {
      for (final source in checked)
        if (source.sourceConfig?['_openReadingHealthCheck'] != null)
          source.id: source,
    };
    if (results.isEmpty) return;
    _emit(
      _state.copyWith(
        sources: [
          for (final source in _state.sources)
            if (results[source.id] case final checked?
                when sameBookSourceHealthCheckConfiguration(source, checked))
              source.copyWith(
                sourceConfig: {
                  ...?source.sourceConfig,
                  '_openReadingHealthCheck':
                      checked.sourceConfig!['_openReadingHealthCheck'],
                },
              )
            else
              source,
        ],
      ),
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

  void mergeExternalSources(List<RegisteredBookSource> sources) {
    _mergeSources(sources);
  }

  bool _canEnable(RegisteredBookSource source) {
    return source.capabilities.isNotEmpty &&
        (source.sourceProtocol == BookSourceProtocolKind.orsp ||
            _additionalProtocolsEnabled);
  }

  Future<bool> _runMutation(
    BookSourceManagementMutation mutation,
    Future<List<RegisteredBookSource>> Function() operation, {
    bool refreshGroups = false,
  }) async {
    _loadRevision++;
    _healthRevision++;
    final revision = ++_mutationRevision;
    _emit(
      _state.copyWith(mutation: mutation, healthProgress: null, failure: null),
    );
    try {
      final sources = await operation();
      if (!_isCurrentMutation(revision)) return false;
      final groups = refreshGroups ? await _registry.loadGroups() : null;
      if (!_isCurrentMutation(revision)) return false;
      _emit(
        _state.copyWith(
          sources: sources,
          groupOrder: groups,
          selectedGroup: groups == null || groups.contains(_state.selectedGroup)
              ? _state.selectedGroup
              : null,
          mutation: null,
        ),
      );
      return true;
    } on Object catch (error) {
      if (!_isCurrentMutation(revision)) return false;
      _emit(_state.copyWith(mutation: null, failure: error));
      rethrow;
    }
  }

  Future<void> _persistSourcePreference({
    required String sourceId,
    required _BookSourcePreferenceField field,
    required bool value,
    required Future<List<RegisteredBookSource>> Function() operation,
  }) async {
    final current = _sourceWithId(sourceId);
    if (current == null) return;
    _loadRevision++;
    _organizationRevision++;
    final key = (sourceId: sourceId, field: field);
    _confirmedPreferenceValues.putIfAbsent(
      key,
      () => _preferenceValue(current, field),
    );
    final revision = ++_nextPreferenceRevision;
    _preferenceRevisions[key] = revision;
    _pendingPreferenceValues[key] = value;
    _emit(
      _state.copyWith(
        sources: _sourcesWithPreference(sourceId, field, value),
        loading: false,
        failure: null,
      ),
    );

    try {
      final saved = await operation();
      if (_disposed || !_preferenceRevisions.containsKey(key)) return;
      final persisted = _sourceWithIdIn(saved, sourceId);
      if (revision > (_settledPreferenceRevisions[key] ?? 0)) {
        _settledPreferenceRevisions[key] = revision;
        _confirmedPreferenceValues[key] = persisted == null
            ? value
            : _preferenceValue(persisted, field);
      }
      if (_preferenceRevisions[key] != revision) return;
      final confirmed = _confirmedPreferenceValues.remove(key)!;
      _preferenceRevisions.remove(key);
      _pendingPreferenceValues.remove(key);
      _emit(
        _state.copyWith(
          sources: _sourcesWithPreference(sourceId, field, confirmed),
        ),
      );
    } on Object catch (error) {
      if (!_disposed && _preferenceRevisions[key] == revision) {
        _settledPreferenceRevisions[key] = revision;
        final confirmed = _confirmedPreferenceValues.remove(key)!;
        _preferenceRevisions.remove(key);
        _pendingPreferenceValues.remove(key);
        _emit(
          _state.copyWith(
            sources: _sourcesWithPreference(sourceId, field, confirmed),
            failure: error,
          ),
        );
      }
      rethrow;
    }
  }

  RegisteredBookSource? _sourceWithId(String id) =>
      _sourceWithIdIn(_state.sources, id);

  RegisteredBookSource? _sourceWithIdIn(
    List<RegisteredBookSource> sources,
    String id,
  ) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  bool _preferenceValue(
    RegisteredBookSource source,
    _BookSourcePreferenceField field,
  ) => switch (field) {
    _BookSourcePreferenceField.enabled => source.enabled,
    _BookSourcePreferenceField.favorite => source.isFavorite,
  };

  List<RegisteredBookSource> _sourcesWithPreference(
    String sourceId,
    _BookSourcePreferenceField field,
    bool value,
  ) => [
    for (final source in _state.sources)
      if (source.id != sourceId)
        source
      else
        switch (field) {
          _BookSourcePreferenceField.enabled => source.copyWith(enabled: value),
          _BookSourcePreferenceField.favorite => source.copyWith(
            isFavorite: value,
          ),
        },
  ];

  void _mergeSources(List<RegisteredBookSource> updated) {
    if (updated.isEmpty) return;
    _emit(_state.copyWith(sources: _mergedSources(updated)));
  }

  List<RegisteredBookSource> _mergedSources(
    List<RegisteredBookSource> updated,
  ) {
    if (updated.isEmpty) return _state.sources;
    final byId = {for (final source in updated) source.id: source};
    return [for (final source in _state.sources) byId[source.id] ?? source];
  }

  List<RegisteredBookSource> _mergedHealthSources(
    List<RegisteredBookSource> updated,
  ) {
    final currentById = {
      for (final source in _state.sources) source.id: source,
    };
    return _mergedSources([
      for (final source in updated)
        if (currentById[source.id] case final current?)
          source.copyWith(
            isFavorite: current.isFavorite,
            groups: current.groups,
          )
        else
          source,
    ]);
  }

  void _resetView(BookSourceManagementState state) {
    _emit(state.copyWith(displayLimit: initialDisplayLimit));
  }

  bool _isCurrentLoad(int revision) => !_disposed && revision == _loadRevision;
  bool _isCurrentMutation(int revision) =>
      !_disposed && revision == _mutationRevision;
  bool _isCurrentHealth(int revision) =>
      !_disposed && revision == _healthRevision;

  void _queueHealthProgress(BookSourceHealthProgress progress, int revision) {
    if (_healthProgressTimer == null) {
      _emit(_state.copyWith(healthProgress: progress));
      _healthProgressTimer = Timer(const Duration(milliseconds: 100), () {
        _healthProgressTimer = null;
        final pending = _pendingHealthProgress;
        _pendingHealthProgress = null;
        if (pending != null && _isCurrentHealth(revision)) {
          _emit(_state.copyWith(healthProgress: pending));
        }
      });
      return;
    }
    _pendingHealthProgress = progress;
  }

  void _clearPendingHealthProgress() {
    _healthProgressTimer?.cancel();
    _healthProgressTimer = null;
    _pendingHealthProgress = null;
  }

  void _emit(BookSourceManagementState state) {
    if (_disposed) return;
    _state =
        _pendingPreferenceValues.isEmpty ||
            identical(state.sources, _state.sources)
        ? state
        : state.copyWith(
            sources: [
              for (final source in state.sources)
                _sourceWithPendingPreferences(source),
            ],
          );
    notifyListeners();
  }

  RegisteredBookSource _sourceWithPendingPreferences(
    RegisteredBookSource source,
  ) {
    final enabled =
        _pendingPreferenceValues[(
          sourceId: source.id,
          field: _BookSourcePreferenceField.enabled,
        )];
    final favorite =
        _pendingPreferenceValues[(
          sourceId: source.id,
          field: _BookSourcePreferenceField.favorite,
        )];
    if ((enabled == null || enabled == source.enabled) &&
        (favorite == null || favorite == source.isFavorite)) {
      return source;
    }
    return source.copyWith(enabled: enabled, isFavorite: favorite);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadRevision++;
    _mutationRevision++;
    _healthRevision++;
    _preferenceRevisions.clear();
    _settledPreferenceRevisions.clear();
    _pendingPreferenceValues.clear();
    _confirmedPreferenceValues.clear();
    _clearPendingHealthProgress();
    if (_ownsClient) _client?.close();
    super.dispose();
  }
}

typedef _InstalledDedupeSnapshot = ({
  BookSourceDedupeResult result,
  Map<int, String> sourceIdsByIndex,
});

_InstalledDedupeSnapshot _prepareAndAnalyzeInstalledSources(
  ({
    List<RegisteredBookSource> sources,
    BookSourceDedupeMode mode,
    Set<String>? sourceIds,
    Set<String> referencedSourceIds,
  })
  request,
) {
  final candidates = <BookSourceDedupeCandidate>[];
  final ids = <int, String>{};
  for (final source in request.sources) {
    if (source.sourceProtocol != BookSourceProtocolKind.readingSource ||
        (request.sourceIds != null &&
            !request.sourceIds!.contains(source.id))) {
      continue;
    }
    final raw = source.sourceConfig;
    if (raw == null || '${raw['bookSourceUrl'] ?? ''}'.trim().isEmpty) continue;
    final index = candidates.length;
    ids[index] = source.id;
    candidates.add(
      BookSourceDedupeCandidate(
        index: index,
        rawConfig: {...raw, 'enabled': source.enabled},
        installedSourceId: source.id,
        isReferenced: request.referencedSourceIds.contains(source.id),
        isHealthy: sourceHealthCheckResultOf(source)?.fullyAvailable == true,
        runnableCapabilities: source.capabilities.length,
        compatibilityRank: source.capabilities.isEmpty ? 0 : 1,
      ),
    );
  }
  return (
    result: const BookSourceDedupeEngine().analyze(
      candidates,
      mode: request.mode,
    ),
    sourceIdsByIndex: ids,
  );
}
