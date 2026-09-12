import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_management_controller.dart';

void main() {
  test(
    'suppresses stale loads and ignores completion after disposal',
    () async {
      final registry = _Registry();
      final first = Completer<List<RegisteredBookSource>>();
      final second = Completer<List<RegisteredBookSource>>();
      registry.loads.addAll([first, second]);
      final controller = BookSourceManagementController(registry: registry);

      final firstLoad = controller.load();
      final secondLoad = controller.load();
      second.complete([_source('new')]);
      await secondLoad;
      first.complete([_source('old')]);
      await firstLoad;

      expect(controller.state.sources.single.id, 'new');
      final late = Completer<List<RegisteredBookSource>>();
      registry.loads.add(late);
      final lateLoad = controller.load();
      controller.dispose();
      late.complete([_source('late')]);
      await lateLoad;
    },
  );

  test(
    'organization reload retains selection, pagination, and in-flight checks',
    () async {
      final registry = _Registry();
      final health = _HealthService();
      final source = _source(
        'reading',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final controller = BookSourceManagementController(
        registry: registry,
        healthService: health,
        initialDisplayLimit: 1,
        displayBatchSize: 1,
      );
      addTearDown(controller.dispose);
      controller.replaceSources([source, _source('second')]);
      controller.loadMore();
      controller.toggleSelectionMode();
      controller.toggleSourceSelection(source.id);
      final checking = controller.checkSelectedSourcesHealth();
      final progress = controller.state.healthProgress;
      registry.groupOrder = ['Empty folder', 'Useful'];
      registry.loads.add(
        Completer<List<RegisteredBookSource>>()..complete([
          source.copyWith(isFavorite: true, groups: ['Useful']),
          _source('second'),
        ]),
      );

      await controller.reloadOrganization();

      expect(controller.state.availableGroups, ['Empty folder', 'Useful']);
      expect(controller.state.sources.first.isFavorite, isTrue);
      expect(controller.state.sources.first.groups, ['Useful']);
      expect(controller.state.selectionMode, isTrue);
      expect(controller.state.selectedSourceIds, {source.id});
      expect(controller.state.displayLimit, 2);
      expect(controller.state.healthProgress, same(progress));
      expect(controller.state.mutation, BookSourceManagementMutation.health);

      health.all.complete([source]);
      await checking;
      expect(controller.state.healthProgress, isNull);
      expect(controller.state.sources.first.isFavorite, isTrue);
      expect(controller.state.sources.first.groups, ['Useful']);
    },
  );

  test(
    'organization reload resets a deleted group and retains empty group order',
    () async {
      final registry = _Registry()..groupOrder = ['Z empty', 'A empty'];
      final source = _source('source', group: 'Old');
      final controller = BookSourceManagementController(registry: registry);
      addTearDown(controller.dispose);
      controller.replaceSources([source]);
      controller.setGroup('Old');
      registry.loads.add(
        Completer<List<RegisteredBookSource>>()
          ..complete([source.copyWith(groups: [])]),
      );

      await controller.reloadOrganization();

      expect(controller.state.selectedGroup, isNull);
      expect(controller.state.availableGroups, ['Z empty', 'A empty']);
      expect(controller.state.visibleSources, hasLength(1));
      controller.setGroup('Z empty');
      expect(controller.state.visibleSources, isEmpty);
    },
  );

  test(
    'single removal refreshes the group directory in controller state',
    () async {
      final registry = _Registry()..groupOrder = ['Only group'];
      final source = _source('source', group: 'Only group');
      final controller = BookSourceManagementController(registry: registry);
      addTearDown(controller.dispose);
      controller.replaceSources([source]);
      controller.setGroup('Only group');
      registry.mutationResult = const [];
      registry.groupsAfterRemoval = const [];

      await controller.removeSource(source.id);

      expect(controller.state.sources, isEmpty);
      expect(controller.state.availableGroups, isEmpty);
      expect(controller.state.selectedGroup, isNull);
    },
  );

  test(
    'bulk removal refreshes the group directory in controller state',
    () async {
      final registry = _Registry()..groupOrder = ['Only group'];
      final source = _source('source', group: 'Only group');
      final controller = BookSourceManagementController(registry: registry);
      addTearDown(controller.dispose);
      controller.replaceSources([source]);
      controller.setGroup('Only group');
      controller.toggleSelectionMode();
      controller.toggleSourceSelection(source.id);
      registry.mutationResult = const [];
      registry.groupsAfterRemoval = const [];

      await controller.removeSelectedSources();

      expect(controller.state.sources, isEmpty);
      expect(controller.state.availableGroups, isEmpty);
      expect(controller.state.selectedGroup, isNull);
      expect(controller.state.selectionMode, isFalse);
      expect(controller.state.selectedSourceIds, isEmpty);
    },
  );

  test(
    'result-page removal preserves unrelated management selection',
    () async {
      final registry = _Registry()..groupOrder = ['Removed group'];
      final kept = _source('kept');
      final removed = _source('removed', group: 'Removed group');
      final controller = BookSourceManagementController(registry: registry);
      addTearDown(controller.dispose);
      controller.replaceSources([kept, removed]);
      controller.toggleSelectionMode();
      controller.toggleSourceSelection(kept.id);
      controller.toggleSourceSelection(removed.id);
      controller.setGroup('Removed group');
      registry.mutationResult = [kept];
      registry.groupsAfterRemoval = [];

      await controller.removeSources({removed.id});

      expect(registry.lastRemovedIds, {removed.id});
      expect(controller.state.sources.single.id, kept.id);
      expect(controller.state.selectedSourceIds, {kept.id});
      expect(controller.state.selectionMode, isTrue);
      expect(controller.state.selectedGroup, isNull);
      expect(controller.state.availableGroups, isEmpty);
    },
  );

  test('empty result-page removal does not write storage', () async {
    final registry = _Registry();
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([_source('kept')]);

    await controller.removeSources({});

    expect(registry.removeAllCalls, 0);
    expect(controller.state.sources.single.id, 'kept');
  });

  test('favorites filter intersects with groups and search', () {
    final controller = BookSourceManagementController();
    addTearDown(controller.dispose);
    final favorite = _source(
      'favorite',
      name: 'Alpha',
    ).copyWith(isFavorite: true, groups: ['Useful']);
    controller.replaceSources([
      favorite,
      _source('ordinary', name: 'Alpha', group: 'Useful'),
      _source('other', name: 'Beta').copyWith(isFavorite: true),
    ]);
    controller.setFilter(BookSourceManagementFilter.favorites);
    expect(controller.state.visibleSources, hasLength(2));
    controller.setGroup('Useful');
    expect(controller.state.visibleSources, [favorite]);
    controller.setQuery('beta');
    expect(controller.state.visibleSources, isEmpty);
  });

  test('enabled state and filter update before persistence finishes', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source', enabled: false);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);
    controller.setFilter(BookSourceManagementFilter.enabled);

    final saving = controller.setSourceEnabled(source, true);

    expect(controller.state.sources.single.enabled, isTrue);
    expect(controller.state.visibleSources.single.id, source.id);
    registry.enabledWrites.single.completer.complete([
      source.copyWith(enabled: true),
    ]);
    await saving;
    expect(registry.loadCalls, 0);
  });

  test('favorite state and filter update without reloading sources', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source');
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);
    controller.setFilter(BookSourceManagementFilter.favorites);

    final saving = controller.setSourceFavorite(source);

    expect(controller.state.sources.single.isFavorite, isTrue);
    expect(controller.state.visibleSources.single.id, source.id);
    registry.favoriteWrites.single.completer.complete([
      source.copyWith(isFavorite: true),
    ]);
    await saving;
    expect(registry.loadCalls, 0);
  });

  test('failed preference save rolls back its latest intent', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source', enabled: false);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);

    final error = StateError('save failed');
    final saving = controller.setSourceEnabled(source, true);
    expect(controller.state.sources.single.enabled, isTrue);
    registry.enabledWrites.single.completer.completeError(error);

    await expectLater(saving, throwsA(same(error)));
    expect(controller.state.sources.single.enabled, isFalse);
    expect(controller.state.failure, same(error));
  });

  test('newer preference intent survives stale completion and rolls back '
      'to the last confirmed value', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source', enabled: false);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);

    final enable = controller.setSourceEnabled(source, true);
    final disable = controller.setSourceEnabled(source, false);
    expect(controller.state.sources.single.enabled, isFalse);

    registry.enabledWrites.first.completer.complete([
      source.copyWith(enabled: true),
    ]);
    await enable;
    expect(controller.state.sources.single.enabled, isFalse);

    final error = StateError('newest save failed');
    registry.enabledWrites.last.completer.completeError(error);
    await expectLater(disable, throwsA(same(error)));
    expect(controller.state.sources.single.enabled, isTrue);
  });

  test('preference completions merge only their source and field', () async {
    final registry = _Registry()..delayPreferences = true;
    final first = _source('first', enabled: false);
    final second = _source('second', enabled: false);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([first, second]);

    final enabling = controller.setSourceEnabled(first, true);
    final favoriting = controller.setSourceFavorite(first);
    final enablingSecond = controller.setSourceEnabled(second, true);
    expect(controller.state.sources[0].enabled, isTrue);
    expect(controller.state.sources[0].isFavorite, isTrue);
    expect(controller.state.sources[1].enabled, isTrue);

    registry.favoriteWrites.single.completer.complete([
      first.copyWith(isFavorite: true),
      second,
    ]);
    await favoriting;
    expect(controller.state.sources[0].enabled, isTrue);
    expect(controller.state.sources[1].enabled, isTrue);

    registry.enabledWrites.first.completer.complete([
      first.copyWith(enabled: true),
      second,
    ]);
    await enabling;
    expect(controller.state.sources[0].isFavorite, isTrue);
    expect(controller.state.sources[1].enabled, isTrue);

    registry.enabledWrites.last.completer.complete([
      first,
      second.copyWith(enabled: true),
    ]);
    await enablingSecond;
    expect(controller.state.sources[0].enabled, isTrue);
    expect(controller.state.sources[0].isFavorite, isTrue);
    expect(controller.state.sources[1].enabled, isTrue);
  });

  test('preference save invalidates an older organization reload', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source');
    final staleReload = Completer<List<RegisteredBookSource>>();
    registry.loads.add(staleReload);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);

    final reloading = controller.reloadOrganization();
    final favoriting = controller.setSourceFavorite(source);
    registry.favoriteWrites.single.completer.complete([
      source.copyWith(isFavorite: true),
    ]);
    await favoriting;
    staleReload.complete([source]);
    await reloading;

    expect(controller.state.sources.single.isFavorite, isTrue);
  });

  test('an old completion cannot match a later preference revision', () async {
    final registry = _Registry()..delayPreferences = true;
    final source = _source('source', enabled: false);
    final controller = BookSourceManagementController(registry: registry);
    addTearDown(controller.dispose);
    controller.replaceSources([source]);

    final first = controller.setSourceEnabled(source, true);
    final second = controller.setSourceEnabled(source, false);
    registry.enabledWrites[1].completer.complete([
      source.copyWith(enabled: false),
    ]);
    await second;
    final third = controller.setSourceEnabled(source, true);

    registry.enabledWrites[0].completer.complete([
      source.copyWith(enabled: true),
    ]);
    await first;
    expect(controller.state.sources.single.enabled, isTrue);

    final error = StateError('latest save failed');
    registry.enabledWrites[2].completer.completeError(error);
    await expectLater(third, throwsA(same(error)));
    expect(controller.state.sources.single.enabled, isFalse);
  });

  test('filters groups and advances the display limit immutably', () {
    final controller = BookSourceManagementController(
      initialDisplayLimit: 1,
      displayBatchSize: 1,
    );
    final enabled = _source('enabled', name: 'Alpha', group: 'News, Featured');
    final disabled = _source(
      'disabled',
      name: 'Beta',
      enabled: false,
      group: 'Archive',
    );
    controller.replaceSources([enabled, disabled]);

    final initialState = controller.state;
    final initialVisible = initialState.visibleSources;
    final initialGroups = initialState.availableGroups;
    expect(initialGroups, ['Archive', 'Featured', 'News']);
    expect(initialState.displayedSources, [enabled]);
    controller.loadMore();
    expect(controller.state.sources, same(initialState.sources));
    expect(
      controller.state.selectedSourceIds,
      same(initialState.selectedSourceIds),
    );
    expect(controller.state.visibleSources, same(initialVisible));
    expect(controller.state.availableGroups, same(initialGroups));
    expect(controller.state.displayedSources, [enabled, disabled]);
    controller.setFilter(BookSourceManagementFilter.disabled);
    expect(controller.state.visibleSources, isNot(same(initialVisible)));
    expect(controller.state.availableGroups, same(initialGroups));
    expect(controller.state.visibleSources, [disabled]);
    expect(controller.state.displayLimit, 1);
    controller.setFilter(BookSourceManagementFilter.all);
    controller.setGroup('Featured');
    expect(controller.state.visibleSources, [enabled]);
    controller.setGroup(null);
    controller.setQuery('archive');
    expect(controller.state.visibleSources, [disabled]);
    expect(
      () => controller.state.selectedSourceIds.add('x'),
      throwsUnsupportedError,
    );
    expect(() => controller.state.sources.add(enabled), throwsUnsupportedError);

    final filtered = controller.state.visibleSources;
    final groups = controller.state.availableGroups;
    controller.replaceSources([enabled]);
    expect(controller.state.visibleSources, isNot(same(filtered)));
    expect(controller.state.availableGroups, isNot(same(groups)));
    controller.dispose();
  });

  test('the requires-login filter isolates sources with a login script', () {
    final controller = BookSourceManagementController();
    final needsLogin = _source(
      'needs-login',
      protocol: BookSourceProtocolKind.readingSource,
      loginUrl: 'function login() {}',
    );
    final noLogin = _source(
      'no-login',
      protocol: BookSourceProtocolKind.readingSource,
    );
    final orspSource = _source('orsp');
    controller.replaceSources([needsLogin, noLogin, orspSource]);

    controller.setFilter(BookSourceManagementFilter.requiresLogin);

    expect(controller.state.visibleSources, [needsLogin]);
    controller.dispose();
  });

  test(
    'duplicate scan ignores ORSP and keeps same-site variants for review',
    () async {
      final controller = BookSourceManagementController();
      final canonicalOld = _source(
        'canonical-old',
        protocol: BookSourceProtocolKind.readingSource,
        sourceUrl: 'https://EXAMPLE.com:443/?utm_source=list',
      );
      final canonicalNew = _source(
        'canonical-new',
        protocol: BookSourceProtocolKind.readingSource,
        sourceUrl: 'https://example.com',
      );
      final otherPath = _source(
        'other-path',
        protocol: BookSourceProtocolKind.readingSource,
        sourceUrl: 'https://example.com/catalog',
      );
      controller.replaceSources([
        canonicalOld,
        canonicalNew,
        otherPath,
        _source('orsp'),
      ]);

      final standard = await controller.findDuplicateSourcesInBackground();
      expect(standard.result.groups, hasLength(1));
      expect(
        standard.result.groups.single.confidence,
        BookSourceDedupeConfidence.canonical,
      );
      expect(standard.sourcesByIndex.values, hasLength(3));

      final site = await controller.findDuplicateSourcesInBackground(
        mode: BookSourceDedupeMode.siteReview,
      );
      expect(site.result.groups, hasLength(1));
      expect(
        site.result.groups.single.confidence,
        BookSourceDedupeConfidence.sameSite,
      );
      expect(site.result.groups.single.defaultSelectedIndices, hasLength(3));

      expect(
        standard.sourcesByIndex.keys,
        standard.result.candidates.map((candidate) => candidate.index),
      );
      controller.dispose();
    },
  );

  test(
    'selection and bulk enable enforce additional-protocol restrictions',
    () async {
      final registry = _Registry();
      final controller = BookSourceManagementController(registry: registry);
      final orsp = _source('orsp');
      final additional = _source(
        'additional',
        protocol: BookSourceProtocolKind.readingSource,
      );
      registry.mutationResult = [orsp, additional];
      controller.replaceSources([orsp, additional]);
      controller.toggleSelectionMode();
      controller.toggleSelectAllVisible();

      expect(controller.state.allVisibleSelected, isTrue);
      await controller.setSelectedSourcesEnabled(true);
      expect(registry.lastEnabledIds, {'orsp'});
      controller.setAdditionalProtocolsEnabled(true);
      await controller.setSelectedSourcesEnabled(true);
      expect(registry.lastEnabledIds, {'orsp', 'additional'});
      controller.toggleSelectAllVisible();
      expect(controller.state.selectedSourceIds, isEmpty);
      controller.dispose();
    },
  );

  test(
    'merges health results and suppresses late progress after disposal',
    () async {
      final source = _source(
        'health',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final health = _HealthService();
      final controller = BookSourceManagementController(healthService: health);
      controller.replaceSources([source]);
      controller.toggleSelectionMode();
      controller.toggleSourceSelection(source.id);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final check = controller.checkSelectedSourcesHealth();
      health.onProgress?.call(1, 1);
      expect(controller.state.healthProgress?.completed, 1);
      for (var completed = 2; completed <= 100; completed++) {
        health.onProgress?.call(completed, 100);
      }
      expect(notifications, 2);
      final updated = source.copyWith(enabled: false);
      health.all.complete([updated]);
      expect(await check, [updated]);
      expect(notifications, 3);
      expect(controller.state.sources.single.enabled, isFalse);
      expect(controller.state.healthProgress, isNull);

      final lateHealth = _HealthService();
      final lateController = BookSourceManagementController(
        healthService: lateHealth,
      );
      lateController.replaceSources([source]);
      lateController.toggleSelectionMode();
      lateController.toggleSourceSelection(source.id);
      final lateCheck = lateController.checkSelectedSourcesHealth();
      lateController.dispose();
      lateHealth.onProgress?.call(1, 1);
      lateHealth.all.complete([updated]);
      expect(await lateCheck, isEmpty);
      controller.dispose();
    },
  );

  test('disableSources turns off exactly the given ids', () async {
    final registry = _Registry();
    final controller = BookSourceManagementController(registry: registry);

    await controller.disableSources(['a', 'b']);

    expect(registry.lastEnabledIds, {'a', 'b'});
  });

  test('disableSources is a no-op for an empty id set', () async {
    final registry = _Registry();
    final controller = BookSourceManagementController(registry: registry);

    await controller.disableSources(const []);

    expect(registry.lastEnabledIds, isEmpty);
  });

  test(
    'owns factory-created clients but leaves injected clients borrowed',
    () async {
      final registry = _Registry();
      final owned = _Client();
      final controller = BookSourceManagementController(
        registry: registry,
        clientFactory: () => owned,
      );
      await controller.refreshSource(_source('owned'));
      controller.dispose();
      expect(owned.closed, isTrue);

      final borrowed = _Client();
      final borrowedController = BookSourceManagementController(
        registry: registry,
        client: borrowed,
      );
      await borrowedController.refreshSource(_source('borrowed'));
      borrowedController.dispose();
      expect(borrowed.closed, isFalse);
    },
  );

  test('a superseded refresh does not report success', () async {
    final registry = _Registry();
    final first = Completer<List<RegisteredBookSource>>();
    final second = Completer<List<RegisteredBookSource>>();
    registry.refreshes.addAll([first, second]);
    final controller = BookSourceManagementController(registry: registry);

    final staleRefresh = controller.refreshSource(_source('stale'));
    final currentRefresh = controller.refreshSource(_source('current'));
    second.complete([_source('current')]);
    expect(await currentRefresh, isTrue);
    first.complete([_source('stale')]);
    expect(await staleRefresh, isFalse);
    expect(controller.state.sources.single.id, 'current');

    controller.dispose();
  });
  test(
    'background dedupe respects scope and prefers shelf references',
    () async {
      final controller = BookSourceManagementController();
      addTearDown(controller.dispose);
      controller.replaceSources([
        _source(
          'shelf',
          protocol: BookSourceProtocolKind.readingSource,
          sourceUrl: 'https://same.example',
        ),
        _source(
          'new',
          protocol: BookSourceProtocolKind.readingSource,
          sourceUrl: 'https://same.example',
        ),
        _source(
          'outside',
          protocol: BookSourceProtocolKind.readingSource,
          sourceUrl: 'https://same.example',
        ),
      ]);
      final analysis = await controller.findDuplicateSourcesInBackground(
        sourceIds: {'shelf', 'new'},
        referencedSourceIds: {'shelf'},
      );
      expect(analysis.result.candidates, hasLength(2));
      expect(
        analysis
            .sourcesByIndex[analysis.result.groups.single.recommendedIndex]!
            .id,
        'shelf',
      );
      expect(analysis.result.candidates.first.isReferenced, isTrue);
    },
  );

  test(
    'background dedupe returns current snapshot after source edits',
    () async {
      final controller = BookSourceManagementController();
      addTearDown(controller.dispose);
      controller.replaceSources([
        for (var i = 0; i < 1000; i++)
          _source(
            'old-$i',
            protocol: BookSourceProtocolKind.readingSource,
            sourceUrl: 'https://same.example',
          ),
      ]);
      final pending = controller.findDuplicateSourcesInBackground();
      controller.replaceSources([
        _source(
          'current',
          protocol: BookSourceProtocolKind.readingSource,
          sourceUrl: 'https://current.example',
        ),
      ]);
      final result = await pending;
      expect(result.sourcesByIndex.values.single.id, 'current');
      expect(result.result.groups, isEmpty);
    },
  );

  test(
    'merging external health evidence preserves edits and removed sources',
    () {
      final controller = BookSourceManagementController();
      addTearDown(controller.dispose);
      final current = _source(
        'kept',
        enabled: false,
        group: 'New group',
        protocol: BookSourceProtocolKind.readingSource,
        sourceUrl: 'https://same.example',
      );
      controller.replaceSources([current]);
      final result = SourceHealthCheckResult(
        checked: {SourceHealthCapability.search},
        failed: {},
        checkedAt: DateTime.utc(2026),
      );
      controller.mergeExternalHealthResults([
        withSourceHealthCheckResult(
          current.copyWith(
            enabled: true,
            sourceConfig: {
              ...current.sourceConfig!,
              'bookSourceGroup': 'Old group',
            },
          ),
          result,
        ),
        withSourceHealthCheckResult(_source('removed'), result),
      ]);
      expect(controller.state.sources, hasLength(1));
      final updated = controller.state.sources.single;
      expect(updated.enabled, isFalse);
      expect(updated.sourceConfig!['bookSourceGroup'], 'New group');
      expect(sourceHealthCheckResultOf(updated)!.checked, {
        SourceHealthCapability.search,
      });
      final edited = current.copyWith(
        sourceConfig: {...current.sourceConfig!, 'searchUrl': '/new-rule'},
      );
      controller.replaceSources([edited]);
      controller.mergeExternalHealthResults([
        withSourceHealthCheckResult(current, result),
      ]);
      expect(
        sourceHealthCheckResultOf(controller.state.sources.single),
        isNull,
      );
      expect(
        controller.state.sources.single.sourceConfig!['searchUrl'],
        '/new-rule',
      );
    },
  );
}

