import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
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

    expect(controller.state.availableGroups, ['Archive', 'Featured', 'News']);
    expect(controller.state.displayedSources, [enabled]);
    controller.loadMore();
    expect(controller.state.displayedSources, [enabled, disabled]);
    controller.setFilter(BookSourceManagementFilter.disabled);
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

      final check = controller.checkSelectedSourcesHealth();
      health.onProgress?.call(1, 1);
      expect(controller.state.healthProgress?.completed, 1);
      final updated = source.copyWith(enabled: false);
      health.all.complete([updated]);
      expect(await check, [updated]);
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

  test(
    'a cleanup sweep buckets sources by fullyAvailable and suppresses late progress after disposal',
    () async {
      final available = _source(
        'fully-available',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final broken = _source(
        'needs-attention',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final health = _HealthService();
      final controller = BookSourceManagementController(healthService: health);
      controller.replaceSources([available, broken]);

      final sweep = controller.runCleanupSweep();
      health.cleanupOnProgress?.call(1, 2);
      expect(controller.state.healthProgress?.completed, 1);
      final availableChecked = withSourceHealthCheckResult(
        available,
        SourceHealthCheckResult(
          checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
          failed: const {},
          checkedAt: DateTime.utc(2026, 8, 12),
        ),
      );
      final brokenChecked = withSourceHealthCheckResult(
        broken,
        SourceHealthCheckResult(
          checked: const {SourceHealthCapability.search},
          failed: const {SourceHealthCapability.search},
          checkedAt: DateTime.utc(2026, 8, 12),
        ),
      );
      health.allForCleanup.complete([availableChecked, brokenChecked]);
      final result = await sweep;

      expect(result.fullyAvailable.single.id, available.id);
      expect(result.needsAttention.single.id, broken.id);
      expect(controller.state.healthProgress, isNull);
      expect(
        controller.state.sources.map((source) => source.enabled),
        everyElement(isTrue),
      );

      final lateHealth = _HealthService();
      final lateController = BookSourceManagementController(
        healthService: lateHealth,
      );
      lateController.replaceSources([broken]);
      final lateSweep = lateController.runCleanupSweep();
      lateController.dispose();
      lateHealth.cleanupOnProgress?.call(1, 1);
      lateHealth.allForCleanup.complete([brokenChecked]);
      final lateResult = await lateSweep;
      expect(lateResult.fullyAvailable, isEmpty);
      expect(lateResult.needsAttention, isEmpty);

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
    'cancelCleanupSweep flags the in-flight sweep as cancelled for the service',
    () async {
      final source = _source(
        'cleanup-cancel',
        protocol: BookSourceProtocolKind.readingSource,
      );
      final health = _HealthService();
      final controller = BookSourceManagementController(healthService: health);
      controller.replaceSources([source]);

      final sweep = controller.runCleanupSweep();
      expect(health.cleanupIsCancelled?.call(), isFalse);
      controller.cancelCleanupSweep();
      expect(health.cleanupIsCancelled?.call(), isTrue);

      health.allForCleanup.complete(const []);
      await sweep;
      controller.dispose();
    },
  );

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
}

RegisteredBookSource _source(
  String id, {
  String? name,
  bool enabled = true,
  String? group,
  String? loginUrl,
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
    sourceConfig: _sourceConfig(protocol, group, loginUrl),
  );
}

Map<String, dynamic>? _sourceConfig(
  BookSourceProtocolKind protocol,
  String? group,
  String? loginUrl,
) {
  if (protocol != BookSourceProtocolKind.readingSource &&
      group == null &&
      loginUrl == null) {
    return null;
  }
  final config = <String, dynamic>{};
  if (group != null) config['bookSourceGroup'] = group;
  if (loginUrl != null) config['loginUrl'] = loginUrl;
  return config;
}

class _Registry extends BookSourceRegistry {
  final List<Completer<List<RegisteredBookSource>>> loads = [];
  final List<Completer<List<RegisteredBookSource>>> refreshes = [];
  Set<String> lastEnabledIds = const {};
  List<RegisteredBookSource> mutationResult = const [];

  @override
  Future<List<RegisteredBookSource>> loadInBackground() {
    return loads.removeAt(0).future;
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
  Future<List<RegisteredBookSource>> refresh(
    RegisteredBookSource source,
    BookSourceClient client,
  ) async => refreshes.isEmpty ? [source] : refreshes.removeAt(0).future;
}

class _HealthService extends BookSourceHealthCheckService {
  final Completer<List<RegisteredBookSource>> all = Completer();
  final Completer<List<RegisteredBookSource>> allForCleanup = Completer();
  SourceHealthCheckProgress? onProgress;
  SourceHealthCheckProgress? cleanupOnProgress;

  @override
  Future<List<RegisteredBookSource>> checkAll(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
  }) {
    this.onProgress = onProgress;
    return all.future;
  }

  bool Function()? cleanupIsCancelled;

  @override
  Future<List<RegisteredBookSource>> checkAllForCleanup(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    cleanupOnProgress = onProgress;
    cleanupIsCancelled = isCancelled;
    return allForCleanup.future;
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
