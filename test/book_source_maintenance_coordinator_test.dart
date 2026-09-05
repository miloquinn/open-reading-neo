import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'keeps progress and classified review result outside page lifecycle',
    () async {
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(service: service);
      addTearDown(coordinator.dispose);
      final healthy = _source('healthy');
      final broken = _source('broken');

      final run = coordinator.start([healthy, broken]);
      final request = service.requests.single;
      request.completeItem(_checked(healthy));
      request.onProgress?.call(1, 2);
      expect(coordinator.state.progress?.completed, 1);
      final brokenResult = _checked(
        broken,
        failed: const {SourceHealthCapability.content},
      );
      request.completeItem(brokenResult);
      request.completer.complete([_checked(healthy), brokenResult]);
      await run;

      expect(coordinator.state.status, BookSourceMaintenanceStatus.completed);
      expect(coordinator.state.progress?.completed, 2);
      expect(coordinator.state.result?.fullyAvailable.single.id, 'healthy');
      expect(coordinator.state.result?.needsAttention.single.id, 'broken');
      expect(
        coordinator.state.result?.classificationOf('broken'),
        BookSourceMaintenanceClassification.failed,
      );
    },
  );

  test(
    'cancel enters cancelling immediately and resume checks only remaining',
    () async {
      final service = _HealthService();
      final first = _source('first');
      final second = _source('second');
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      await registry.upsertAll([first, second]);
      final coordinator = BookSourceMaintenanceCoordinator(
        service: service,
        registry: registry,
      );
      addTearDown(coordinator.dispose);

      final run = coordinator.begin([first, second]);
      final request = service.requests.single;
      request.completeItem(_checked(first));
      request.onProgress?.call(1, 2);
      coordinator.cancel();

      expect(coordinator.state.status, BookSourceMaintenanceStatus.cancelling);
      expect(coordinator.state.isRunning, isTrue);
      expect(request.isCancelled?.call(), isTrue);
      request.completer.complete([_checked(first)]);
      await run;

      expect(coordinator.state.status, BookSourceMaintenanceStatus.cancelled);
      expect(coordinator.state.progress?.completed, 1);
      expect(coordinator.state.progress?.total, 2);
      expect(coordinator.state.remainingSources.single.id, second.id);
      expect(coordinator.state.canResume, isTrue);

      await registry.applySynced(_source('second', searchRule: 'new-rule'));
      final resume = coordinator.resume();
      await _waitForRequests(service, 2);
      final resumed = service.requests.last;
      expect(resumed.sources.map((source) => source.id), [second.id]);
      expect(resumed.sources.single.sourceConfig?['ruleSearch'], {
        'bookList': 'new-rule',
      });
      resumed.completeItem(_checked(second));
      resumed.completer.complete([_checked(second)]);
      await resume;

      expect(coordinator.state.status, BookSourceMaintenanceStatus.completed);
      expect(coordinator.state.result?.allSources, hasLength(2));
      expect(coordinator.state.remainingSources, isEmpty);
    },
  );

  test('begin while running reuses the active task', () async {
    final service = _HealthService();
    final coordinator = BookSourceMaintenanceCoordinator(service: service);
    addTearDown(coordinator.dispose);

    final first = coordinator.begin([_source('first')]);
    final duplicate = coordinator.begin([_source('other')]);

    expect(identical(first, duplicate), isTrue);
    expect(service.requests, hasLength(1));
    service.requests.single.completer.complete(const []);
    await first;
  });

  test(
    'failure preserves completed items and leaves the rest resumable',
    () async {
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(service: service);
      addTearDown(coordinator.dispose);
      final first = _source('first');
      final second = _source('second');

      final run = coordinator.start([first, second]);
      service.requests.single.completeItem(_checked(first));
      service.requests.single.completer.completeError(
        StateError('save failed'),
      );
      await run;

      expect(coordinator.state.status, BookSourceMaintenanceStatus.failed);
      expect(coordinator.state.result?.allSources.single.id, first.id);
      expect(coordinator.state.remainingSources.single.id, second.id);
      expect(coordinator.state.canResume, isTrue);
    },
  );

  test(
    'retryIssues keeps available results and retries only issue buckets',
    () async {
      final service = _HealthService();
      final available = _source('available');
      final limited = _source('limited');
      final timedOut = _source('timeout');
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      await registry.upsertAll([available, limited, timedOut]);
      final coordinator = BookSourceMaintenanceCoordinator(
        service: service,
        registry: registry,
      );
      addTearDown(coordinator.dispose);

      final run = coordinator.start([available, limited, timedOut]);
      final request = service.requests.single;
      final results = [
        _checked(available),
        _checked(limited, checked: const {SourceHealthCapability.search}),
        _checked(timedOut, timedOut: true),
      ];
      for (final result in results) {
        request.completeItem(result);
      }
      request.completer.complete(results);
      await run;

      final retry = coordinator.retryIssues();
      await _waitForRequests(service, 2);
      final retried = service.requests.last;
      expect(retried.sources.map((source) => source.id).toSet(), {
        limited.id,
        timedOut.id,
      });
      expect(coordinator.state.progress?.completed, 1);
      final repaired = retried.sources.map(_checked).toList();
      for (final result in repaired) {
        retried.completeItem(result);
      }
      retried.completer.complete(repaired);
      await retry;

      expect(coordinator.state.result?.fullyAvailable, hasLength(3));
      expect(coordinator.state.result?.needsAttention, isEmpty);
    },
  );

  test(
    'retry keeps unstarted sources and excludes disabled issue results',
    () async {
      final service = _HealthService();
      final issue = _source('issue');
      final unstarted = _source('unstarted');
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      await registry.upsertAll([issue, unstarted]);
      final coordinator = BookSourceMaintenanceCoordinator(
        service: service,
        registry: registry,
      );
      addTearDown(coordinator.dispose);

      final run = coordinator.start([issue, unstarted]);
      final first = service.requests.single;
      final failed = _checked(
        issue,
        failed: const {SourceHealthCapability.search},
      );
      first.completeItem(failed);
      coordinator.cancel();
      first.completer.complete([failed]);
      await run;
      await registry.setEnabled(issue.id, false);

      final retry = coordinator.retryIssues();
      await _waitForRequests(service, 2);
      final retried = service.requests.last;
      expect(retried.sources.map((source) => source.id), [unstarted.id]);
      retried.completeItem(_checked(unstarted));
      retried.completer.complete([_checked(unstarted)]);
      await retry;

      expect(coordinator.state.result?.assessments, hasLength(2));
      expect(coordinator.state.result?.needsAttention, isEmpty);
    },
  );

  test('resume drops an unstarted source removed from the registry', () async {
    final service = _HealthService();
    final first = _source('first');
    final removed = _source('removed');
    final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    await registry.upsertAll([first, removed]);
    final coordinator = BookSourceMaintenanceCoordinator(
      service: service,
      registry: registry,
    );
    addTearDown(coordinator.dispose);

    final run = coordinator.start([first, removed]);
    final request = service.requests.single;
    request.completeItem(_checked(first));
    coordinator.cancel();
    request.completer.complete([_checked(first)]);
    await run;
    await registry.remove(removed.id);

    await coordinator.resume();

    expect(service.requests, hasLength(1));
    expect(coordinator.state.remainingSources, isEmpty);
    expect(coordinator.state.canResume, isFalse);
    expect(coordinator.state.progress?.total, 2);
    expect(coordinator.state.result?.allSources.single.id, first.id);
  });

  test('a changed configuration result is kept as unchecked', () async {
    final service = _HealthService();
    final source = _source('changed');
    final coordinator = BookSourceMaintenanceCoordinator(service: service);
    addTearDown(coordinator.dispose);

    final run = coordinator.start([source]);
    final request = service.requests.single;
    request.completeItem(_checked(source));
    final current = _source('changed', searchRule: 'new-rule');
    request.onItemError?.call(
      current,
      const SourceHealthCheckConfigurationChangedException('changed'),
      StackTrace.empty,
    );
    request.completer.complete([current]);
    await run;

    expect(
      coordinator.state.result?.classificationOf(source.id),
      BookSourceMaintenanceClassification.unchecked,
    );
  });

  test(
    'a failed health-result write remains resumable with the real service',
    () async {
      final storage = _ToggleFailStorage();
      final registry = BookSourceRegistry(storage: storage);
      final source = _source('persist', capabilities: const {});
      await registry.upsert(source);
      final coordinator = BookSourceMaintenanceCoordinator(
        service: BookSourceHealthCheckService(registry: registry),
        registry: registry,
      );
      addTearDown(coordinator.dispose);
      storage.failWrites = true;

      await coordinator.start([source]);

      expect(coordinator.state.status, BookSourceMaintenanceStatus.failed);
      expect(coordinator.state.canResume, isTrue);
      expect(coordinator.state.remainingSources.single.id, source.id);
      expect(coordinator.state.result?.assessments, hasLength(1));
      expect(sourceHealthCheckResultOf((await registry.load()).single), isNull);

      storage.failWrites = false;
      await coordinator.resume();

      expect(coordinator.state.status, BookSourceMaintenanceStatus.completed);
      expect(coordinator.state.remainingSources, isEmpty);
      expect(
        sourceHealthCheckResultOf((await registry.load()).single),
        isNotNull,
      );
    },
  );

  test(
    'dismissReviewed removes only sources that are actually disabled',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(
        service: service,
        registry: registry,
      );
      addTearDown(coordinator.dispose);
      final disabled = _source('disabled');
      final enabled = _source('enabled');
      await registry.upsertAll([disabled, enabled]);
      await registry.setEnabled(disabled.id, false);

      final run = coordinator.start([disabled, enabled]);
      final request = service.requests.single;
      final results = [
        _checked(disabled, failed: const {SourceHealthCapability.search}),
        _checked(enabled, failed: const {SourceHealthCapability.search}),
      ];
      for (final result in results) {
        request.completeItem(result);
      }
      request.completer.complete(results);
      await run;
      await coordinator.dismissReviewed([disabled.id, enabled.id]);

      expect(coordinator.state.result?.needsAttention.single.id, enabled.id);
      expect(coordinator.state.result?.allSources, hasLength(2));
    },
  );

  test('dismissReviewed cannot write an older review into a new run', () async {
    final service = _HealthService();
    final registry = _DelayedRegistry();
    final coordinator = BookSourceMaintenanceCoordinator(
      service: service,
      registry: registry,
    );
    addTearDown(coordinator.dispose);
    final first = _source('first');
    final firstRun = coordinator.start([first]);
    final firstResult = _checked(
      first,
      failed: const {SourceHealthCapability.search},
    );
    service.requests.single.completeItem(firstResult);
    service.requests.single.completer.complete([firstResult]);
    await firstRun;

    final dismiss = coordinator.dismissReviewed([first.id]);
    final second = _source('second');
    final secondRun = coordinator.start([second]);
    registry.loadCompleter.complete([first.copyWith(enabled: false)]);
    await dismiss;
    final secondResult = _checked(
      second,
      failed: const {SourceHealthCapability.search},
    );
    service.requests.last.completeItem(secondResult);
    service.requests.last.completer.complete([secondResult]);
    await secondRun;

    expect(coordinator.state.result?.reviewedSourceIds, isEmpty);
    expect(coordinator.state.result?.needsAttention.single.id, second.id);
  });

  test(
    'coalesces rapid progress updates before rebuilding listeners',
    () async {
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(service: service);
      addTearDown(coordinator.dispose);
      var notifications = 0;
      coordinator.addListener(() => notifications++);

      final run = coordinator.start([_source('source')]);
      expect(notifications, 1);
      final request = service.requests.single;
      request.onProgress?.call(1, 100);
      for (var completed = 2; completed <= 100; completed++) {
        request.onProgress?.call(completed, 100);
      }

      expect(notifications, 2);
      expect(coordinator.state.progress?.completed, 1);
      request.completer.complete(const []);
      await run;
      expect(notifications, 3);
    },
  );
}

