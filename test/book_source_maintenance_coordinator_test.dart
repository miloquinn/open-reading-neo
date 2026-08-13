import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';

void main() {
  test('keeps progress and review result outside a page lifecycle', () async {
    final service = _HealthService();
    final coordinator = BookSourceMaintenanceCoordinator(service: service);
    final healthy = _source('healthy');
    final broken = _source('broken');

    final run = coordinator.start([healthy, broken]);
    service.onProgress?.call(1, 2);
    expect(coordinator.state.isRunning, isTrue);
    expect(coordinator.state.progress?.completed, 1);

    service.completer.complete([
      _checked(healthy, failed: false),
      _checked(broken, failed: true),
    ]);
    await run;

    expect(coordinator.state.status, BookSourceMaintenanceStatus.completed);
    expect(coordinator.state.result?.fullyAvailable.single.id, 'healthy');
    expect(coordinator.state.result?.needsAttention.single.id, 'broken');
    coordinator.dispose();
  });

  test(
    'cancel requests stop future cleanup work without discarding results',
    () async {
      final service = _HealthService();
      final coordinator = BookSourceMaintenanceCoordinator(service: service);
      final source = _source('source');

      final run = coordinator.start([source]);
      expect(service.isCancelled?.call(), isFalse);
      coordinator.cancel();
      expect(service.isCancelled?.call(), isTrue);
      service.completer.complete([_checked(source, failed: true)]);
      await run;

      expect(coordinator.state.status, BookSourceMaintenanceStatus.cancelled);
      expect(coordinator.state.result?.needsAttention.single.id, source.id);
      coordinator.dispose();
    },
  );
}

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {'bookSourceUrl': 'https://$id.example'},
);

RegisteredBookSource _checked(
  RegisteredBookSource source, {
  required bool failed,
}) => withSourceHealthCheckResult(
  source,
  SourceHealthCheckResult(
    checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
    failed: failed ? const {SourceHealthCapability.search} : const {},
    checkedAt: DateTime.utc(2026, 8, 13),
  ),
);

class _HealthService extends BookSourceHealthCheckService {
  final completer = Completer<List<RegisteredBookSource>>();
  SourceHealthCheckProgress? onProgress;
  bool Function()? isCancelled;

  @override
  Future<List<RegisteredBookSource>> checkAllForCleanup(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    this.onProgress = onProgress;
    this.isCancelled = isCancelled;
    return completer.future;
  }
}
