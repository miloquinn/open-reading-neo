import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_clock.dart';
import 'package:xxread/services/sync/sync_engine.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  late Database firstDb;
  late Database secondDb;
  late Directory databaseDirectory;

  setUp(() async {
    sqfliteFfiInit();
    databaseDirectory = await Directory.systemTemp.createTemp('sync-engine-');
    firstDb = await databaseFactoryFfi.openDatabase(
      '${databaseDirectory.path}/first.db',
    );
    secondDb = await databaseFactoryFfi.openDatabase(
      '${databaseDirectory.path}/second.db',
    );
    await WebDavSyncSchemaMigration.migrate(firstDb);
    await WebDavSyncSchemaMigration.migrate(secondDb);
  });

  tearDown(() async {
    await firstDb.close();
    await secondDb.close();
    await databaseDirectory.delete(recursive: true);
  });

  test(
    'metadata engine shares HLC batches through provider-neutral storage',
    () async {
      final storage = MemorySyncStorage(spaceKey: 'shared-space');
      final firstStore = SyncChangeStore(database: () async => firstDb);
      final secondStore = SyncChangeStore(database: () async => secondDb);
      final firstAdapter = _ProgressAdapter(firstStore, localValue: 0.42);
      final secondAdapter = _ProgressAdapter(secondStore);

      await SyncEngine(
        storage: storage,
        scope: const WebDavSyncScope(),
        changeStore: firstStore,
        adapters: MetadataSyncAdapters(
          store: firstStore,
          registeredAdapters: [firstAdapter],
        ),
      ).run();
      final result = await SyncEngine(
        storage: storage,
        scope: const WebDavSyncScope(),
        changeStore: secondStore,
        adapters: MetadataSyncAdapters(
          store: secondStore,
          registeredAdapters: [secondAdapter],
        ),
      ).run();

      expect(result.downloaded, 1);
      expect(secondAdapter.appliedValue, 0.42);
      final devices = await storage.list(SyncPath('sync/metadata/devices'));
      expect(devices.prefixes, isNotEmpty);
      final deviceObjects = await storage.list(devices.prefixes.first);
      expect(
        deviceObjects.objects.map((object) => object.path.value),
        contains(contains('/head.json')),
      );
      expect(
        (await storage.readText(SyncPath('format.json'))).text,
        contains('open-reading-sync'),
      );
    },
  );

  test('new engine leaves legacy protocol objects untouched', () async {
    final storage = MemorySyncStorage();
    final bytes = [1, 2, 3];
    for (final legacy in const [
      'v1/space.json',
      'v2/current.txt',
      'v3/head.json',
    ]) {
      await storage.create(
        SyncPath(legacy),
        Stream.value(bytes),
        length: bytes.length,
        contentType: 'application/octet-stream',
      );
    }
    final store = SyncChangeStore(database: () async => firstDb);
    await SyncEngine(
      storage: storage,
      scope: const WebDavSyncScope(),
      changeStore: store,
      adapters: MetadataSyncAdapters(
        store: store,
        registeredAdapters: [_ProgressAdapter(store)],
      ),
    ).run();

    for (final legacy in const [
      'v1/space.json',
      'v2/current.txt',
      'v3/head.json',
    ]) {
      expect((await storage.stat(SyncPath(legacy)))?.length, bytes.length);
    }
  });
}

final class _ProgressAdapter implements MetadataSyncAdapter {
  _ProgressAdapter(this.store, {this.localValue});

  final SyncChangeStore store;
  final double? localValue;
  double? appliedValue;

  @override
  String get dataset => 'progress';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    if (localValue == null) return;
    await store.recordLocal(
      dataset: dataset,
      recordId: 'book-1',
      entityKey: 'book-1',
      payload: {'reading_progress': localValue},
      deleted: false,
      clock: clock,
    );
  }

  @override
  Future<void> validate(SyncOperation operation) async {}

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    appliedValue = (operation.payload?['reading_progress'] as num?)?.toDouble();
    return true;
  }
}
