import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/book_note_lookup_index_migration.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('v23 migration adds the CFI lookup index and is idempotent', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    await database.execute('''
      CREATE TABLE book_notes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        cfi TEXT NOT NULL,
        type TEXT NOT NULL
      )
    ''');

    await BookNoteLookupIndexMigration.migrate(database);
    await BookNoteLookupIndexMigration.migrate(database);

    final indexes = await database.rawQuery('PRAGMA index_list(book_notes)');
    expect(
      indexes.map((row) => row['name']),
      contains(BookNoteLookupIndexMigration.indexName),
    );
    final plan = await database.rawQuery(
      'EXPLAIN QUERY PLAN '
      'SELECT * FROM book_notes '
      'WHERE book_id = ? AND cfi = ? AND type != ? '
      'ORDER BY id DESC LIMIT 1',
      [1, 'chapter-1', 'ink'],
    );
    expect(
      plan.map((row) => row['detail']).join('\n'),
      contains(BookNoteLookupIndexMigration.indexName),
    );
  });
}
