import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'health merge preserves concurrent edits and does not revive deletion',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      final original = _source('kept', enabled: true, group: 'old');
      final removed = _source('removed', enabled: true, group: 'old');
      await registry.upsertAll([original, removed]);
      final staleChecked = withSourceHealthCheckResult(
        original,
        _healthyResult(),
      );
      final staleRemoved = withSourceHealthCheckResult(
        removed,
        _healthyResult(),
      );

      await registry.upsertAll([
        _source('kept', enabled: false, group: 'edited'),
      ]);
      await registry.setEnabled('kept', false);
      await registry.remove('removed');
      final merge = await registry.mergeHealthCheckResults([
        staleChecked,
        staleRemoved,
      ]);

      final reloaded = await registry.load();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.id, 'kept');
      expect(reloaded.single.enabled, isFalse);
      expect(reloaded.single.sourceConfig?['bookSourceGroup'], 'edited');
      expect(
        sourceHealthCheckResultOf(reloaded.single)?.fullyAvailable,
        isTrue,
      );
      expect(merge.mergedSourceIds, {'kept'});
    },
  );

  test(
    'health merge rejects a result from an older rule configuration',
    () async {
      final storage = _MemoryRegistryStorage();
      final registry = BookSourceRegistry(storage: storage);
      final original = _source(
        'changed',
        enabled: true,
        group: 'group',
        searchRule: 'old-rule',
      );
      await registry.upsert(original);
      final staleChecked = withSourceHealthCheckResult(
        original,
        _healthyResult(),
      );
      await registry.upsert(
        _source(
          'changed',
          enabled: true,
          group: 'group',
          searchRule: 'new-rule',
        ),
      );

      final merge = await registry.mergeHealthCheckResults([staleChecked]);

      expect(merge.mergedSourceIds, isEmpty);
      final current = merge.sources.single;
      expect(current.sourceConfig?['ruleSearch'], {'bookList': 'new-rule'});
      expect(sourceHealthCheckResultOf(current), isNull);
    },
  );
}

SourceHealthCheckResult _healthyResult() => SourceHealthCheckResult(
  checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
  failed: const {},
  checkedAt: DateTime.utc(2026),
  respondTimeMs: 12,
);

RegisteredBookSource _source(
  String id, {
  required bool enabled,
  required String group,
  String searchRule = 'default-rule',
}) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: enabled,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {
    'bookSourceUrl': 'https://$id.example',
    'bookSourceGroup': group,
    'ruleSearch': {'bookList': searchRule},
  },
);

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
