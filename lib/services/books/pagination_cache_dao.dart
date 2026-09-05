import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/migration/pagination_cache_schema_migration.dart';
import '../core/database_service.dart';

typedef PaginationCacheDatabaseProvider = Future<Database> Function();

/// Shared, disposable boundary storage. Payloads never contain chapter text.
class PaginationCacheDao {
  PaginationCacheDao({
    PaginationCacheDatabaseProvider? databaseProvider,
    this.maxEntries = 4096,
    this.maxBytes = 32 * 1024 * 1024,
  }) : _databaseProvider =
           databaseProvider ?? (() => DatabaseService().database);

  static const int maxLayoutsPerBook = 128;
  static int _epoch = 0;
  static int get epoch => _epoch;
  static int _nextRevisionEpoch = 0;
  static final Map<String, ({String revision, int epoch})> _revisions = {};

  /// Capture before queueing work so an older content revision cannot replace
  /// a newer one merely because its disk operation completed later.
  static int revisionEpochFor(String identity, String revision) {
    final previous = _revisions.remove(identity);
    final token = previous?.revision == revision
        ? previous!.epoch
        : ++_nextRevisionEpoch;
    _revisions[identity] = (revision: revision, epoch: token);
    while (_revisions.length > 8192) {
      _revisions.remove(_revisions.keys.first);
    }
    return token;
  }

  static bool _isCurrentRevision(String identity, int token) =>
      _revisions[identity]?.epoch == token;
  static const _table = PaginationCacheSchemaMigration.tableName;
  final PaginationCacheDatabaseProvider _databaseProvider;
  final int maxEntries;
  final int maxBytes;

  Future<Map<String, Uint8List>> loadForBook(int bookId, String bookRevision) =>
      loadForIdentity('local:$bookId', bookRevision);

  Future<Map<String, Uint8List>> loadForIdentity(
    String identity,
    String bookRevision,
  ) async {
    final generation = epoch;
    final revisionToken = revisionEpochFor(identity, bookRevision);
    final db = await _databaseProvider();
    return db.transaction((transaction) async {
      if (generation != epoch || !_isCurrentRevision(identity, revisionToken)) {
        return <String, Uint8List>{};
      }
      await transaction.delete(
        _table,
        where: 'cache_identity = ? AND book_revision != ?',
        whereArgs: [identity, bookRevision],
      );
      if (generation != epoch || !_isCurrentRevision(identity, revisionToken)) {
        return <String, Uint8List>{};
      }
      await transaction.update(
        _table,
        {'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'cache_identity = ? AND book_revision = ?',
        whereArgs: [identity, bookRevision],
      );
      await _prune(transaction, identity);
      final rows = await transaction.query(
        _table,
        columns: const ['layout_fingerprint', 'payload'],
        where: 'cache_identity = ? AND book_revision = ?',
        whereArgs: [identity, bookRevision],
        orderBy: 'updated_at DESC',
        limit: maxLayoutsPerBook,
      );
      if (generation != epoch || !_isCurrentRevision(identity, revisionToken)) {
        return <String, Uint8List>{};
      }
      return Map<String, Uint8List>.unmodifiable({
        for (final row in rows)
          if (_payloadBytes(row['payload']) case final Uint8List payload)
            row['layout_fingerprint']! as String: payload,
      });
    });
  }

  Future<void> upsert({
    required int bookId,
    required String bookRevision,
    required String layoutFingerprint,
    required int chapterIndex,
    required Uint8List payload,
    int? expectedEpoch,
    int? expectedRevisionEpoch,
  }) => upsertForIdentity(
    identity: 'local:$bookId',
    localBookId: bookId,
    bookRevision: bookRevision,
    layoutFingerprint: layoutFingerprint,
    chapterIndex: chapterIndex,
    payload: payload,
    expectedEpoch: expectedEpoch,
    expectedRevisionEpoch: expectedRevisionEpoch,
  );

  Future<void> upsertForIdentity({
    required String identity,
    int? localBookId,
    required String bookRevision,
    required String layoutFingerprint,
    required int chapterIndex,
    required Uint8List payload,
    int? expectedEpoch,
    int? expectedRevisionEpoch,
  }) async {
    final generation = expectedEpoch ?? epoch;
    if (generation != epoch || payload.lengthInBytes > maxBytes) return;
    final revisionToken =
        expectedRevisionEpoch ?? revisionEpochFor(identity, bookRevision);
    if (!_isCurrentRevision(identity, revisionToken)) return;
    final db = await _databaseProvider();
    await db.transaction((transaction) async {
      if (generation != epoch || !_isCurrentRevision(identity, revisionToken)) {
        return;
      }
      await transaction.delete(
        _table,
        where: 'cache_identity = ? AND book_revision != ?',
        whereArgs: [identity, bookRevision],
      );
      if (generation != epoch || !_isCurrentRevision(identity, revisionToken)) {
        return;
      }
      await transaction.insert(_table, {
        'cache_identity': identity,
        'book_id': localBookId,
        'book_revision': bookRevision,
        'layout_fingerprint': layoutFingerprint,
        'chapter_index': chapterIndex,
        'payload': payload,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _prune(transaction, identity);
    });
  }

  Future<void> deleteForBook(int bookId) async {
    final db = await _databaseProvider();
    await db.delete(_table, where: 'book_id = ?', whereArgs: [bookId]);
  }

  Future<int> payloadSizeBytes() async {
    final db = await _databaseProvider();
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(length(payload)), 0) AS bytes FROM $_table',
    );
    return (rows.single['bytes'] as num).toInt();
  }

  Future<void> clearAll() async {
    _epoch++;
    _revisions.clear();
    final db = await _databaseProvider();
    await db.delete(_table);
  }

  Future<void> _prune(DatabaseExecutor db, String identity) async {
    await db.rawDelete(
      '''
      DELETE FROM $_table WHERE rowid IN (
        SELECT rowid FROM $_table WHERE cache_identity = ?
        ORDER BY updated_at DESC, rowid DESC LIMIT -1 OFFSET ?
      )''',
      [identity, maxLayoutsPerBook],
    );
    final totals = (await db.rawQuery(
      'SELECT COUNT(*) AS entries, COALESCE(SUM(length(payload)), 0) AS bytes FROM $_table',
    )).single;
    if ((totals['entries'] as num) <= maxEntries &&
        (totals['bytes'] as num) <= maxBytes) {
      return;
    }
    // Read individual sizes only when the shared budget needs eviction.
    final rows = await db.rawQuery(
      'SELECT rowid, length(payload) AS bytes FROM $_table ORDER BY updated_at DESC, rowid DESC',
    );
    var bytes = 0;
    var retained = 0;
    for (final row in rows) {
      final size = (row['bytes'] as num).toInt();
      if (retained >= maxEntries || bytes + size > maxBytes) {
        await db.delete(_table, where: 'rowid = ?', whereArgs: [row['rowid']]);
      } else {
        retained++;
        bytes += size;
      }
    }
  }

  static Uint8List? _payloadBytes(Object? value) {
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }
}
