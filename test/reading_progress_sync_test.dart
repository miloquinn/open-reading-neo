import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/book_sync_identity.dart';
import 'package:xxread/services/sync/reading_progress_event.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_clock.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;
  late Directory tempDirectory;
  late SyncChangeStore store;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('progress-sync-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await _createBooksTable(database);
    await WebDavSyncSchemaMigration.migrate(database);
    store = SyncChangeStore(database: () async => database);
  });

  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  Future<Map<String, Object?>> insertTxt({double progress = 0.2}) async {
    final file = File('${tempDirectory.path}/book.txt');
    await file.writeAsString('first version');
    final id = await database.insert('books', {
      'title': 'Book',
      'author': 'Author',
      'filePath': file.path,
      'format': 'txt',
      'currentPage': 2,
      'totalPages': 10,
      'reading_progress': progress,
      'importDate': 1000,
      'content_hash': 'content-v1',
      'storage_type': 'local',
    });
    return (await database.query(
      'books',
      where: 'id = ?',
      whereArgs: [id],
    )).single;
  }

  ProgressSyncAdapter adapterFor(Database db, SyncChangeStore changeStore) =>
      ProgressSyncAdapter(
        changeStore,
        () async => db,
        const BookSourceReadingProgressStore(),
      );

  test('stable book identity survives mutable TXT content changes', () async {
    final row = await insertTxt();
    final before = await stableBookUidForMap(database, row);

    await File(row['filePath']! as String).writeAsString('edited version');
    final after = await stableBookUidForMap(
      database,
      (await database.query('books')).single,
    );

    expect(after, before);
    expect(await store.getState('frozen_book_uid:${row['id']}'), before);
  });

  test(
    'remote progress is staged and never overwrites the business row',
    () async {
      final row = await insertTxt();
      final uid = await stableBookUidForMap(database, row);
      final applied = await database.transaction(
        (txn) => adapterFor(database, store).apply(
          txn,
          _operation(
            uid,
            page: 8,
            device: 'remote',
            vector: const {'remote': 1},
          ),
        ),
      );

      expect(applied, isTrue);
      expect((await database.query('books')).single['currentPage'], 2);
      final candidates = await store.statesWithPrefix(
        'progress_candidate:$uid:',
      );
      expect(candidates, hasLength(1));
      expect(candidates.values.single, contains('remote-event'));
    },
  );

  test(
    'a database scan cannot invent a fresh event for stale progress',
    () async {
      final row = await insertTxt(progress: 0.1);
      final uid = await stableBookUidForMap(database, row);
      final adapter = adapterFor(database, store);

      await adapter.scan(HybridLogicalClock(deviceId: 'new-device'));
      expect(await store.recordsForDataset('progress'), isEmpty);

      await store.setState(
        '${ReadingProgressSyncService.localEventStatePrefix}$uid',
        jsonEncode(_event('real-read', 'new-device', const {'new-device': 1})),
      );
      await adapter.scan(HybridLogicalClock(deviceId: 'new-device'));
      expect(
        (await store.recordsForDataset(
          'progress',
        )).single.payload?['position_event']['event_id'],
        'real-read',
      );
    },
  );

  test(
    'late upload from an offline branch cannot steal a newer mirror',
    () async {
      const uid = 'book-uid';
      await store.recordLocal(
        dataset: 'progress',
        recordId: uid,
        entityKey: uid,
        payload: {
          'current_page': 9,
          'position_event': _event('b-90', 'b', const {'a': 1, 'b': 1}),
        },
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'b', nowMillis: () => 11000),
      );

      final applied = await _applyBatch(
        store,
        _operation(
          uid,
          page: 8,
          device: 'a',
          eventId: 'a-80-late',
          vector: const {'a': 2},
          hlc: '12000-0000-a',
        ),
        device: 'a',
      );

      expect(applied, 0);
      expect(
        (await store.recordsForDataset(
          'progress',
        )).single.payload?['current_page'],
        9,
      );
      expect(
        await store.statesWithPrefix('progress_candidate:$uid:'),
        hasLength(1),
      );
    },
  );

  test(
    'candidates from three devices coexist instead of replacing each other',
    () async {
      const uid = 'book-uid';
      await store.recordLocal(
        dataset: 'progress',
        recordId: uid,
        entityKey: uid,
        payload: {
          'current_page': 2,
          'position_event': _event('local', 'local', const {'local': 1}),
        },
        deleted: false,
        clock: HybridLogicalClock(deviceId: 'local'),
      );
      await _applyBatch(
        store,
        _operation(uid, page: 6, device: 'a', vector: const {'a': 1}),
        device: 'a',
      );
      await _applyBatch(
        store,
        _operation(
          uid,
          page: 7,
          device: 'c',
          eventId: 'c-event',
          vector: const {'c': 1},
        ),
        device: 'c',
        sequence: 2,
      );

      final candidates = await store.statesWithPrefix(
        'progress_candidate:$uid:',
      );
      expect(candidates, hasLength(2));
      expect(candidates.values.join(), contains('remote-event'));
      expect(candidates.values.join(), contains('c-event'));

      final service = ReadingProgressSyncService.instance;
      final parsed = await service.candidatesForUid(uid, changeStore: store);
      final fromA = parsed.singleWhere(
        (candidate) => candidate.snapshot.eventId == 'remote-event',
      );
      final fromC = parsed.singleWhere(
        (candidate) => candidate.snapshot.eventId == 'c-event',
      );
      await service.snoozeCandidate(1, fromA, changeStore: store);
      await service.ignoreCandidate(fromC, changeStore: store);
      expect(
        await service.candidatesForUid(
          uid,
          includeSnoozed: false,
          changeStore: store,
        ),
        isEmpty,
      );
      expect(
        await service.candidatesForUid(uid, changeStore: store),
        hasLength(1),
      );
    },
  );

  test('causally newer progress is mirrored but remains a candidate', () async {
    final row = await insertTxt();
    final uid = await stableBookUidForMap(database, row);
    await store.recordLocal(
      dataset: 'progress',
      recordId: uid,
      entityKey: uid,
      payload: {
        'current_page': 2,
        'position_event': _event('a-1', 'a', const {'a': 1}),
      },
      deleted: false,
      clock: HybridLogicalClock(deviceId: 'a', nowMillis: () => 1000),
    );
    final operation = _operation(
      uid,
      page: 8,
      device: 'b',
      eventId: 'b-1',
      vector: const {'a': 1, 'b': 1},
      hlc: '500-0000-b',
    );

    expect(
      await store.applyRemoteBatch(
        SyncBatch.create(
          deviceId: 'b',
          sequence: 1,
          createdHlc: operation.hlc,
          operations: [operation],
        ),
        validateWinner: adapterFor(database, store).validate,
        applyWinner: adapterFor(database, store).apply,
      ),
      1,
    );
    expect((await database.query('books')).single['currentPage'], 2);
    expect(
      (await store.recordsForDataset(
        'progress',
      )).single.payload?['current_page'],
      8,
    );
    expect(
      await store.statesWithPrefix('progress_candidate:$uid:'),
      hasLength(1),
    );
  });

  test(
    'automatic selection requires one candidate to dominate every branch',
    () {
      final service = ReadingProgressSyncService.instance;
      final head = _snapshot('head', 'a', const {'a': 1});
      final causal = _candidate(
        _snapshot('causal', 'b', const {'a': 1, 'b': 1}),
      );
      final concurrent = _candidate(_snapshot('other', 'c', const {'c': 1}));

      expect(service.chooseCausallyNewest(head, [causal]), same(causal));
      expect(service.chooseCausallyNewest(head, [causal, concurrent]), isNull);
    },
  );

  test('different event ids with equal vectors are concurrent', () {
    expect(
      compareReadingProgressEvents(
        _event('first', 'a', const {'a': 1}),
        _event('second', 'a', const {'a': 1}),
      ),
      ReadingProgressEventRelation.concurrent,
    );
  });

  test('one legacy candidate can initialize an unread online book only', () {
    final service = ReadingProgressSyncService.instance;
    final legacy = ReadingProgressRemoteCandidate(
      bookUid: 'source:book',
      snapshot: const ReadingProgressSnapshot(
        currentPage: 8,
        readingProgress: 0.8,
        canonicalLocator: null,
        eventId: 'legacy-event',
      ),
      receivedAt: DateTime.utc(2026),
    );
    final unread = Book(
      id: 1,
      title: 'Online',
      filePath: '',
      format: 'source',
      storageType: 'online',
      currentPage: 0,
    );

    expect(
      service.chooseCandidateForOpen(unread, null, [legacy]),
      same(legacy),
    );
    expect(
      service.chooseCandidateForOpen(
        unread.copyWith(currentPage: 2, readingProgress: 0.2),
        null,
        [legacy],
      ),
      isNull,
    );
  });

  test('content revision is checked before a remote locator can apply', () {
    final locator = jsonEncode({
      'format': 'txt',
      'chapterId': 'txt-8',
      'progression': 0.4,
      'contentSignature': 'content-v2',
    });
    final candidate = ReadingProgressRemoteCandidate(
      bookUid: 'uid',
      snapshot: ReadingProgressSnapshot(
        currentPage: 8,
        readingProgress: 0.8,
        canonicalLocator: locator,
        locatorRevision: 'content-v2',
      ),
      receivedAt: DateTime.utc(2026),
    );
    final book = Book(
      id: 1,
      title: 'Book',
      filePath: '/tmp/book.txt',
      format: 'txt',
      contentHash: 'content-v1',
    );

    expect(
      ReadingProgressSyncService.instance.candidateMatchesBook(candidate, book),
      isFalse,
    );
    final fallbackOnly = ReadingProgressRemoteCandidate(
      bookUid: 'uid',
      snapshot: const ReadingProgressSnapshot(
        currentPage: 8,
        readingProgress: 0.8,
        canonicalLocator: null,
        locatorRevision: 'content-v2',
      ),
      receivedAt: DateTime.utc(2026),
    );
    expect(
      ReadingProgressSyncService.instance.candidateMatchesBook(
        fallbackOnly,
        book,
      ),
      isFalse,
    );
  });

  test('switching WebDAV space keeps local causal history only', () async {
    final row = await insertTxt();
    final uid = await stableBookUidForMap(database, row);
    await database.insert('sync_book_files', {
      'book_uid': uid,
      'local_book_id': row['id'],
      'blob_sha256': 'hash',
      'file_name': 'book.txt',
      'file_size': 10,
      'remote_path': 'old-space/book.txt',
      'sync_enabled': 1,
      'updated_at': '2026-09-05T09:00:00.000Z',
    });
    await store.setState('device_id', 'old-device');
    await store.setState('progress_candidate:$uid:remote', 'candidate');
    await store.setState('progress_event:$uid', 'local-event');
    await store.setState('progress_head:$uid', 'local-head');
    await store.setState('progress_device_sequence:$uid:old-device', '4');

    await store.resetRemoteMirrorForNewSpace();

    expect(await store.getState('device_id'), isNull);
    expect(await store.getState('progress_candidate:$uid:remote'), isNull);
    expect(await store.getState('progress_event:$uid'), 'local-event');
    expect(await store.getState('progress_head:$uid'), 'local-head');
    expect(
      await store.getState('progress_device_sequence:$uid:old-device'),
      '4',
    );
    expect(await store.getState('frozen_book_uid:${row['id']}'), uid);
  });
}