RegisteredBookSource _source(
  String id, {
  String? name,
  bool enabled = true,
  String? group,
  String? loginUrl,
  String? sourceUrl,
  BookSourceProtocolKind protocol = BookSourceProtocolKind.orsp,
}) {
  return RegisteredBookSource(
    id: id,
    name: name ?? id,
    description: '',
    manifestUrl: Uri.parse('https://$id.example/source.json'),
    apiBaseUrl: Uri.parse('https://$id.example/api/'),
    protocolVersion: protocol == BookSourceProtocolKind.orsp
        ? '1.5'
        : 'reading-1',
    languages: const ['en'],
    capabilities: const {'search'},
    enabled: enabled,
    addedAt: DateTime.utc(2026),
    sourceProtocol: protocol,
    sourceConfig: _sourceConfig(protocol, group, loginUrl, sourceUrl),
  );
}

Map<String, dynamic>? _sourceConfig(
  BookSourceProtocolKind protocol,
  String? group,
  String? loginUrl,
  String? sourceUrl,
) {
  if (protocol != BookSourceProtocolKind.readingSource &&
      group == null &&
      loginUrl == null) {
    return null;
  }
  final config = <String, dynamic>{};
  if (group != null) config['bookSourceGroup'] = group;
  if (loginUrl != null) config['loginUrl'] = loginUrl;
  if (sourceUrl != null) config['bookSourceUrl'] = sourceUrl;
  return config;
}

