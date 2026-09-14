import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/sync/metadata_checkpoint.dart';
import 'package:xxread/services/sync/storage/immutable_object_store.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  late Database db;
  late Directory root;
  late MemorySyncStorage storage;
  late SyncChangeStore store;
  late ImmutableObjectStore objects;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await WebDavSyncSchemaMigration.migrate(db);
    root = await Directory.systemTemp.createTemp('checkpoint-test-');
    storage = MemorySyncStorage();
    store = SyncChangeStore(database: () async => db);
    objects = ImmutableObjectStore(storage, Directory('${root.path}/writer'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  SyncBatch batch(int sequence, int offset) => SyncBatch.create(
    deviceId: 'writer',
    sequence: sequence,
    createdHlc: '$sequence-0-writer',
    operations: List.generate(
      500,
      (i) => SyncOperation(
        dataset: 'settings',
        recordId: '${offset + i}',
        entityKey: '${offset + i}',
        hlc: '$sequence-0-writer',
        deleted: i == 0,
        payload: i == 0 ? null : {'value': i},
      ),
    ),
  );

  test(
    'paged checkpoint restores complete published state including tombstones',
    () async {
      final checkpoint = MetadataCheckpoint(objects, store, 'test');
      await checkpoint.recordPublished(batch(1, 0));
      await checkpoint.recordPublished(batch(128, 500));
      final operations = <SyncOperation>[];
      final cursor = await checkpoint.restore('writer', 0, (
        batch,
        namespace,
      ) async {
        operations.addAll(batch.operations);
      });
      expect(cursor, 128);
      expect(operations, hasLength(1000));
      expect(operations.where((o) => o.deleted), hasLength(2));
      expect(await store.cursorFor('writer', namespace: 'test'), 128);
    },
  );

  test(
    'compaction keeps two verified recovery points and leaves other writers alone',
    () async {
      final checkpoint = MetadataCheckpoint(objects, store, 'test');
      await checkpoint.recordPublished(batch(1, 0));
      await checkpoint.recordPublished(batch(128, 0));
      await checkpoint.recordPublished(batch(256, 0));
      final hash = 'a' * 64;
      final oldLog = SyncPath('changes/writer/000000000001-$hash.json');
      final otherLog = SyncPath('changes/other/000000000001-$hash.json');
      for (final path in [oldLog, otherLog]) {
        await storage.create(
          path,
          Stream.value([1]),
          length: 1,
          contentType: 'application/json',
        );
      }
      await checkpoint.compact('writer');
      expect(await storage.stat(oldLog), isNull);
      expect(await storage.stat(otherLog), isNotNull);
      expect(
        (await storage.list(SyncPath('checkpoints/writer'))).objects,
        hasLength(2),
      );
      final reader = MetadataCheckpoint(
        ImmutableObjectStore(storage, Directory('${root.path}/fresh')),
        store,
        'fresh',
      );
      final operations = <SyncOperation>[];
      expect(
        await reader.restore('writer', 0, (batch, _) async {
          operations.addAll(batch.operations);
        }),
        256,
      );
      expect(operations, hasLength(500));
      expect(operations.where((o) => o.deleted), hasLength(1));
    },
  );

  test(
    'missing checkpoint page never advances the main cursor or applies a partial envelope',
    () async {
      final checkpoint = MetadataCheckpoint(objects, store, 'test');
      await checkpoint.recordPublished(batch(1, 0));
      await checkpoint.recordPublished(batch(128, 500));
      final listing = await storage.list(SyncPath('checkpoints/writer'));
      final index = listing.objects.last;
      final data = jsonDecode((await storage.readText(index.path)).text) as Map;
      final remote = SyncPath(
        'checkpoints/writer/pages/${(data['pages'] as List).last}.json',
      );
      await storage.delete(
        remote,
        expectedVersion: (await storage.stat(remote))!.version,
      );
      final fresh = MetadataCheckpoint(
        ImmutableObjectStore(storage, Directory('${root.path}/reader')),
        store,
        'reader',
      );
      var applied = 0;
      await expectLater(
        fresh.restore('writer', 0, (_, _) async {
          applied++;
        }),
        throwsA(isA<SyncStorageException>()),
      );
      expect(applied, 0);
      expect(await store.cursorFor('writer', namespace: 'reader'), 0);
    },
  );
}
