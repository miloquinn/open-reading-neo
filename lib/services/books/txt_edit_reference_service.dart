import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/txt_edit_service.dart';
import 'package:xxread/services/core/database_service.dart';

const String txtUnresolvedLocatorMarker = 'openreading:txt-unresolved:';

bool isTxtNoteLocatorResolved(Map<String, dynamic> row) {
  final payload = row['payload_json'] as String?;
  if (payload == null || payload.isEmpty) return true;
  try {
    final values = jsonDecode(payload) as Map;
    return values['txt_locator_status'] != 'unresolved';
  } catch (_) {
    return true;
  }
}

bool isTxtBookmarkLocatorResolved(String? anchorKey) =>
    !(anchorKey?.startsWith(txtUnresolvedLocatorMarker) ?? false);

class TxtEditReferenceService {
  TxtEditReferenceService({Future<Database> Function()? databaseProvider})
    : _databaseProvider =
          databaseProvider ?? (() => DatabaseService().database);

  final Future<Database> Function() _databaseProvider;

  Future<Book> commitRevision({
    required Book book,
    required TxtEditCommit commit,
  }) async {
    final db = await _databaseProvider();
    return db.transaction(
      (transaction) =>
          commitRevisionInTransaction(transaction, book: book, commit: commit),
    );
  }