class _Registry extends BookSourceRegistry {
  List<String> groupOrder = const [];
  List<String>? groupsAfterRemoval;

  @override
  Future<List<String>> loadGroups() async => groupOrder;

  final List<Completer<List<RegisteredBookSource>>> loads = [];
  final List<Completer<List<RegisteredBookSource>>> refreshes = [];
  final List<
    ({String id, bool value, Completer<List<RegisteredBookSource>> completer})
  >
  enabledWrites = [];
  final List<
    ({String id, bool value, Completer<List<RegisteredBookSource>> completer})
  >
  favoriteWrites = [];
  bool delayPreferences = false;
  int loadCalls = 0;
  Set<String> lastEnabledIds = const {};
  Set<String> lastRemovedIds = const {};
  int removeAllCalls = 0;
  List<RegisteredBookSource> mutationResult = const [];

  @override
  Future<List<RegisteredBookSource>> loadInBackground() {
    loadCalls++;
    return loads.removeAt(0).future;
  }

  @override
  Future<List<RegisteredBookSource>> setEnabled(String id, bool enabled) {
    if (!delayPreferences) return Future.value(mutationResult);
    final completer = Completer<List<RegisteredBookSource>>();
    enabledWrites.add((id: id, value: enabled, completer: completer));
    return completer.future;
  }

