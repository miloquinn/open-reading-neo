import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_clock.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  late Database database;
  late SyncChangeStore store;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await WebDavSyncSchemaMigration.migrate(database);
    store = SyncChangeStore(database: () async => database);
  });

  tearDown(() => database.close());

  test('remote LWW applies newer HLC and is idempotent', () async {
    final clock = HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000);
    await store.recordLocal(
      dataset: 'progress',
      recordId: 'book-1',
      entityKey: 'book-1',
      payload: const {
        'canonical_locator': {'progression': 0.2},
      },
      deleted: false,
      clock: clock,
    );
    final batch = SyncBatch.create(
      deviceId: 'remote',
      sequence: 1,
      createdHlc: '2000-0000-remote',
      operations: const [
        SyncOperation(
          dataset: 'progress',
          recordId: 'book-1',
          entityKey: 'book-1',
          hlc: '2000-0000-remote',
          deleted: false,
          payload: {
            'canonical_locator': {'progression': 0.1},
          },
        ),
      ],
    );
    var businessApplies = 0;

    expect(
      await store.applyRemoteBatch(
        batch,
        validateWinner: (_) async {},
        applyWinner: (_, _) async {
          businessApplies++;
          return true;
        },
      ),
      1,
    );
    expect(
      await store.applyRemoteBatch(
        batch,
        validateWinner: (_) async {},
        applyWinner: (_, _) async {
          businessApplies++;
          return true;
        },
      ),
      0,
    );
    final record = (await store.recordsForDataset('progress')).single;
    expect(record.payload!['canonical_locator'], {'progression': 0.1});
    expect(record.dirty, isFalse);
    expect(businessApplies, 1);
    expect(await store.cursorFor('remote'), 1);
  });

  test(
    'canonical payload comparison does not create false local changes',
    () async {
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 1000,
      );
      await store.recordLocal(
        dataset: 'books',
        recordId: 'book-1',
        entityKey: 'book-1',
        payload: const {'title': 'A', 'author': 'B'},
        deleted: false,
        clock: clock,
      );
      await store.markUploaded(await store.dirtyRecords());
      await store.recordLocal(
        dataset: 'books',
        recordId: 'book-1',
        entityKey: 'book-1',
        payload: const {'author': 'B', 'title': 'A'},
        deleted: false,
        clock: clock,
      );

      expect(await store.pendingCount(), 0);
      expect((await store.latestTimestamp()).toString(), '1000-0000-local');
    },
  );

  test(
    'dirty queries exclude datasets disabled by the current scope',
    () async {
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 1000,
      );
      await store.recordLocal(
        dataset: 'notes',
        recordId: 'note-1',
        entityKey: 'book-1',
        payload: const {'content': 'private note'},
        deleted: false,
        clock: clock,
      );
      await store.recordLocal(
        dataset: 'progress',
        recordId: 'book-1',
        entityKey: 'book-1',
        payload: const {'reading_progress': 0.5},
        deleted: false,
        clock: clock,
      );

      final visible = await store.dirtyRecords(datasets: const {'progress'});
      expect(visible.map((record) => record.dataset), ['progress']);
      expect(await store.pendingCount(datasets: const {'progress'}), 1);
      expect(await store.pendingCount(datasets: const {}), 0);
      expect(await store.pendingCount(), 2);
    },
  );

  test('unknown future dataset is retained without materialization', () async {
    final futureAdapter = _RecordingAdapter('future_annotations');
    final adapters = MetadataSyncAdapters(
      store: store,
      registeredAdapters: [futureAdapter],
    );
    final batch = SyncBatch.create(
      deviceId: 'future-device',
      sequence: 1,
      createdHlc: '2000-0000-future-device',
      operations: const [
        SyncOperation(
          dataset: 'future_annotations',
          recordId: 'note-1',
          entityKey: 'book-1',
          hlc: '2000-0000-future-device',
          deleted: false,
          payload: {'content': 'reserved future payload'},
        ),
      ],
    );

    expect(
      await store.applyRemoteBatch(
        batch,
        validateWinner: adapters.validate,
        applyWinner: adapters.apply,
      ),
      1,
    );
    final retained = (await store.recordsForDataset(
      'future_annotations',
    )).single;
    expect(retained.recordId, 'note-1');
    expect(retained.dirty, isFalse);
    expect(futureAdapter.applyCount, 0);
    expect(await store.cursorFor('future-device'), 1);
  });

  test('disabled known dataset is retained without business apply', () async {
    final notesAdapter = _RecordingAdapter('notes');
    final adapters = MetadataSyncAdapters(
      store: store,
      registeredAdapters: [notesAdapter],
    );
    final batch = SyncBatch.create(
      deviceId: 'remote',
      sequence: 1,
      createdHlc: '2000-0000-remote',
      operations: const [
        SyncOperation(
          dataset: 'notes',
          recordId: 'note-1',
          entityKey: 'book-1',
          hlc: '2000-0000-remote',
          deleted: false,
          payload: {'content': 'private note'},
        ),
      ],
    );

    await store.applyRemoteBatch(
      batch,
      validateWinner: adapters.validate,
      applyWinner: (txn, operation) => adapters.apply(
        txn,
        operation,
        scope: const WebDavSyncScope(notes: false),
      ),
    );

    expect((await store.recordsForDataset('notes')).single.recordId, 'note-1');
    expect(notesAdapter.applyCount, 0);
  });

  test(
    'a remote winner deferred by scope is materialized on re-enable',
    () async {
      final notesAdapter = _StatefulRecordingAdapter(store, 'notes', 'v1');
      final adapters = MetadataSyncAdapters(
        store: store,
        database: () async => database,
        registeredAdapters: [notesAdapter],
      );
      final localClock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 1000,
      );
      await adapters.scan(const WebDavSyncScope(notes: true), localClock);
      await store.markUploaded(await store.dirtyRecords());

      final batch = SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '2000-0000-remote',
        operations: const [
          SyncOperation(
            dataset: 'notes',
            recordId: 'note-1',
            entityKey: 'book-1',
            hlc: '2000-0000-remote',
            deleted: false,
            payload: {'value': 'v2'},
          ),
        ],
      );
      await store.applyRemoteBatch(
        batch,
        validateWinner: adapters.validate,
        applyWinner: (txn, operation) => adapters.apply(
          txn,
          operation,
          scope: const WebDavSyncScope(notes: false),
        ),
      );

      expect(notesAdapter.value, 'v1');
      expect(await store.getState('locally_observed:notes:note-1'), isNull);

      await adapters.scan(
        const WebDavSyncScope(notes: true),
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
      );

      expect(notesAdapter.value, 'v2');
      final record = (await store.recordsForDataset('notes')).single;
      expect(record.hlc, '2000-0000-remote');
      expect(record.dirty, isFalse);
      expect(await store.pendingCount(), 0);
      expect(
        await store.getState('locally_observed:notes:note-1'),
        '2000-0000-remote',
      );
    },
  );

  test(
    'failed materialization remains durably queued after cursor commit',
    () async {
      final adapter = _FailingMaterializationAdapter('notes');
      final adapters = MetadataSyncAdapters(
        store: store,
        database: () async => database,
        registeredAdapters: [adapter],
      );
      final batch = SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '2000-0000-remote',
        operations: const [
          SyncOperation(
            dataset: 'notes',
            recordId: 'note-1',
            entityKey: 'book-1',
            hlc: '2000-0000-remote',
            deleted: false,
            payload: {'value': 'remote'},
          ),
        ],
      );

      await expectLater(
        store.applyRemoteBatch(
          batch,
          validateWinner: adapters.validate,
          applyWinner: adapters.apply,
        ),
        throwsStateError,
      );
      expect(await store.cursorFor('remote'), 1);
      expect((await store.recordsForDataset('notes')).single.dirty, isFalse);
      expect(await store.getState('locally_observed:notes:note-1'), isNull);

      adapter.shouldFail = false;
      await adapters.scan(
        const WebDavSyncScope(notes: true),
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
      );
      expect(adapter.value, 'remote');
      expect(
        await store.getState('locally_observed:notes:note-1'),
        '2000-0000-remote',
      );
    },
  );

  test('book file payload exposes the content-addressed cover reference', () {
    expect(
      bookFileSyncPayload(const {
        'file_size': 10,
        'file_name': 'book.txt',
        'blob_sha256': 'book-hash',
        'remote_path': 'blobs/books/book-hash',
        'cover_blob_sha256': 'cover-hash',
        'cover_file_name': 'cover.img',
        'cover_file_size': 5,
        'cover_remote_path': 'blobs/covers/cover-hash',
      }),
      {
        'file_available': true,
        'file_size': 10,
        'file_name': 'book.txt',
        'blob_sha256': 'book-hash',
        'remote_path': 'blobs/books/book-hash',
        'cover_available': true,
        'cover_blob_sha256': 'cover-hash',
        'cover_file_name': 'cover.img',
        'cover_file_size': 5,
        'cover_remote_path': 'blobs/covers/cover-hash',
      },
    );
  });

  test('book file payload exposes the content-addressed cover reference', () {
    expect(
      bookFileSyncPayload(const {
        'file_size': 10,
        'file_name': 'book.txt',
        'blob_sha256': 'book-hash',
        'remote_path': 'blobs/books/book-hash',
        'cover_blob_sha256': 'cover-hash',
        'cover_file_name': 'cover.img',
        'cover_file_size': 5,
        'cover_remote_path': 'blobs/covers/cover-hash',
      }),
      {
        'file_available': true,
        'file_size': 10,
        'file_name': 'book.txt',
        'blob_sha256': 'book-hash',
        'remote_path': 'blobs/books/book-hash',
        'cover_available': true,
        'cover_blob_sha256': 'cover-hash',
        'cover_file_name': 'cover.img',
        'cover_file_size': 5,
        'cover_remote_path': 'blobs/covers/cover-hash',
      },
    );
  });
}

