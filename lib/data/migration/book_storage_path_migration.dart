import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/services/books/book_storage_paths.dart';

/// Converts only managed book/cover locations. Runs inside SQLite's upgrade
/// transaction so interrupted upgrades cannot leave a partially migrated schema.
class BookStoragePathMigration {
  static const migrationVersion = 25;

  static Future<void> migrate(DatabaseExecutor db, String documentsPath) async {
    final paths = BookStoragePaths(documentsPath);
    final rows = await db.query(
      'books',
      columns: ['id', 'filePath', 'cover_image_path'],
    );
    final batch = db.batch();
    for (final row in rows) {
      final encoded = paths.encodeBookMap(row);
      final changes = <String, Object?>{};
      for (final key in ['filePath', 'cover_image_path']) {
        if (encoded[key] != row[key]) changes[key] = encoded[key];
      }
      if (changes.isNotEmpty) {
        batch.update('books', changes, where: 'id = ?', whereArgs: [row['id']]);
      }
    }
    await batch.commit(noResult: true);
  }
}