  @override
  Future<List<RegisteredBookSource>> setFavorite(String id, bool value) {
    if (!delayPreferences) return Future.value(mutationResult);
    final completer = Completer<List<RegisteredBookSource>>();
    favoriteWrites.add((id: id, value: value, completer: completer));
    return completer.future;
  }

  @override
  Future<List<RegisteredBookSource>> setEnabledAll(
    Iterable<String> ids,
    bool enabled,
  ) async {
    lastEnabledIds = ids.toSet();
    return mutationResult;
  }

  @override
  Future<List<RegisteredBookSource>> remove(String id) async {
    groupOrder = groupsAfterRemoval ?? groupOrder;
    return mutationResult;
  }

  @override
  Future<List<RegisteredBookSource>> removeAll(Iterable<String> ids) async {
    lastRemovedIds = ids.toSet();
    removeAllCalls++;
    groupOrder = groupsAfterRemoval ?? groupOrder;
    return mutationResult;
  }

  @override
  Future<List<RegisteredBookSource>> refresh(
    RegisteredBookSource source,
    BookSourceClient client,
  ) async => refreshes.isEmpty ? [source] : refreshes.removeAt(0).future;
}

class _HealthService extends BookSourceHealthCheckService {
  final Completer<List<RegisteredBookSource>> all = Completer();
  SourceHealthCheckProgress? onProgress;

  @override
  Future<List<RegisteredBookSource>> checkAll(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
  }) {
    this.onProgress = onProgress;
    return all.future;
  }
}

class _Client extends BookSourceClient {
  bool closed = false;

  @override
  void close({bool force = true}) {
    closed = true;
    super.close(force: force);
  }
}
