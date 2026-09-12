import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book.dart';
import '../books/book_storage_codec.dart';
import '../core/database_service.dart';

const _frozenBookUidPrefix = 'frozen_book_uid:';
final Map<String, String> _bookUidCache = <String, String>{};

/// Returns the immutable sync identity assigned to a library book.
///
/// File bytes are used only when assigning the identity for the first time.
/// Later TXT edits therefore change the content revision without creating a
/// different synced book.
Future<String> stableBookUid(
  Book book, {
  DatabaseService? databaseService,
}) async {
  final id = book.id;
  if (id == null) return initialBookUidForMap(book.toMap());
  final db = await (databaseService ?? DatabaseService()).database;
  final rows = await db.query(
    'books',
    where: 'id = ?',
    whereArgs: [id],
    limit: 1,
  );
  if (rows.isEmpty) return initialBookUidForMap(book.toMap());
  return stableBookUidForMap(db, rows.first);
}

Future<String> stableBookUidForMap(
  DatabaseExecutor db,
  Map<String, Object?> row,
) async {
  final id = row['id'] as int?;
  await _ensureIdentityState(db);
  if (id != null) {
    final frozenRows = await db.query(
      'sync_local_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['$_frozenBookUidPrefix$id'],
      limit: 1,
    );
    if (frozenRows.isNotEmpty) {
      final frozen = frozenRows.first['value'] as String?;
      if (frozen != null && frozen.isNotEmpty) return frozen;
    }
    // File bindings bootstrap identity only once. They must never rename a
    // book that already owns a frozen identity, even when accounts change.
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_book_files'",
    );
    if (tables.isNotEmpty) {
      final bindings = await db.query(
        'sync_book_files',
        columns: ['book_uid'],
        where: 'local_book_id = ?',
        whereArgs: [id],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      final bound = bindings.isEmpty
          ? null
          : bindings.first['book_uid'] as String?;
      if (bound != null && bound.isNotEmpty) {
        return freezeBookUid(db, id, bound);
      }
    }
  }
  final assigned = await initialBookUidForMap(row);
  return id == null ? assigned : freezeBookUid(db, id, assigned);
}

/// Attaches a local record to its permanent identity, including restored books.
/// Conflicting identities are rejected instead of silently reassigning a book.
Future<String> freezeBookUid(
  DatabaseExecutor db,
  int bookId,
  String uid,
) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid');
  await _ensureIdentityState(db);
  final key = '$_frozenBookUidPrefix$bookId';
  await db.insert('sync_local_state', {
    'key': key,
    'value': uid,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  final rows = await db.query(
    'sync_local_state',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [key],
    limit: 1,
  );
  final existing = rows.single['value'] as String;
  if (existing != uid) {
    throw StateError('A library book already has a different frozen identity.');
  }
  return existing;
}

Future<void> _ensureIdentityState(DatabaseExecutor db) => db.execute(
  'CREATE TABLE IF NOT EXISTS sync_local_state('
  'key TEXT PRIMARY KEY, value TEXT NOT NULL)',
);

/// Computes an identity only for first assignment, before it is frozen.
Future<String> initialBookUidForMap(
  Map<String, Object?> row, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  final sourceId = row['source_id'] as String?;
  final sourceBookId = row['source_book_id'] as String?;
  if (sourceId != null &&
      sourceId.isNotEmpty &&
      sourceBookId != null &&
      sourceBookId.isNotEmpty) {
    return 'source:$sourceId:$sourceBookId';
  }
  final path = row['filePath'] as String?;
  if (path != null && path.isNotEmpty) {
    final resolvedPath = await resolveBookStoragePath(
      path,
      documentsDirectory: documentsDirectory,
    );
    final file = File(resolvedPath);
    try {
      if (await file.exists()) {
        final stat = await file.stat();
        final cacheKey =
            '$resolvedPath|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
        final cached = _bookUidCache[cacheKey];
        if (cached != null) return cached;
        final digest = await sha256.bind(file.openRead()).first;
        final uid = 'sha256:$digest';
        _bookUidCache[cacheKey] = uid;
        return uid;
      }
    } on FileSystemException {
      // Keep metadata sync available when a document provider is temporarily
      // inaccessible or a file disappears between stat and read.
    }
  }
  final legacy = row['content_hash'] as String?;
  if (legacy != null && legacy.isNotEmpty) return 'legacy-hash:$legacy';
  return 'local-meta:${sha256.convert(utf8.encode('${row['title']}|${row['author']}|${row['format']}|${row['importDate']}'))}';
}
