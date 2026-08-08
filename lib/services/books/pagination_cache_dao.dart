import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/migration/pagination_cache_schema_migration.dart';
import '../core/database_service.dart';

typedef PaginationCacheDatabaseProvider = Future<Database> Function();

/// Persists compact native-reader pagination payloads without exposing reader
/// implementation types to the database layer.
class PaginationCacheDao {
  PaginationCacheDao({PaginationCacheDatabaseProvider? databaseProvider})
    : _databaseProvider =
          databaseProvider ?? (() => DatabaseService().database);

  static const int maxLayoutsPerBook = 128;

  final PaginationCacheDatabaseProvider _databaseProvider;

  Future<Map<String, Uint8List>> loadForBook(
    int bookId,
    String bookRevision,
  ) async {
    final db = await _databaseProvider();
    return db.transaction((transaction) async {
      await transaction.delete(
        PaginationCacheSchemaMigration.tableName,
        where: 'book_id = ? AND book_revision != ?',
        whereArgs: [bookId, bookRevision],
      );
      await _prune(transaction, bookId);
      final rows = await transaction.query(
        PaginationCacheSchemaMigration.tableName,
        columns: const ['layout_fingerprint', 'payload'],
        where: 'book_id = ? AND book_revision = ?',
        whereArgs: [bookId, bookRevision],
        orderBy: 'updated_at DESC',
        limit: maxLayoutsPerBook,
      );
      final result = <String, Uint8List>{};
      for (final row in rows) {
        final payload = _payloadBytes(row['payload']);
        if (payload != null) {
          result[row['layout_fingerprint']! as String] = payload;
        }
      }
      return Map<String, Uint8List>.unmodifiable(result);
    });
  }

  Future<void> upsert({
    required int bookId,
    required String bookRevision,
    required String layoutFingerprint,
    required int chapterIndex,
    required Uint8List payload,
  }) async {
    final db = await _databaseProvider();
    await db.transaction((transaction) async {
      await transaction.delete(
        PaginationCacheSchemaMigration.tableName,
        where: 'book_id = ? AND book_revision != ?',
        whereArgs: [bookId, bookRevision],
      );
      await transaction.insert(
        PaginationCacheSchemaMigration.tableName,
        {
          'book_id': bookId,
          'book_revision': bookRevision,
          'layout_fingerprint': layoutFingerprint,
          'chapter_index': chapterIndex,
          'payload': payload,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _prune(transaction, bookId);
    });
  }

  Future<void> deleteForBook(int bookId) async {
    final db = await _databaseProvider();
    await db.delete(
      PaginationCacheSchemaMigration.tableName,
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
  }

  static Future<void> _prune(DatabaseExecutor db, int bookId) {
    return db.rawDelete(
      '''
      DELETE FROM ${PaginationCacheSchemaMigration.tableName}
      WHERE rowid IN (
        SELECT rowid
        FROM ${PaginationCacheSchemaMigration.tableName}
        WHERE book_id = ?
        ORDER BY updated_at DESC, rowid DESC
        LIMIT -1 OFFSET ?
      )
      ''',
      [bookId, maxLayoutsPerBook],
    );
  }

  static Uint8List? _payloadBytes(Object? value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }
}