Map<String, Object?> _event(
  String eventId,
  String device,
  Map<String, int> vector,
) => {
  'event_id': eventId,
  'saved_at': '2026-09-05T09:00:00.000Z',
  'device_id': device,
  'device_sequence': vector[device] ?? 1,
  'vector': vector,
};

SyncOperation _operation(
  String uid, {
  required int page,
  required String device,
  required Map<String, int> vector,
  String eventId = 'remote-event',
  String hlc = '2000-0000-remote',
}) => SyncOperation(
  dataset: 'progress',
  recordId: uid,
  entityKey: uid,
  hlc: hlc,
  deleted: false,
  payload: {
    'book_uid': uid,
    'current_page': page,
    'total_pages': 10,
    'reading_progress': page / 10,
    'position_event': _event(eventId, device, vector),
  },
);

Future<int> _applyBatch(
  SyncChangeStore store,
  SyncOperation operation, {
  required String device,
  int sequence = 1,
}) => store.applyRemoteBatch(
  SyncBatch.create(
    deviceId: device,
    sequence: sequence,
    createdHlc: operation.hlc,
    operations: [operation],
  ),
  validateWinner: (_) async {},
  applyWinner: (_, _) async => true,
);

ReadingProgressSnapshot _snapshot(
  String eventId,
  String device,
  Map<String, int> vector,
) => ReadingProgressSnapshot(
  currentPage: 1,
  readingProgress: 0.1,
  canonicalLocator: null,
  eventId: eventId,
  savedAt: DateTime.utc(2026),
  deviceId: device,
  deviceSequence: vector[device] ?? 1,
  vector: vector,
);

ReadingProgressRemoteCandidate _candidate(ReadingProgressSnapshot snapshot) =>
    ReadingProgressRemoteCandidate(
      bookUid: 'uid',
      snapshot: snapshot,
      receivedAt: DateTime.utc(2026),
    );

Future<void> _createBooksTable(Database database) => database.execute('''
  CREATE TABLE books(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    author TEXT,
    filePath TEXT NOT NULL,
    format TEXT NOT NULL,
    currentPage INTEGER DEFAULT 0,
    totalPages INTEGER DEFAULT 1,
    reading_progress REAL,
    importDate INTEGER NOT NULL,
    content_hash TEXT,
    last_canonical_locator TEXT,
    storage_type TEXT NOT NULL DEFAULT 'local',
    source_id TEXT,
    source_book_id TEXT
  )
''');