RegisteredBookSource _source(
  String id, {
  String searchRule = 'default-rule',
  Set<String> capabilities = const {'search'},
}) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: capabilities,
  enabled: true,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {
    'bookSourceUrl': 'https://$id.example',
    'ruleSearch': {'bookList': searchRule},
  },
);

Future<void> _waitForRequests(_HealthService service, int count) async {
  for (
    var attempt = 0;
    attempt < 20 && service.requests.length < count;
    attempt++
  ) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(service.requests, hasLength(count));
}

RegisteredBookSource _checked(
  RegisteredBookSource source, {
  Set<SourceHealthCapability> checked =
      SourceHealthCheckResult.fullAvailabilityCapabilities,
  Set<SourceHealthCapability> failed = const {},
  bool timedOut = false,
}) => withSourceHealthCheckResult(
  source,
  SourceHealthCheckResult(
    checked: checked,
    failed: failed,
    checkedAt: DateTime.utc(2026, 8, 13),
    timedOut: timedOut,
  ),
);

class _HealthRequest {
  _HealthRequest({
    required this.sources,
    this.onProgress,
    this.isCancelled,
    this.onItemCompleted,
    this.onItemError,
  });

  final List<RegisteredBookSource> sources;
  final Completer<List<RegisteredBookSource>> completer = Completer();
  final SourceHealthCheckProgress? onProgress;
  final bool Function()? isCancelled;
  final SourceHealthCheckItemCompleted? onItemCompleted;
  final SourceHealthCheckItemError? onItemError;

  void completeItem(RegisteredBookSource source) =>
      onItemCompleted?.call(source);
}

class _HealthService extends BookSourceHealthCheckService {
  final requests = <_HealthRequest>[];

  @override
  Future<List<RegisteredBookSource>> checkAllForCleanup(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
    bool Function()? isCancelled,
    SourceHealthCheckItemCompleted? onItemCompleted,
    SourceHealthCheckItemError? onItemError,
  }) {
    final request = _HealthRequest(
      sources: sources,
      onProgress: onProgress,
      isCancelled: isCancelled,
      onItemCompleted: onItemCompleted,
      onItemError: onItemError,
    );
    requests.add(request);
    return request.completer.future;
  }
}

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}

class _DelayedRegistry extends BookSourceRegistry {
  final loadCompleter = Completer<List<RegisteredBookSource>>();

  @override
  Future<List<RegisteredBookSource>> load() => loadCompleter.future;
}

class _ToggleFailStorage implements BookSourceRegistryStorage {
  String? raw;
  bool failWrites = false;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    if (failWrites) return false;
    raw = value;
    return true;
  }
}
