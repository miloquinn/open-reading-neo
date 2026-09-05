import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book.dart';
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
  if (id != null) {
    final bindings = await db.query(
      'sync_book_files',
      columns: ['book_uid'],
      where: 'local_book_id = ?',
      whereArgs: [id],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (bindings.isNotEmpty) {
      final bound = bindings.first['book_uid'] as String?;
      if (bound != null && bound.isNotEmpty) {
        await _freezeUid(db, id, bound);
        return bound;
      }
    }

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
  }

  final assigned = await initialBookUidForMap(row);
  if (id != null) await _freezeUid(db, id, assigned);
  return assigned;
}

Future<void> _freezeUid(DatabaseExecutor db, int bookId, String uid) {
  return db.insert('sync_local_state', {
    'key': '$_frozenBookUidPrefix$bookId',
    'value': uid,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// Computes the legacy deterministic identity used for first assignment.
Future<String> initialBookUidForMap(Map<String, Object?> row) async {
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
    final file = File(path);
    try {
      if (await file.exists()) {
        final stat = await file.stat();
        final cacheKey =
            '$path|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
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
