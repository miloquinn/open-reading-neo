import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Adds the bounded, versioned cache for local and online reader page boundaries.
class PaginationCacheSchemaMigration {
  const PaginationCacheSchemaMigration._();

  static const int migrationVersion = 24;
  static const String tableName = 'reader_pagination_cache';

  static const Map<String, ({String type, int primaryKeyOrder})>
  _expectedColumns = {
    'cache_identity': (type: 'TEXT', primaryKeyOrder: 1),
    'book_id': (type: 'INTEGER', primaryKeyOrder: 0),
    'book_revision': (type: 'TEXT', primaryKeyOrder: 2),
    'layout_fingerprint': (type: 'TEXT', primaryKeyOrder: 3),
    'chapter_index': (type: 'INTEGER', primaryKeyOrder: 0),
    'payload': (type: 'BLOB', primaryKeyOrder: 0),
    'updated_at': (type: 'INTEGER', primaryKeyOrder: 0),
  };

  static Future<void> migrate(DatabaseExecutor db) async {
    final existingColumns = await db.rawQuery('PRAGMA table_info($tableName)');
    final preserveLocal = _usesLegacyNativeSchema(existingColumns);
    if (existingColumns.isNotEmpty && !_usesCurrentSchema(existingColumns)) {
      // Older development builds used this name for a JSON cache with a
      // different primary key. Pagination data is entirely derived, so replace
      // only incompatible derived data. The previous binary format can retain
      // its boundaries by adding the local identity namespace below.
      await db.execute(
        preserveLocal
            ? 'ALTER TABLE $tableName RENAME TO ${tableName}_local_v22'
            : 'DROP TABLE $tableName',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName(
        cache_identity TEXT NOT NULL,
        book_id INTEGER,
        book_revision TEXT NOT NULL,
        layout_fingerprint TEXT NOT NULL,
        chapter_index INTEGER NOT NULL,
        payload BLOB NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (cache_identity, book_revision, layout_fingerprint),
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
    if (preserveLocal) {
      await db.execute('''
        INSERT INTO $tableName(cache_identity, book_id, book_revision,
          layout_fingerprint, chapter_index, payload, updated_at)
        SELECT 'local:' || book_id, book_id, book_revision,
          layout_fingerprint, chapter_index, payload, updated_at
        FROM ${tableName}_local_v22
      ''');
      await db.execute('DROP TABLE ${tableName}_local_v22');
    }
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_reader_pagination_cache_book_revision
      ON $tableName(cache_identity, book_revision)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_reader_pagination_cache_pruning
      ON $tableName(updated_at DESC)
    ''');
  }

  static bool _usesLegacyNativeSchema(List<Map<String, Object?>> columns) {
    if (columns.length != _expectedColumns.length - 1) return false;
    final byName = {for (final column in columns) column['name']: column};
    for (final entry in _expectedColumns.entries) {
      if (entry.key == 'cache_identity') continue;
      final column = byName[entry.key];
      if (column == null ||
          column['type'] != entry.value.type ||
          column['notnull'] != 1 ||
          column['pk'] !=
              (entry.key == 'book_id' ? 1 : entry.value.primaryKeyOrder)) {
        return false;
      }
    }
    return true;
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
          column['notnull'] != (entry.key == 'book_id' ? 0 : 1) ||
          column['pk'] != entry.value.primaryKeyOrder) {
        return false;
      }
    }
    return true;
  }
}
