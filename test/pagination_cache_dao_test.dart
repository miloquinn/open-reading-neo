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
}
