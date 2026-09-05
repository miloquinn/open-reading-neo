import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/pagination_cache_schema_migration.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';

void main() {
  late Database database;
  late PaginationCacheDao dao;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('PRAGMA foreign_keys = ON');
    await database.execute(
      'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT)',
    );
    await database.insert('books', {'id': 1});
    await PaginationCacheSchemaMigration.migrate(database);
    await PaginationCacheSchemaMigration.migrate(database);
    dao = PaginationCacheDao(databaseProvider: () async => database);
  });

  tearDown(() => database.close());

  test(
    'online identities persist without books and invalidate content revisions',
    () async {
      await dao.upsertForIdentity(
        identity: 'online:source/book/chapter',
        bookRevision: 'text-a',
        layoutFingerprint: 'layout-a',
        chapterIndex: 0,
        payload: Uint8List.fromList([1, 2]),
      );
      final reopened = PaginationCacheDao(
        databaseProvider: () async => database,
      );
      expect(
        (await reopened.loadForIdentity(
          'online:source/book/chapter',
          'text-a',
        ))['layout-a'],
        [1, 2],
      );
      expect(
        await reopened.loadForIdentity('online:other/book/chapter', 'text-a'),
        isEmpty,
      );
      expect(
        await reopened.loadForIdentity('online:source/book/chapter', 'text-b'),
        isEmpty,
      );
    },
  );

  test(
    'global entry and byte quotas include online and local payloads',
    () async {
      final bounded = PaginationCacheDao(
        databaseProvider: () async => database,
        maxEntries: 10,
        maxBytes: 5,
      );
      for (var i = 0; i < 4; i++) {
        await bounded.upsertForIdentity(
          identity: 'online:$i',
          bookRevision: 'a',
          layoutFingerprint: 'l',
          chapterIndex: 0,
          payload: Uint8List.fromList([1, 2]),
        );
      }
      expect(await bounded.payloadSizeBytes(), 4);
      expect(await database.query('reader_pagination_cache'), hasLength(2));
    },
  );

  test(
    'clear rejects writes queued before clear across DAO instances',
    () async {
      final oldEpoch = PaginationCacheDao.epoch;
      final ready = Completer<Database>();
      final delayed = PaginationCacheDao(databaseProvider: () => ready.future);
      final pending = delayed.upsertForIdentity(
        identity: 'online:a',
        bookRevision: 'a',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([1]),
      );
      await dao.clearAll();
      ready.complete(database);
      await pending;
      await dao.upsert(
        bookId: 1,
        bookRevision: 'a',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([2]),
        expectedEpoch: oldEpoch,
      );
      expect(await dao.payloadSizeBytes(), 0);
    },
  );

  test('deleting a local book cascades only its pagination rows', () async {
    await dao.upsert(
      bookId: 1,
      bookRevision: 'a',
      layoutFingerprint: 'l',
      chapterIndex: 0,
      payload: Uint8List.fromList([1]),
    );
    await dao.upsertForIdentity(
      identity: 'online:a',
      bookRevision: 'a',
      layoutFingerprint: 'l',
      chapterIndex: 0,
      payload: Uint8List.fromList([2]),
    );
    await database.delete('books', where: 'id = ?', whereArgs: [1]);
    expect(await dao.loadForBook(1, 'a'), isEmpty);
    expect((await dao.loadForIdentity('online:a', 'a'))['l'], [2]);
  });

  test(
    'late old revision reads and writes cannot remove the newer revision',
    () async {
      final identity = 'online:revision-race';
      final oldToken = PaginationCacheDao.revisionEpochFor(identity, 'old');
      final ready = Completer<Database>();
      final delayed = PaginationCacheDao(databaseProvider: () => ready.future);
      final pendingWrite = delayed.upsertForIdentity(
        identity: identity,
        bookRevision: 'old',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([1]),
      );
      final pendingRead = delayed.loadForIdentity(identity, 'old');
      await dao.loadForIdentity(identity, 'new');
      await dao.upsertForIdentity(
        identity: identity,
        bookRevision: 'new',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([2]),
      );
      ready.complete(database);
      await pendingWrite;
      expect(await pendingRead, isEmpty);
      await dao.upsertForIdentity(
        identity: identity,
        bookRevision: 'old',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([3]),
        expectedRevisionEpoch: oldToken,
      );
      expect((await dao.loadForIdentity(identity, 'new'))['l'], [2]);
    },
  );

  test(
    'global pruning skips oversized candidates and retains older fitting rows',
    () async {
      final bounded = PaginationCacheDao(
        databaseProvider: () async => database,
        maxEntries: 2,
        maxBytes: 5,
      );
      for (final entry in [('small', 1), ('middle', 4), ('newest', 4)]) {
        await bounded.upsertForIdentity(
          identity: 'online:${entry.$1}',
          bookRevision: 'a',
          layoutFingerprint: 'l',
          chapterIndex: 0,
          payload: Uint8List(entry.$2),
        );
      }
      final rows = await database.query('reader_pagination_cache');
      expect(
        rows.map((r) => r['cache_identity']),
        containsAll(['online:newest', 'online:small']),
      );
      expect(await bounded.payloadSizeBytes(), 5);
    },
  );

  test('a read refreshes recency before global entry eviction', () async {
    final bounded = PaginationCacheDao(
      databaseProvider: () async => database,
      maxEntries: 2,
      maxBytes: 100,
    );
    for (final identity in ['online:hot', 'online:cold']) {
      await bounded.upsertForIdentity(
        identity: identity,
        bookRevision: 'a',
        layoutFingerprint: 'l',
        chapterIndex: 0,
        payload: Uint8List.fromList([1]),
      );
    }
    await database.update('reader_pagination_cache', {'updated_at': 1});
    await bounded.loadForIdentity('online:hot', 'a');
    await bounded.upsertForIdentity(
      identity: 'online:new',
      bookRevision: 'a',
      layoutFingerprint: 'l',
      chapterIndex: 0,
      payload: Uint8List.fromList([1]),
    );
    final rows = await database.query('reader_pagination_cache');
    expect(
      rows.map((r) => r['cache_identity']),
      containsAll(['online:hot', 'online:new']),
    );
    expect(rows, hasLength(2));
  });

  test('round-trips payloads and replaces an existing layout', () async {
    await dao.upsert(
      bookId: 1,
      bookRevision: 'revision-a',
      layoutFingerprint: 'layout-1',
      chapterIndex: 3,
      payload: Uint8List.fromList([1, 2, 3]),
    );
    await dao.upsert(
      bookId: 1,
      bookRevision: 'revision-a',
      layoutFingerprint: 'layout-2',
      chapterIndex: 4,
      payload: Uint8List.fromList([4, 5]),
    );
    await dao.upsert(
      bookId: 1,
      bookRevision: 'revision-a',
      layoutFingerprint: 'layout-1',
      chapterIndex: 3,
      payload: Uint8List.fromList([9, 8, 7]),
    );

    final restored = await dao.loadForBook(1, 'revision-a');

    expect(restored.keys, containsAll(<String>['layout-1', 'layout-2']));
    expect(restored['layout-1'], orderedEquals(<int>[9, 8, 7]));
    expect(restored['layout-2'], orderedEquals(<int>[4, 5]));
  });

  test('loading a new revision removes stale rows', () async {
    await dao.upsert(
      bookId: 1,
      bookRevision: 'revision-old',
      layoutFingerprint: 'old-layout',
      chapterIndex: 0,
      payload: Uint8List.fromList([1]),
    );

    expect(await dao.loadForBook(1, 'revision-new'), isEmpty);
    expect(await database.query('reader_pagination_cache'), isEmpty);
  });

  test('bounds retained layouts and deletes all rows for a book', () async {
    for (var index = 0; index < 132; index++) {
      await dao.upsert(
        bookId: 1,
        bookRevision: 'revision-a',
        layoutFingerprint: 'layout-$index',
        chapterIndex: index,
        payload: Uint8List.fromList([index & 0xff]),
      );
    }

    final rows = await database.query('reader_pagination_cache');
    expect(rows, hasLength(PaginationCacheDao.maxLayoutsPerBook));

    await dao.deleteForBook(1);
    expect(await database.query('reader_pagination_cache'), isEmpty);
  });

  test('replaces the legacy v21 cache table without touching books', () async {
    await database.execute(
      'DROP TABLE ${PaginationCacheSchemaMigration.tableName}',
    );
    await database.execute('''
      CREATE TABLE ${PaginationCacheSchemaMigration.tableName}(
        cache_key TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await database.insert(PaginationCacheSchemaMigration.tableName, {
      'cache_key': 'legacy-key',
      'book_id': '1',
      'chapter_id': 'legacy-chapter',
      'payload': '{}',
      'updated_at': 1,
    });

    await PaginationCacheSchemaMigration.migrate(database);

    final columns = await database.rawQuery(
      'PRAGMA table_info(${PaginationCacheSchemaMigration.tableName})',
    );
    expect(columns.map((row) => row['name']).toSet(), {
      'cache_identity',
      'book_id',
      'book_revision',
      'layout_fingerprint',
      'chapter_index',
      'payload',
      'updated_at',
    });
    expect(
      await database.query(PaginationCacheSchemaMigration.tableName),
      isEmpty,
    );
    expect(
      await database.query('books', where: 'id = ?', whereArgs: [1]),
      hasLength(1),
    );
  });

  test(
    'migrates compatible local binary boundaries into the local namespace',
    () async {
      await database.execute('DROP TABLE reader_pagination_cache');
      await database.execute('''CREATE TABLE reader_pagination_cache(
      book_id INTEGER NOT NULL, book_revision TEXT NOT NULL,
      layout_fingerprint TEXT NOT NULL, chapter_index INTEGER NOT NULL,
      payload BLOB NOT NULL, updated_at INTEGER NOT NULL,
      PRIMARY KEY(book_id, book_revision, layout_fingerprint),
      FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE)''');
      await database.insert('reader_pagination_cache', {
        'book_id': 1,
        'book_revision': 'a',
        'layout_fingerprint': 'l',
        'chapter_index': 0,
        'payload': Uint8List.fromList([7]),
        'updated_at': 1,
      });
      await PaginationCacheSchemaMigration.migrate(database);
      expect((await dao.loadForBook(1, 'a'))['l'], [7]);
      expect(
        (await database.query(
          'reader_pagination_cache',
        )).single['cache_identity'],
        'local:1',
      );
      expect(await database.query('books'), hasLength(1));
    },
  );

  test('keeps current cache rows when migration runs again', () async {
    await dao.upsert(
      bookId: 1,
      bookRevision: 'revision-current',
      layoutFingerprint: 'layout-current',
      chapterIndex: 2,
      payload: Uint8List.fromList([7, 8, 9]),
    );

    await PaginationCacheSchemaMigration.migrate(database);

    final restored = await dao.loadForBook(1, 'revision-current');
    expect(restored['layout-current'], orderedEquals(<int>[7, 8, 9]));
  });
}
