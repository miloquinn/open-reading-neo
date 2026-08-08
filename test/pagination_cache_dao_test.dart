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