  Future<Book> commitRevisionInTransaction(
    DatabaseExecutor transaction, {
    required Book book,
    required TxtEditCommit commit,
  }) async {
    final id = book.id;
    if (id == null) throw StateError('TXT edit requires a library book id');
    final rows = await transaction.query(
      'books',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('TXT library book is missing');
    final values = Map<String, dynamic>.from(rows.single);
    final mapping = commit.mapping;
    if (mapping != null) {
      values['last_canonical_locator'] = _mapLocator(
        values['last_canonical_locator'] as String?,
        mapping,
        commit.contentHash,
      );
      values['last_rendered_locator'] = null;
      values['layout_signature'] = null;
      await _migrateNotes(transaction, id, mapping, commit.contentHash);
      await _migrateBookmarks(transaction, id, mapping, commit.contentHash);
    } else if (commit.invalidateAllReferences) {
      values['last_canonical_locator'] = null;
      values['last_rendered_locator'] = null;
      values['layout_signature'] = null;
      await _invalidateAllReferences(transaction, id);
    }
    values
      ..['file_modified_time'] = commit.modifiedAt.millisecondsSinceEpoch
      ..['content_hash'] = commit.contentHash
      ..['text_encoding'] = commit.textEncoding
      ..['cached_content'] = null
      ..['cached_pages'] = null
      ..['table_of_contents'] = null;
    await _updateProgressRevision(
      transaction,
      bookId: id,
      values: values,
      contentHash: commit.contentHash,
    );
    await transaction.update('books', values, where: 'id = ?', whereArgs: [id]);
    return Book.fromMap(values);
  }

  Future<void> _updateProgressRevision(
    DatabaseExecutor db, {
    required int bookId,
    required Map<String, dynamic> values,
    required String contentHash,
  }) async {
    final tables = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: ['sync_local_state'],
      limit: 1,
    );
    if (tables.isEmpty) return;
    final uidRows = await db.query(
      'sync_local_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['frozen_book_uid:$bookId'],
      limit: 1,
    );
    if (uidRows.isEmpty) return;
    final uid = uidRows.single['value'] as String?;
    if (uid == null || uid.isEmpty) return;
    for (final prefix in const ['progress_event:', 'progress_head:']) {
      final key = '$prefix$uid';
      final rows = await db.query(
        'sync_local_state',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      try {
        final event = (jsonDecode(rows.single['value']! as String) as Map)
            .cast<String, dynamic>();
        event
          ..['current_page'] = values['currentPage']
          ..['reading_progress'] = values['reading_progress']
          ..['canonical_locator'] = values['last_canonical_locator']
          ..['locator_revision'] = contentHash;
        await db.update(
          'sync_local_state',
          {'value': jsonEncode(event)},
          where: 'key = ?',
          whereArgs: [key],
        );
      } catch (_) {
        // A damaged optional sync marker must not roll back a TXT edit.
      }
    }
  }

  Future<void> _invalidateAllReferences(DatabaseExecutor db, int bookId) async {
    final notes = await db.query(
      'book_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    for (final raw in notes) {
      final row = Map<String, dynamic>.from(raw)
        ..['canonical_locator'] = null
        ..['start_offset'] = null
        ..['end_offset'] = null
        ..['payload_json'] = _markUnresolved(raw['payload_json'] as String?);
      await db.update(
        'book_notes',
        row,
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    final bookmarks = await db.query(
      'bookmarks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
    for (final raw in bookmarks) {
      final row = Map<String, dynamic>.from(raw);
      final oldKey = row['anchor_key'] as String? ?? '';
      row
        ..['canonical_locator'] = null
        ..['anchor_key'] = '$txtUnresolvedLocatorMarker$oldKey';
      await db.update(
        'bookmarks',
        row,
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<void> _migrateNotes(
    DatabaseExecutor db,
    int bookId,
    TxtEditRevisionMapping mapping,
    String contentHash,
  ) async {
    final rows = await db.query(
      'book_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final locator = _decodeLocator(row['canonical_locator'] as String?);
      final chapterId = locator?.chapterId ?? locator?.textAnchor?.chapterId;
      if (mapping.invalidatesChapter(chapterId)) {
        row
          ..['canonical_locator'] = null
          ..['start_offset'] = null
          ..['end_offset'] = null
          ..['payload_json'] = _markUnresolved(row['payload_json'] as String?);
        await db.update(
          'book_notes',
          row,
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        continue;
      }
      if (chapterId != mapping.chapterId) continue;
      final quote = (row['content'] as String? ?? '').trim();
      final oldStart =
          (row['start_offset'] as num?)?.toInt() ??
          locator?.textAnchor?.startOffsetUtf16;
      final resolved = _resolveRange(mapping, oldStart, quote);
      if (resolved == null) {
        row
          ..['canonical_locator'] = null
          ..['start_offset'] = null
          ..['end_offset'] = null
          ..['payload_json'] = _markUnresolved(row['payload_json'] as String?);
      } else {
        row
          ..['canonical_locator'] = _locatorJson(
            chapterId: mapping.chapterId,
            offset: resolved,
            quote: quote,
            textLength: mapping.newText.length,
            contentHash: contentHash,
          )
          ..['start_offset'] = resolved
          ..['end_offset'] = resolved + quote.length
          ..['payload_json'] = _clearUnresolved(row['payload_json'] as String?);
      }
      await db.update(
        'book_notes',
        row,
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<void> _migrateBookmarks(
    DatabaseExecutor db,
    int bookId,
    TxtEditRevisionMapping mapping,
    String contentHash,
  ) async {
    final rows = await db.query(
      'bookmarks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final locator = _decodeLocator(row['canonical_locator'] as String?);
      final chapterId = locator?.chapterId ?? locator?.textAnchor?.chapterId;
      if (mapping.invalidatesChapter(chapterId)) {
        final oldKey = row['anchor_key'] as String? ?? '';
        row
          ..['canonical_locator'] = null
          ..['anchor_key'] = '$txtUnresolvedLocatorMarker$oldKey';
        await db.update(
          'bookmarks',
          row,
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        continue;
      }
      if (chapterId != mapping.chapterId) continue;
      final quote = (row['excerpt'] as String? ?? '').trim();
      final oldStart = locator?.textAnchor?.startOffsetUtf16;
      final resolved = _resolveRange(mapping, oldStart, quote);
      if (resolved == null) {
        final oldKey = row['anchor_key'] as String? ?? '';
        row
          ..['canonical_locator'] = null
          ..['anchor_key'] = '$txtUnresolvedLocatorMarker$oldKey';
      } else {
        row
          ..['canonical_locator'] = _locatorJson(
            chapterId: mapping.chapterId,
            offset: resolved,
            quote: quote,
            textLength: mapping.newText.length,
            contentHash: contentHash,
          )
          ..['anchor_key'] = '${mapping.chapterId}:$resolved';
      }
      await db.update(
        'bookmarks',
        row,
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }
}

int? _resolveRange(
  TxtEditRevisionMapping mapping,
  int? oldStart,
  String quote,
) {
  if (oldStart != null &&
      quote.isNotEmpty &&
      oldStart >= 0 &&
      oldStart + quote.length <= mapping.oldText.length &&
      mapping.oldText.substring(oldStart, oldStart + quote.length) == quote) {
    final oldEnd = oldStart + quote.length;
    if (oldEnd <= mapping.commonPrefixLength) return oldStart;
    final oldSuffixStart = mapping.oldLength - mapping.commonSuffixLength;
    if (oldStart >= oldSuffixStart) {
      return mapping.newText.length - (mapping.oldLength - oldStart);
    }
  }
  // A quote can occur more than once across revisions. Once its original
  // range overlaps the edit, searching the new text would guess which
  // occurrence the user meant and can silently jump to a different passage.
  return null;
}

String? _mapLocator(
  String? raw,
  TxtEditRevisionMapping mapping,
  String contentHash,
) {
  final locator = _decodeLocator(raw);
  if (locator == null) return null;
  final chapterId = locator.chapterId ?? locator.textAnchor?.chapterId;
  if (mapping.invalidatesChapter(chapterId)) return null;
  if (chapterId != mapping.chapterId) return raw;
  final anchor = locator.textAnchor;
  final quote = anchor?.quote.trim() ?? '';
  final resolved = _resolveRange(mapping, anchor?.startOffsetUtf16, quote);
  if (resolved == null) return null;
  return _locatorJson(
    chapterId: mapping.chapterId,
    offset: resolved,
    quote: quote,
    textLength: mapping.newText.length,
    contentHash: contentHash,
  );
}

CanonicalLocator? _decodeLocator(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return LocatorCodec.decodeCanonicalLocator(raw);
}

String _locatorJson({
  required String chapterId,
  required int offset,
  required String quote,
  required int textLength,
  required String contentHash,
}) => LocatorCodec.encodeCanonicalLocator(
  CanonicalLocator.fromComponents(
    format: BookFormat.txt,
    chapterId: chapterId,
    offset: offset,
    excerpt: quote,
    progression: textLength == 0 ? 0 : offset / textLength,
    contentSignature: contentHash,
  ),
);

String _markUnresolved(String? raw) {
  final values = _payload(raw);
  values['txt_locator_status'] = 'unresolved';
  return jsonEncode(values);
}

String? _clearUnresolved(String? raw) {
  final values = _payload(raw)..remove('txt_locator_status');
  return values.isEmpty ? null : jsonEncode(values);
}

Map<String, dynamic> _payload(String? raw) {
  if (raw == null || raw.isEmpty) return <String, dynamic>{};
  try {
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return <String, dynamic>{'legacy_payload': raw};
  }
}
