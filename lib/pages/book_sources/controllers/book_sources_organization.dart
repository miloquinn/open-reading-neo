part of 'book_sources_controller.dart';

extension _BookSourcesOrganization on BookSourcesController {
  /// Organization edits must not discard channels, in-flight requests, or the
  /// user's current reading position. Reload content only for runtime changes.
  Future<void> _refreshOrganizationMetadata() async {
    final revision = ++_registryChangeRevision;
    final sourceRevision = _sourceRevision;
    try {
      final sources = await _registry.loadRunnableInBackground();
      if (_closed ||
          revision != _registryChangeRevision ||
          sourceRevision != _sourceRevision) {
        return;
      }
      final comparison = <String, List<RegisteredBookSource>>{
        'previous': _state.sources,
        'current': sources,
      };
      final sameRuntime = sources.length > largeSourceLibraryThreshold
          ? await compute(_sameRuntimeSources, comparison)
          : _sameRuntimeSources(comparison);
      if (_closed ||
          revision != _registryChangeRevision ||
          sourceRevision != _sourceRevision) {
        return;
      }
      if (_state.loadingSources || !sameRuntime) {
        await reload();
        return;
      }
      final index = _buildSectionSourceIndex(sources);
      final ids = index.values
          .expand((items) => items)
          .map((s) => s.id)
          .toSet();
      var group = _state.selectedGroup;
      if (group != null) {
        final groups = await _registry.loadGroups();
        if (_closed ||
            revision != _registryChangeRevision ||
            sourceRevision != _sourceRevision) {
          return;
        }
        if (!groups.contains(group)) group = null;
      }
      final previousState = _state;
      var next = _state.copyWith(
        sources: sources,
        sectionSources: index,
        discoverySources: sources.where((s) => ids.contains(s.id)).toList(),
        selectedGroup: group,
        listGroupsRevision: _state.listGroupsRevision + 1,
      );
      final visibleIds = next.organizedDiscoverySources
          .map((s) => s.id)
          .toSet();
      final selectedRemoved =
          next.selectedSourceId != null &&
          !visibleIds.contains(next.selectedSourceId);
      if (selectedRemoved) {
        next = next.copyWith(selectedSourceId: null, showListDirectory: true);
      }
      if (!next.listLayout &&
          next.requiresScopedDiscovery &&
          next.selectedSourceId == null) {
        next = next.copyWith(
          selectedSourceId: next.organizedDiscoverySources.first.id,
        );
      }
      if (next.expandedListSourceId != null &&
          !visibleIds.contains(next.expandedListSourceId)) {
        next = next.copyWith(expandedListSourceId: null);
      }
      if (next.selectedCategory != null &&
          !next.matchesSelectedSource(next.selectedCategory!.source)) {
        _categoryRevision++;
        next = _resetCategory(next);
      }
      final caches = {...next.caches};
      // Removing a member can filter already-loaded content in place. Only
      // newly included sources require fetching, and only for their sections.
      for (final section in BookSourcesSection.values) {
        final previousIds = previousState
            .scopedSourcesFor(section)
            .map((s) => s.id)
            .toSet();
        if (next
            .scopedSourcesFor(section)
            .any((s) => !previousIds.contains(s.id))) {
          caches.remove(section);
        }
      }
      next = next.copyWith(caches: caches);
      if (!next.listLayout &&
          next.availableSections.isNotEmpty &&
          !next.availableSections.contains(next.section)) {
        _categoryRevision++;
        next = _resetCategory(
          next.copyWith(section: next.availableSections.first),
        );
      }
      _emit(next);
      if (!next.caches.containsKey(next.section)) {
        await loadSection(next.section);
      } else if (next.section == BookSourcesSection.categories &&
          !(next.listLayout && next.showListDirectory)) {
        _autoSelectFirstCategory();
      }
    } catch (_) {
      // The editing surface reports save failures. A failed background read
      // leaves the current content usable; explicit refresh can retry it.
    }
  }

  Future<void> _changeOrganizationScope({
    bool favoritesOnly = false,
    String? group,
    bool force = false,
  }) async {
    if (_closed ||
        (!force &&
            favoritesOnly == _state.favoritesOnly &&
            group == _state.selectedGroup)) {
      return;
    }
    _sectionRevision++;
    _categoryRevision++;
    var next = _resetCategory(
      _state.copyWith(
        favoritesOnly: favoritesOnly,
        selectedGroup: group,
        selectedSourceId: null,
        expandedListSourceId: null,
        showListDirectory: true,
        caches: const {},
        listGroupsRevision: _state.listGroupsRevision + 1,
      ),
    );
    if (!next.listLayout && next.requiresScopedDiscovery) {
      next = next.copyWith(
        selectedSourceId: next.organizedDiscoverySources.first.id,
      );
    }
    if (!next.listLayout &&
        next.availableSections.isNotEmpty &&
        !next.availableSections.contains(next.section)) {
      next = next.copyWith(section: next.availableSections.first);
    }
    _emit(next);
    await loadSection(next.section);
  }
}

// Large compatibility configurations are compared off the UI isolate. Local
// organization changes deliberately do not invalidate runtime response caches.
bool _sameRuntimeSources(Map<String, List<RegisteredBookSource>> input) {
  final previous = {for (final source in input['previous']!) source.id: source};
  final current = input['current']!;
  if (previous.length != current.length) return false;
  String signature(RegisteredBookSource source) => jsonEncode(
    source.toJson()
      ..remove('isFavorite')
      ..remove('groups'),
  );
  return current.every((source) {
    final old = previous[source.id];
    return old != null && signature(old) == signature(source);
  });
}
