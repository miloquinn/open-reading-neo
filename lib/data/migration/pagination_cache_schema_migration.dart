import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Adds the bounded, versioned cache for native-reader page boundaries.
class PaginationCacheSchemaMigration {
  const PaginationCacheSchemaMigration._();

  static const int migrationVersion = 22;
  static const String tableName = 'reader_pagination_cache';

  static Future<void> migrate(DatabaseExecutor db) async {
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
}