class _RecordingAdapter implements MetadataSyncAdapter {
  _RecordingAdapter(this.dataset);

  @override
  final String dataset;

  int applyCount = 0;

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    applyCount++;
    return true;
  }

  @override
  Future<void> scan(HybridLogicalClock clock) async {}

  @override
  Future<void> validate(SyncOperation operation) async {}
}

class _StatefulRecordingAdapter implements MetadataSyncAdapter {
  _StatefulRecordingAdapter(this.store, this.dataset, this.value);

  final SyncChangeStore store;

  @override
  final String dataset;

  String value;

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    value = operation.payload!['value']! as String;
    return true;
  }

  @override
  Future<void> scan(HybridLogicalClock clock) => store.recordLocal(
    dataset: dataset,
    recordId: 'note-1',
    entityKey: 'book-1',
    payload: {'value': value},
    deleted: false,
    clock: clock,
  );

  @override
  Future<void> validate(SyncOperation operation) async {}
}

class _FailingMaterializationAdapter implements MetadataSyncAdapter {
  _FailingMaterializationAdapter(this.dataset);

  @override
  final String dataset;

  bool shouldFail = true;
  String? value;

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (shouldFail) throw StateError('simulated preference failure');
    value = operation.payload!['value']! as String;
    return true;
  }

  @override
  Future<void> scan(HybridLogicalClock clock) async {}

  @override
  Future<void> validate(SyncOperation operation) async {}
}
