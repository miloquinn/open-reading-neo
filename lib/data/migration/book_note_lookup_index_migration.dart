import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BookNoteLookupIndexMigration {
  const BookNoteLookupIndexMigration._();

  static const int migrationVersion = 23;
  static const String indexName = 'idx_book_notes_book_cfi_id';

  static Future<void> migrate(DatabaseExecutor db) => db.execute(
    'CREATE INDEX IF NOT EXISTS $indexName '
    'ON book_notes (book_id, cfi, id DESC)',
  );
}
