import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Adds the bounded, versioned cache for native-reader page boundaries.
class PaginationCacheSchemaMigration {
  const PaginationCacheSchemaMigration._();

  static const int migrationVersion = 22;
  static const String tableName = 'reader_pagination_cache';

  static const Map<String, ({String type, int primaryKeyOrder})>
  _expectedColumns = {
    'book_id': (type: 'INTEGER', primaryKeyOrder: 1),
    'book_revision': (type: 'TEXT', primaryKeyOrder: 2),
    'layout_fingerprint': (type: 'TEXT', primaryKeyOrder: 3),
    'chapter_index': (type: 'INTEGER', primaryKeyOrder: 0),
    'payload': (type: 'BLOB', primaryKeyOrder: 0),
    'updated_at': (type: 'INTEGER', primaryKeyOrder: 0),
  };

  static Future<void> migrate(DatabaseExecutor db) async {
    final existingColumns = await db.rawQuery('PRAGMA table_info($tableName)');
    if (existingColumns.isNotEmpty && !_usesCurrentSchema(existingColumns)) {
      // Older development builds used this name for a JSON cache with a
      // different primary key. Pagination data is entirely derived, so replace
      // only this table instead of risking a failed database open or attempting
      // to reinterpret incompatible payloads.
      await db.execute('DROP TABLE $tableName');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName(
        book_id INTEGER NOT NULL,
        book_revision TEXT NOT NULL,
        layout_fingerprint TEXT NOT NULL,
        chapter_index INTEGER NOT NULL,
        payload BLOB NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (book_id, book_revision, layout_fingerprint),
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_reader_pagination_cache_book_revision
      ON $tableName(book_id, book_revision)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_reader_pagination_cache_pruning
      ON $tableName(book_id, updated_at DESC)
    ''');
  }

  static bool _usesCurrentSchema(List<Map<String, Object?>> columns) {
    if (columns.length != _expectedColumns.length) return false;
    final byName = <String, Map<String, Object?>>{
      for (final column in columns) column['name']! as String: column,
    };
    for (final entry in _expectedColumns.entries) {
      final column = byName[entry.key];
      if (column == null ||
          (column['type'] as String?)?.toUpperCase() != entry.value.type ||
          column['notnull'] != 1 ||
          column['pk'] != entry.value.primaryKeyOrder) {
        return false;
      }
    }
    return true;
  }
}
