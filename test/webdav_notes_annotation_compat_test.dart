import 'dart:convert';

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
  late NotesSyncAdapter adapter;

  const bookUid = 'source:source-1:book-1';

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT,
        filePath TEXT NOT NULL,
        format TEXT NOT NULL,
        importDate INTEGER NOT NULL,
        content_hash TEXT,
        source_id TEXT,
        source_book_id TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE book_notes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        annotation_id TEXT NOT NULL,
        book_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        cfi TEXT NOT NULL,
        chapter TEXT NOT NULL,
        type TEXT NOT NULL,
        color TEXT NOT NULL,
        reader_note TEXT,
        page_number INTEGER,
        start_offset INTEGER,
        end_offset INTEGER,
        canonical_locator TEXT,
        payload_json TEXT,
        create_time TEXT,
        update_time TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX idx_book_notes_annotation_id_unique
      ON book_notes(annotation_id)
    ''');
    await database.insert('books', {
      'title': 'Remote Book',
      'author': 'Author',
      'filePath': '',
      'format': 'source',
      'importDate': 1,
      'source_id': 'source-1',
      'source_book_id': 'book-1',
    });
    await WebDavSyncSchemaMigration.migrate(database);
    store = SyncChangeStore(database: () async => database);
    adapter = NotesSyncAdapter(store, () async => database);
  });

  tearDown(() => database.close());

  test(
    'remote ink records preserve stable identity and drawing payload',
    () async {
      const annotationId = '27d34c7c-90e3-4c79-a1c6-95923628bb36';
      const operation = SyncOperation(
        dataset: 'notes',
        recordId: '64b1e3cb-3ed7-5ce2-a93d-c8f778aaeb2b',
        entityKey: bookUid,
        hlc: '1000-0000-remote',
        deleted: false,
        payload: {
          'annotation_id': annotationId,
          'content': 'quoted text',
          'cfi': 'or-annotation:ink:chapter-1:4:4',
          'chapter': 'Chapter 1',
          'type': 'ink',
          'color': '2563EB',
          'reader_note': null,
          'page_number': 1,
          'start_offset': 4,
          'end_offset': 4,
          'canonical_locator': {'chapterId': 'chapter-1'},
          'payload_json': {
            'version': 1,
            'coordinateSpace': 'normalized-page',
            'strokes': [
              {
                'color': '2563EB',
                'width': 2.7,
                'points': [
                  [0.1, 0.2],
                  [0.3, 0.4],
                ],
              },
            ],
          },
          'create_time': '2026-07-26T00:00:00.000Z',
          'update_time': '2026-07-26T00:00:00.000Z',
        },
      );

      await database.transaction((txn) => adapter.apply(txn, operation));

      final row = (await database.query('book_notes')).single;
      expect(row['annotation_id'], annotationId);
      expect(
        jsonDecode(row['payload_json']! as String),
        operation.payload!['payload_json'],
      );

      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000),
      );
      final record = (await store.recordsForDataset('notes')).single;
      expect(record.payload!['annotation_id'], annotationId);
      expect(
        record.payload!['payload_json'],
        operation.payload!['payload_json'],
      );
    },
  );

  test(
    'legacy remote notes use the stable record id as an annotation id',
    () async {
      const recordId = '749bd077-72b0-5279-aa6f-018083bb4964';
      const operation = SyncOperation(
        dataset: 'notes',
        recordId: recordId,
        entityKey: bookUid,
        hlc: '1000-0000-remote',
        deleted: false,
        payload: {
          'content': 'legacy highlight',
          'cfi': 'legacy-cfi',
          'chapter': 'Chapter 1',
          'type': 'highlight',
          'color': 'FFD54F',
          'create_time': '2026-07-25T00:00:00.000Z',
          'update_time': '2026-07-25T00:00:00.000Z',
        },
      );

      await database.transaction((txn) => adapter.apply(txn, operation));
      await database.transaction((txn) => adapter.apply(txn, operation));

      final rows = await database.query('book_notes');
      expect(rows, hasLength(1));
      expect(rows.single['annotation_id'], recordId);
    },
  );

  test(
    'new local annotations use their durable annotation UUID as record ID',
    () async {
      const annotationId = 'dc197717-f15f-47b7-b83a-e618de77cb40';
      await database.insert('book_notes', {
        'annotation_id': annotationId,
        'book_id': 1,
        'content': 'highlighted text',
        'cfi': 'or-annotation:highlight:chapter-1:2:8',
        'chapter': 'Chapter 1',
        'type': 'highlight',
        'color': 'FFD54F',
        'reader_note': null,
        'page_number': 1,
        'start_offset': 2,
        'end_offset': 8,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': '2026-08-30T00:00:00.000Z',
        'update_time': '2026-08-30T00:00:00.000Z',
      });

      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000),
      );

      final record = (await store.recordsForDataset('notes')).single;
      expect(record.recordId, annotationId);
      expect(record.payload?['annotation_id'], annotationId);
    },
  );

  test(
    'existing legacy sync identity is reused without creating an alias',
    () async {
      const annotationId = '3ed472ab-5b4c-4eb8-84ec-a4aa12de3db1';
      const legacyRecordId = '0a96a67d-355a-5daf-ae49-a73e5b108b15';
      await store.recordLocal(
        dataset: 'notes',
        recordId: legacyRecordId,
        entityKey: bookUid,
        payload: const {
          'annotation_id': annotationId,
          'content': 'legacy identity',
        },
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'old', nowMillis: () => 1000),
      );
      await store.markUploaded(await store.dirtyRecords());
      await database.insert('book_notes', {
        'annotation_id': annotationId,
        'book_id': 1,
        'content': 'legacy identity',
        'cfi': 'legacy-cfi',
        'chapter': 'Chapter 1',
        'type': 'highlight',
        'color': 'FFD54F',
        'reader_note': null,
        'page_number': 1,
        'start_offset': 1,
        'end_offset': 3,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': '2026-08-01T00:00:00.000Z',
        'update_time': '2026-08-01T00:00:00.000Z',
      });

      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 2000),
      );

      final active = (await store.recordsForDataset(
        'notes',
      )).where((record) => !record.deleted).toList();
      expect(active, hasLength(1));
      expect(active.single.recordId, legacyRecordId);
      expect(active.single.payload?['annotation_id'], annotationId);
    },
  );

  test('payload-less tombstone deletes a previously synced note', () async {
    const annotationId = '31aee86b-c485-48b4-8788-d7cc258fcb9b';
    await database.insert('book_notes', {
      'annotation_id': annotationId,
      'book_id': 1,
      'content': 'remove me',
      'cfi': 'note-cfi',
      'chapter': 'Chapter 1',
      'type': 'highlight',
      'color': 'FFD54F',
      'reader_note': null,
      'page_number': 1,
      'start_offset': 1,
      'end_offset': 2,
      'canonical_locator': null,
      'payload_json': null,
      'create_time': '2026-08-01T00:00:00.000Z',
      'update_time': '2026-08-01T00:00:00.000Z',
    });
    await adapter.scan(
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 1000),
    );
    await store.markUploaded(await store.dirtyRecords());
    final adapters = MetadataSyncAdapters(
      store: store,
      registeredAdapters: [adapter],
    );

    await store.applyRemoteBatch(
      SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '2000-0000-remote',
        operations: const [
          SyncOperation(
            dataset: 'notes',
            recordId: annotationId,
            entityKey: bookUid,
            hlc: '2000-0000-remote',
            deleted: true,
            payload: null,
          ),
        ],
      ),
      validateWinner: adapters.validate,
      applyWinner: adapters.apply,
    );

    expect(await database.query('book_notes'), isEmpty);
    await adapter.scan(
      HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
    );
    final record = (await store.recordsForDataset('notes')).single;
    expect(record.deleted, isTrue);
    expect(record.dirty, isFalse);
  });

  test(
    'a newer legacy tombstone defeats an older active canonical alias',
    () async {
      const annotationId = '1017af42-b198-4501-a9c0-ac04f074eb0b';
      const legacyRecordId = '91289c3e-a824-5e52-8a1e-96244e999608';
      const payload = <String, dynamic>{
        'annotation_id': annotationId,
        'content': 'keep canonical note',
        'cfi': 'alias-cfi',
        'chapter': 'Chapter 1',
        'type': 'highlight',
        'color': 'FFD54F',
        'reader_note': null,
        'page_number': 1,
        'start_offset': 1,
        'end_offset': 2,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': '2026-08-01T00:00:00.000Z',
        'update_time': '2026-08-01T00:00:00.000Z',
      };
      await database.insert('book_notes', {
        'annotation_id': annotationId,
        'book_id': 1,
        'content': payload['content'],
        'cfi': payload['cfi'],
        'chapter': payload['chapter'],
        'type': payload['type'],
        'color': payload['color'],
        'reader_note': null,
        'page_number': 1,
        'start_offset': 1,
        'end_offset': 2,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': payload['create_time'],
        'update_time': payload['update_time'],
      });
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 1000,
      );
      for (final recordId in [annotationId, legacyRecordId]) {
        await store.recordLocal(
          dataset: 'notes',
          recordId: recordId,
          entityKey: bookUid,
          payload: payload,
          deleted: false,
          clock: clock,
        );
      }
      await store.markUploaded(await store.dirtyRecords());
      final adapters = MetadataSyncAdapters(
        store: store,
        registeredAdapters: [adapter],
      );

      await store.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: '2000-0000-remote',
          operations: const [
            SyncOperation(
              dataset: 'notes',
              recordId: legacyRecordId,
              entityKey: bookUid,
              hlc: '2000-0000-remote',
              deleted: true,
              payload: null,
            ),
          ],
        ),
        validateWinner: adapters.validate,
        normalizeWinner: adapters.normalizeRemoteWinner,
        cleanupWinnerAliases: adapters.cleanupRemoteWinnerAliases,
        applyWinner: adapters.apply,
      );
      expect(await database.query('book_notes'), isEmpty);

      await store.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 2,
          createdHlc: '3000-0000-remote',
          operations: const [
            SyncOperation(
              dataset: 'notes',
              recordId: annotationId,
              entityKey: bookUid,
              hlc: '3000-0000-remote',
              deleted: true,
              payload: null,
            ),
          ],
        ),
        validateWinner: adapters.validate,
        normalizeWinner: adapters.normalizeRemoteWinner,
        cleanupWinnerAliases: adapters.cleanupRemoteWinnerAliases,
        applyWinner: adapters.apply,
      );
      expect(await database.query('book_notes'), isEmpty);
    },
  );

  test(
    'a newer canonical tombstone defeats an older active legacy alias',
    () async {
      const annotationId = '5be5ca44-f865-43dc-a345-1f15e67c7981';
      const legacyRecordId = '9a48a9dc-34cc-5acb-8f83-671b7be639f8';
      const payload = <String, dynamic>{
        'annotation_id': annotationId,
        'content': 'delete across aliases',
        'cfi': 'reverse-alias-cfi',
        'chapter': 'Chapter 1',
        'type': 'highlight',
        'color': 'FFD54F',
        'reader_note': null,
        'page_number': 1,
        'start_offset': 1,
        'end_offset': 2,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': '2026-08-01T00:00:00.000Z',
        'update_time': '2026-08-01T00:00:00.000Z',
      };
      await database.insert('book_notes', {
        'annotation_id': annotationId,
        'book_id': 1,
        'content': payload['content'],
        'cfi': payload['cfi'],
        'chapter': payload['chapter'],
        'type': payload['type'],
        'color': payload['color'],
        'reader_note': null,
        'page_number': 1,
        'start_offset': 1,
        'end_offset': 2,
        'canonical_locator': null,
        'payload_json': null,
        'create_time': payload['create_time'],
        'update_time': payload['update_time'],
      });
      for (final recordId in [annotationId, legacyRecordId]) {
        await store.recordLocal(
          dataset: 'notes',
          recordId: recordId,
          entityKey: bookUid,
          payload: payload,
          deleted: false,
          clock: HybridLogicalClock(deviceId: recordId, nowMillis: () => 1000),
        );
      }
      await store.markUploaded(await store.dirtyRecords());
      final adapters = MetadataSyncAdapters(
        store: store,
        registeredAdapters: [adapter],
      );

      await store.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'remote',
          sequence: 1,
          createdHlc: '2000-0000-remote',
          operations: const [
            SyncOperation(
              dataset: 'notes',
              recordId: annotationId,
              entityKey: bookUid,
              hlc: '2000-0000-remote',
              deleted: true,
            ),
          ],
        ),
        validateWinner: adapters.validate,
        normalizeWinner: adapters.normalizeRemoteWinner,
        cleanupWinnerAliases: adapters.cleanupRemoteWinnerAliases,
        applyWinner: adapters.apply,
      );

      expect(await database.query('book_notes'), isEmpty);
      await adapter.scan(
        HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
      );
      expect(
        (await store.recordsForDataset(
          'notes',
        )).where((record) => !record.deleted),
        isEmpty,
      );
    },
  );

  test(
    'local note deletion publishes tombstones for observed aliases',
    () async {
      const annotationId = 'local-delete-annotation';
      const legacyRecordId = 'local-delete-legacy';
      await database.insert('book_notes', {
        'annotation_id': annotationId,
        'book_id': 1,
        'content': 'remove on both devices',
        'cfi': 'local-delete-cfi',
        'chapter': 'Chapter 1',
        'type': 'note',
        'color': 'FFD54F',
        'create_time': '2026-08-01T00:00:00.000Z',
        'update_time': '2026-08-01T00:00:00.000Z',
      });
      final clock = HybridLogicalClock(
        deviceId: 'local',
        nowMillis: () => 2000,
      );
      await adapter.scan(clock);
      final original = (await store.recordsForDataset('notes')).single;
      await store.recordLocal(
        dataset: 'notes',
        recordId: legacyRecordId,
        entityKey: bookUid,
        payload: original.payload,
        deleted: false,
        clock: clock,
      );
      await store.markUploaded(await store.dirtyRecords());

      await adapter.scan(clock);
      expect(await store.dirtyRecords(), isEmpty);
      await database.delete('book_notes');
      await adapter.scan(clock);

      final pending = await store.dirtyRecords();
      expect(
        pending.map((record) => record.recordId),
        unorderedEquals([annotationId, legacyRecordId]),
      );
      expect(pending.every((record) => record.deleted), isTrue);
    },
  );

  for (final notesEnabled in [true, false]) {
    test(
      'canonicalizing a newer dirty alias preserves its pending upload (notes=$notesEnabled)',
      () async {
        const annotationId = 'pending-canonical-annotation';
        const legacyRecordId = 'pending-legacy-annotation';
        Map<String, dynamic> payload(String content) => {
          'annotation_id': annotationId,
          'content': content,
          'cfi': 'pending-alias-cfi',
          'chapter': 'Chapter 1',
          'type': 'note',
          'color': 'FFD54F',
          'create_time': '2026-08-01T00:00:00.000Z',
          'update_time': '2026-09-04T00:00:00.000Z',
        };
        await store.recordLocal(
          dataset: 'notes',
          recordId: legacyRecordId,
          entityKey: bookUid,
          payload: payload('unpublished local edit'),
          deleted: false,
          clock: HybridLogicalClock(deviceId: 'local', nowMillis: () => 3000),
        );
        final pendingHlc = (await store.dirtyRecords()).single.hlc;
        final adapters = MetadataSyncAdapters(
          store: store,
          registeredAdapters: [adapter],
        );
        await store.applyRemoteBatch(
          SyncBatch.create(
            deviceId: 'remote',
            sequence: 1,
            createdHlc: '2000-0000-remote',
            operations: [
              SyncOperation(
                dataset: 'notes',
                recordId: annotationId,
                entityKey: bookUid,
                hlc: '2000-0000-remote',
                deleted: false,
                payload: payload('older remote edit'),
              ),
            ],
          ),
          validateWinner: adapters.validate,
          normalizeWinner: adapters.normalizeRemoteWinner,
          cleanupWinnerAliases: adapters.cleanupRemoteWinnerAliases,
          applyWinner: (txn, operation) => adapters.apply(
            txn,
            operation,
            scope: WebDavSyncScope(notes: notesEnabled),
          ),
        );

        final pending = (await store.dirtyRecords()).single;
        expect(pending.recordId, annotationId);
        expect(pending.hlc, pendingHlc);
        expect(pending.payload?['content'], 'unpublished local edit');
        expect((await store.recordsForDataset('notes')), hasLength(1));
        final rows = await database.query('book_notes');
        if (notesEnabled) {
          expect(rows.single['content'], 'unpublished local edit');
        } else {
          expect(rows, isEmpty);
          expect(
            await store.getState('locally_observed:notes:$annotationId'),
            isNull,
          );
        }
      },
    );
  }

  test('divergent note aliases materialize the newest HLC payload', () async {
    const annotationId = '44476064-835f-4aa9-8127-78a27d68ed96';
    const legacyRecordId = '7642fc51-1442-5b7d-8324-718e2045c754';
    Map<String, dynamic> payload(String content) => <String, dynamic>{
      'annotation_id': annotationId,
      'content': content,
      'cfi': 'divergent-alias-cfi',
      'chapter': 'Chapter 1',
      'type': 'note',
      'color': 'FFD54F',
      'reader_note': content,
      'page_number': 1,
      'start_offset': 1,
      'end_offset': 2,
      'canonical_locator': null,
      'payload_json': null,
      'create_time': '2026-08-01T00:00:00.000Z',
      'update_time': '2026-09-04T00:00:00.000Z',
    };
    final adapters = MetadataSyncAdapters(
      store: store,
      registeredAdapters: [adapter],
    );

    await store.applyRemoteBatch(
      SyncBatch.create(
        deviceId: 'remote',
        sequence: 1,
        createdHlc: '3000-0000-remote',
        operations: [
          SyncOperation(
            dataset: 'notes',
            recordId: legacyRecordId,
            entityKey: bookUid,
            hlc: '3000-0000-remote',
            deleted: false,
            payload: payload('newer legacy payload'),
          ),
          SyncOperation(
            dataset: 'notes',
            recordId: annotationId,
            entityKey: bookUid,
            hlc: '2000-0000-remote',
            deleted: false,
            payload: payload('older canonical payload'),
          ),
        ],
      ),
      validateWinner: adapters.validate,
      normalizeWinner: adapters.normalizeRemoteWinner,
      cleanupWinnerAliases: adapters.cleanupRemoteWinnerAliases,
      applyWinner: adapters.apply,
    );

    final row = (await database.query('book_notes')).single;
    expect(row['content'], 'newer legacy payload');
    expect(row['reader_note'], 'newer legacy payload');
  });
}
