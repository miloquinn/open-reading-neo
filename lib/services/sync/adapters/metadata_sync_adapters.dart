import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_reading_progress.dart';
import '../../../book_sources/services/book_source_registry.dart';
import '../../../core/reader/paged_image_reader_settings.dart';
import '../../../core/reader/reader_custom_theme.dart';
import '../../../core/reader/reader_layout.dart';
import '../../../core/reader/reader_settings.dart';
import '../../../core/reader/reader_tap_zones.dart';
import '../../../core/reader/reader_theme_order.dart';
import '../../../utils/reader_themes.dart';
import '../../core/database_service.dart';
import '../../reader/replace_rule_service.dart';
import '../sync_change_store.dart';
import '../sync_clock.dart';
import '../sync_dataset_catalog.dart';
import '../sync_models.dart';
import '../sync_protocol.dart';
import '../book_sync_identity.dart';
import '../reading_progress_event.dart';
import '../reading_progress_sync_service.dart';

abstract interface class MetadataSyncAdapter {
  String get dataset;
  Future<void> scan(HybridLogicalClock clock);
  Future<void> validate(SyncOperation operation);

  /// Returns whether the record was materialized into the local business
  /// store. A false result keeps it queued for a later dependency/scope retry.
  Future<bool> apply(Transaction txn, SyncOperation operation);
}

typedef SyncDatabaseProvider = Future<Database> Function();

class MetadataSyncAdapters {
  MetadataSyncAdapters({
    required SyncChangeStore store,
    DatabaseService? databaseService,
    SyncDatabaseProvider? database,
    BookSourceRegistry? bookSourceRegistry,
    BookSourceReadingProgressStore? sourceProgressStore,
    ReplaceRuleService? replaceRuleService,
    Iterable<MetadataSyncAdapter>? registeredAdapters,
  }) : _databaseProvider =
           database ?? (() => (databaseService ?? DatabaseService()).database),
       _store = store,
       adapters = registeredAdapters == null
           ? []
           : List<MetadataSyncAdapter>.of(registeredAdapters) {
    if (registeredAdapters == null) {
      final registry = bookSourceRegistry ?? BookSourceRegistry();
      final progressStore =
          sourceProgressStore ?? const BookSourceReadingProgressStore();
      adapters.addAll([
        BookSourcesSyncAdapter(store, registry),
        BooksSyncAdapter(store, _databaseProvider),
        ProgressSyncAdapter(store, _databaseProvider, progressStore),
        BookmarksSyncAdapter(store, _databaseProvider),
        NotesSyncAdapter(store, _databaseProvider),
        ReadingSessionsSyncAdapter(store, _databaseProvider),
        ReaderSettingsSyncAdapter(store, _databaseProvider),
        ReaderThemesSyncAdapter(store),
        ReplaceRulesSyncAdapter(store, service: replaceRuleService),
      ]);
    }
  }

  final SyncDatabaseProvider _databaseProvider;
  final SyncChangeStore _store;
  final List<MetadataSyncAdapter> adapters;

  Future<void> scan(WebDavSyncScope scope, HybridLogicalClock clock) async {
    for (final adapter in adapters) {
      final dataset = SyncDataset.fromRemoteName(adapter.dataset);
      if (dataset == null || !SyncDatasetCatalog.isEnabled(dataset, scope)) {
        continue;
      }
      await _materializePreviouslyRemoteRecords(adapter);
      await adapter.scan(clock);
    }
    final permanentlyBlocked = (await _store.dirtyRecords())
        .where(
          (record) => SyncDatasetCatalog.isPermanentlyBlockedRecord(
            dataset: record.dataset,
            recordId: record.recordId,
            entityKey: record.entityKey,
            payload: record.payload,
          ),
        )
        .toList(growable: false);
    // These records were staged by older builds or represent private source
    // identities. Marking the local mirrors clean drops only unpublished work;
    // immutable remote history remains readable for compatibility.
    await _store.markUploaded(permanentlyBlocked);
  }

  Future<void> _materializePreviouslyRemoteRecords(
    MetadataSyncAdapter adapter,
  ) async {
    final records = await _store.recordsForDataset(adapter.dataset);
    final pending = <SyncRecord>[];
    for (final record in records) {
      final observed = await _store.getState(
        'locally_observed:${adapter.dataset}:${record.recordId}',
      );
      // A previously observed record that disappeared locally represents a
      // real local deletion. Re-applying it here would resurrect it before the
      // scanner can emit its tombstone.
      if (observed != '1' && observed != record.hlc) pending.add(record);
    }
    if (pending.isEmpty) return;
    final db = await _databaseProvider();
    for (final record in pending) {
      await db.transaction((txn) async {
        await adapter.validate(record.toOperation());
        final materialized = await adapter.apply(txn, record.toOperation());
        if (!materialized) return;
        await txn.insert('sync_local_state', {
          'key': 'locally_observed:${adapter.dataset}:${record.recordId}',
          'value': record.hlc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    }
  }

  Future<bool> apply(
    Transaction txn,
    SyncOperation operation, {
    WebDavSyncScope? scope,
  }) async {
    final dataset = SyncDataset.fromRemoteName(operation.dataset);
    if (dataset == null || !SyncDatasetCatalog.isSupported(dataset)) {
      return false;
    }
    if (scope != null && !SyncDatasetCatalog.isEnabled(dataset, scope)) {
      return false;
    }
    final adapter = adapters.where((item) => item.dataset == operation.dataset);
    if (adapter.isEmpty) return false;
    return adapter.first.apply(txn, operation);
  }

  Future<void> validate(SyncOperation operation) async {
    final dataset = SyncDataset.fromRemoteName(operation.dataset);
    if (dataset == null || !SyncDatasetCatalog.isSupported(dataset)) return;
    final adapter = adapters.where((item) => item.dataset == operation.dataset);
    if (adapter.isNotEmpty) await adapter.first.validate(operation);
  }

  Future<SyncOperation> normalizeRemoteWinner(
    Transaction txn,
    SyncOperation operation,
  ) async {
    final adapter = adapters.where((item) => item.dataset == operation.dataset);
    if (adapter.isEmpty || adapter.first is! NotesSyncAdapter) return operation;
    return (adapter.first as NotesSyncAdapter).normalizeRemoteWinner(
      txn,
      operation,
    );
  }

  Future<void> cleanupRemoteWinnerAliases(
    Transaction txn,
    SyncOperation operation,
  ) async {
    final adapter = adapters.where((item) => item.dataset == operation.dataset);
    if (adapter.isEmpty || adapter.first is! NotesSyncAdapter) return;
    await (adapter.first as NotesSyncAdapter).cleanupRemoteWinnerAliases(
      txn,
      operation,
    );
  }
}

abstract class _BaseAdapter implements MetadataSyncAdapter {
  _BaseAdapter(this.store, this.database);

  final SyncChangeStore store;
  final SyncDatabaseProvider database;

  Future<Map<int, String>> bookUids() async {
    final db = await database();
    final rows = await db.query('books');
    final result = <int, String>{};
    for (final row in rows) {
      final id = row['id'] as int?;
      if (_rowHasPrivateSourceIdentity(row)) continue;
      if (id != null) result[id] = await stableBookUidForMap(db, row);
    }
    return result;
  }

  Future<int?> localBookId(DatabaseExecutor db, String bookUid) async {
    final rows = await db.query('books');
    for (final row in rows) {
      if (await stableBookUidForMap(db, row) == bookUid) {
        return row['id'] as int?;
      }
    }
    return null;
  }

  Future<void> tombstoneMissing(
    Set<String> seen,
    HybridLogicalClock clock,
  ) async {
    for (final record in await store.recordsForDataset(dataset)) {
      final locallyObserved = await store.getState(
        'locally_observed:$dataset:${record.recordId}',
      );
      if (!record.deleted &&
          locallyObserved != null &&
          !seen.contains(record.recordId)) {
        await store.recordLocal(
          dataset: dataset,
          recordId: record.recordId,
          entityKey: record.entityKey,
          payload: record.payload,
          deleted: true,
          clock: clock,
        );
      }
    }
  }
}

class BookSourcesSyncAdapter implements MetadataSyncAdapter {
  BookSourcesSyncAdapter(this.store, this.registry);

  final SyncChangeStore store;
  final BookSourceRegistry registry;

  @override
  String get dataset => 'book_sources';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final sources = await registry.load();
    final seen = <String>{};
    for (final source in sources) {
      final payload = _publicBookSourceSyncPayload(source);
      if (payload == null) continue;
      final recordId = stableRecordId('book_source', source.id);
      seen.add(recordId);
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: source.id,
        payload: payload,
        deleted: false,
        clock: clock,
      );
    }
    for (final record in await store.recordsForDataset(dataset)) {
      final locallyObserved = await store.getState(
        'locally_observed:$dataset:${record.recordId}',
      );
      if (!record.deleted &&
          locallyObserved != null &&
          !seen.contains(record.recordId)) {
        await store.recordLocal(
          dataset: dataset,
          recordId: record.recordId,
          entityKey: record.entityKey,
          payload: record.payload,
          deleted: true,
          clock: clock,
        );
      }
    }
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId !=
        stableRecordId('book_source', operation.entityKey)) {
      throw _corruptSyncData('A synced book source has an invalid identity.');
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced book source is missing data.');
    }
    try {
      final source = RegisteredBookSource.fromJson(payload);
      if (source.id != operation.entityKey) throw const FormatException();
    } catch (_) {
      throw _corruptSyncData('A synced book source contains invalid data.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.deleted) {
      await registry.remove(operation.entityKey);
      return true;
    }
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced book source is missing data.');
    }
    late final RegisteredBookSource source;
    try {
      source = RegisteredBookSource.fromJson(payload);
    } catch (_) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'A synced book source contains invalid data.',
      );
    }
    if (source.id != operation.entityKey ||
        operation.recordId != stableRecordId('book_source', source.id)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'A synced book source has an invalid identity.',
      );
    }
    await registry.applySynced(source);
    return true;
  }
}

class BooksSyncAdapter extends _BaseAdapter {
  BooksSyncAdapter(super.store, super.database);

  @override
  String get dataset => 'books';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final db = await database();
    final rows = await db.query('books');
    final seen = <String>{};
    for (final row in rows) {
      if (_rowHasPrivateSourceIdentity(row)) continue;
      final uid = await stableBookUidForMap(db, row);
      seen.add(uid);
      final fileRows = await db.query(
        'sync_book_files',
        where: 'book_uid = ? AND sync_enabled = 1',
        whereArgs: [uid],
        limit: 1,
      );
      final file = fileRows.isEmpty ? null : fileRows.first;
      final sourceSnapshot = _publicBookSourceSnapshot(row['source_json']);
      final sourceBookSnapshot = _publicSourceBookSnapshot(
        row['source_book_json'],
      );
      final payload = <String, dynamic>{
        'sync_schema': 1,
        'book_uid': uid,
        'title': row['title'],
        'author': row['author'],
        'format': row['format'],
        'import_date': row['importDate'],
        'storage_type': row['storage_type'],
        'source_id': row['source_id'],
        'source_book_id': row['source_book_id'],
        ...bookFileSyncPayload(file),
      };
      if (sourceSnapshot != null) payload['source_json'] = sourceSnapshot;
      if (sourceBookSnapshot != null) {
        payload['source_book_json'] = sourceBookSnapshot;
      }
      await store.recordLocal(
        dataset: dataset,
        recordId: uid,
        entityKey: uid,
        payload: payload,
        deleted: false,
        clock: clock,
      );
    }
    await tombstoneMissing(seen, clock);
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId != operation.entityKey ||
        operation.entityKey.isEmpty) {
      throw _corruptSyncData('A synced book has an invalid identity.');
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced book is missing data.');
    }
    for (final key in const [
      'title',
      'author',
      'format',
      'storage_type',
      'source_id',
      'source_book_id',
      'source_json',
      'source_book_json',
    ]) {
      final value = payload[key];
      if (value != null && value is! String) {
        throw _corruptSyncData('A synced book contains an invalid value.');
      }
    }
    if (payload['import_date'] != null && payload['import_date'] is! num) {
      throw _corruptSyncData('A synced book contains an invalid date.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    final id = await localBookId(txn, operation.entityKey);
    if (operation.deleted) {
      if (id == null) return true;
      final rows = await txn.query(
        'books',
        columns: ['storage_type'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isNotEmpty && rows.first['storage_type'] == 'online') {
        await txn.delete('books', where: 'id = ?', whereArgs: [id]);
      }
      return true;
    }
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced book is missing data.');
    }
    final sourceId = _nonEmptyString(payload['source_id']);
    final sourceBookId = _nonEmptyString(payload['source_book_id']);
    final sourceJson = _nonEmptyString(payload['source_json']);
    final sourceBookJson = _nonEmptyString(payload['source_book_json']);
    final restorableOnline =
        payload['storage_type'] == 'online' &&
        sourceId != null &&
        sourceBookId != null &&
        sourceJson != null &&
        sourceBookJson != null;
    if (id == null) {
      if (!restorableOnline) return false;
      await txn.insert('books', {
        'title': _nonEmptyString(payload['title']) ?? 'Untitled',
        'author': payload['author'] as String? ?? '',
        'filePath': '',
        'format': _nonEmptyString(payload['format']) ?? 'source',
        'currentPage': 0,
        'totalPages': 1,
        'importDate':
            (payload['import_date'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        'storage_type': 'online',
        'source_id': sourceId,
        'source_book_id': sourceBookId,
        'source_json': sourceJson,
        'source_book_json': sourceBookJson,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return true;
    }
    final rows = await txn.query(
      'books',
      columns: ['storage_type'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final values = <String, Object?>{
      'title': payload['title'],
      'author': payload['author'],
    };
    if (restorableOnline) {
      values.addAll({
        'source_id': sourceId,
        'source_book_id': sourceBookId,
        'source_json': sourceJson,
        'source_book_json': sourceBookJson,
      });
      if (rows.first['storage_type'] == 'online') {
        values.addAll({
          'filePath': '',
          'format': _nonEmptyString(payload['format']) ?? 'source',
          'storage_type': 'online',
        });
      }
    }
    await txn.update('books', values, where: 'id = ?', whereArgs: [id]);
    return true;
  }
}

Map<String, Object?> bookFileSyncPayload(Map<String, Object?>? file) {
  if (file == null) return const {};
  return {
    'file_available': true,
    'file_size': file['file_size'],
    'file_name': file['file_name'],
    'blob_sha256': file['blob_sha256'],
    'remote_path': file['remote_path'],
    if (file['cover_remote_path'] != null) 'cover_available': true,
    if (file['cover_file_size'] != null)
      'cover_file_size': file['cover_file_size'],
    if (file['cover_file_name'] != null)
      'cover_file_name': file['cover_file_name'],
    if (file['cover_blob_sha256'] != null)
      'cover_blob_sha256': file['cover_blob_sha256'],
    if (file['cover_remote_path'] != null)
      'cover_remote_path': file['cover_remote_path'],
  };
}

class ProgressSyncAdapter extends _BaseAdapter {
  ProgressSyncAdapter(super.store, super.database, this.progressStore);

  final BookSourceReadingProgressStore progressStore;

  @override
  String get dataset => 'progress';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final db = await database();
    final rows = await db.query('books');
    final mirrored = <String, SyncRecord>{
      for (final record in await store.recordsForDataset(dataset))
        record.recordId: record,
    };
    final seen = <String>{};
    for (final row in rows) {
      if (_rowHasPrivateSourceIdentity(row)) continue;
      final uid = await stableBookUidForMap(db, row);
      final locator = _decodeOptionalJson(row['last_canonical_locator']);
      BookSourceReadingProgress? sourceProgress;
      final sourceId = _nonEmptyString(row['source_id']);
      final sourceBookId = _nonEmptyString(row['source_book_id']);
      if (row['storage_type'] == 'online' &&
          sourceId != null &&
          sourceBookId != null) {
        sourceProgress = await progressStore.load(
          sourceId: sourceId,
          bookId: sourceBookId,
        );
      }
      final readingProgress = (row['reading_progress'] as num?)?.toDouble();
      if (locator == null &&
          sourceProgress == null &&
          readingProgress == null) {
        continue;
      }
      seen.add(uid);
      final payload = <String, dynamic>{'book_uid': uid};
      if (locator != null) payload['canonical_locator'] = locator;
      payload['current_page'] = row['currentPage'];
      payload['total_pages'] = row['totalPages'];
      if (readingProgress != null) {
        payload['reading_progress'] = readingProgress;
      }
      if (sourceProgress != null) {
        payload.addAll({
          'source_progress': sourceProgress.toJson(),
          'current_page': row['currentPage'],
          'total_pages': row['totalPages'],
        });
      }
      final rawEvent = await store.getState(
        '${ReadingProgressSyncService.localEventStatePrefix}$uid',
      );
      // A database scan is observation, not a reading action. Publishing a
      // never-seen legacy position here would give it a fresh HLC and let a
      // new device's stale local page beat the real remote position.
      if (rawEvent != null && rawEvent.isNotEmpty) {
        try {
          payload['position_event'] = jsonDecode(rawEvent);
        } catch (_) {
          // A damaged marker is not a reading event and must not be published.
          continue;
        }
      } else if (sourceProgress != null) {
        final sequence = sourceProgress.updatedAt.millisecondsSinceEpoch;
        final sourceEvent = <String, Object?>{
          'event_id': stableRecordId(
            'source-progress',
            '$uid|${sourceProgress.updatedAt.toUtc().toIso8601String()}',
          ),
          'saved_at': sourceProgress.updatedAt.toUtc().toIso8601String(),
          'device_id': clock.deviceId,
          'device_sequence': sequence,
          'vector': {clock.deviceId: sequence},
        };
        payload['position_event'] = sourceEvent;
        final sourceSnapshot = <String, Object?>{
          'current_page': row['currentPage'],
          'total_pages': row['totalPages'],
          'reading_progress': readingProgress,
          'canonical_locator': row['last_canonical_locator'],
          'source_progress': sourceProgress.toJson(),
          ...sourceEvent,
        };
        final encoded = jsonEncode(sourceSnapshot);
        await store.setState(
          '${ReadingProgressSyncService.localEventStatePrefix}$uid',
          encoded,
        );
        await store.setState(
          '${ReadingProgressSyncService.headStatePrefix}$uid',
          encoded,
        );
      } else {
        continue;
      }
      final mirroredEvent = mirrored[uid]?.payload?['position_event'];
      final relation = compareReadingProgressEvents(
        payload['position_event'],
        mirroredEvent,
      );
      if (relation == ReadingProgressEventRelation.incomingDominates) {
        continue;
      }
      await store.recordLocal(
        dataset: dataset,
        recordId: uid,
        entityKey: uid,
        payload: payload,
        deleted: false,
        clock: clock,
      );
    }
    await tombstoneMissing(seen, clock);
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId != operation.entityKey ||
        operation.entityKey.isEmpty) {
      throw _corruptSyncData(
        'Synced reading progress has an invalid identity.',
      );
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('Synced reading progress is missing data.');
    }
    if (payload['canonical_locator'] != null &&
        payload['canonical_locator'] is! Map) {
      throw _corruptSyncData('A synced reading locator is invalid.');
    }
    if (payload['reading_progress'] != null &&
        payload['reading_progress'] is! num) {
      throw _corruptSyncData('A synced reading percentage is invalid.');
    }
    final positionEvent = payload['position_event'];
    if (positionEvent != null &&
        (positionEvent is! Map ||
            positionEvent['event_id'] is! String ||
            positionEvent['saved_at'] is! String ||
            positionEvent['device_id'] is! String ||
            positionEvent['device_sequence'] is! num ||
            readingProgressEventVector(positionEvent) == null)) {
      throw _corruptSyncData('A synced reading event is invalid.');
    }
    final sourceProgress = payload['source_progress'];
    if (sourceProgress != null) {
      if (sourceProgress is! Map) {
        throw _corruptSyncData('Synced source progress is invalid.');
      }
      try {
        BookSourceReadingProgress.fromJson(
          sourceProgress.map((key, value) => MapEntry('$key', value)),
        );
      } catch (_) {
        throw _corruptSyncData('Synced source progress is invalid.');
      }
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    final id = await localBookId(txn, operation.entityKey);
    if (id == null) return false;
    final rows = await txn.query(
      'books',
      columns: ['storage_type', 'source_id', 'source_book_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.single;
    final sourceId = _nonEmptyString(row['source_id']);
    final sourceBookId = _nonEmptyString(row['source_book_id']);
    if (operation.deleted) {
      final candidatePrefix =
          '${ReadingProgressSyncService.candidateStatePrefix}${operation.entityKey}:';
      await txn.delete(
        'sync_local_state',
        where: 'substr(key, 1, ?) = ?',
        whereArgs: [candidatePrefix.length, candidatePrefix],
      );
      if (row['storage_type'] == 'online' &&
          sourceId != null &&
          sourceBookId != null) {
        await progressStore.delete(sourceId: sourceId, bookId: sourceBookId);
        await txn.update(
          'books',
          {'currentPage': 0, 'last_canonical_locator': null},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      return true;
    }
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('Synced reading progress is missing data.');
    }
    final positionEvent = payload['position_event'];
    final candidateEvent = positionEvent is Map
        ? positionEvent
        : <String, Object?>{
            'event_id': 'legacy-${operation.hlc}',
            'saved_at': DateTime.now().toUtc().toIso8601String(),
          };
    final candidateId = readingProgressCandidateId(candidateEvent);
    final snapshot = <String, Object?>{
      'current_page': (payload['current_page'] as num?)?.toInt() ?? 0,
      'reading_progress': (payload['reading_progress'] as num?)?.toDouble(),
      'total_pages': (payload['total_pages'] as num?)?.toInt(),
      if (payload['source_progress'] is Map)
        'source_progress': payload['source_progress'],
      'canonical_locator': payload['canonical_locator'] == null
          ? null
          : jsonEncode(payload['canonical_locator']),
      'event_id': candidateEvent['event_id'],
      'saved_at': candidateEvent['saved_at'],
      'device_id': candidateEvent['device_id'],
      'device_sequence': candidateEvent['device_sequence'],
      'vector': candidateEvent['vector'],
      'locator_revision': candidateEvent['locator_revision'],
    };
    await txn.insert('sync_local_state', {
      'key': readingProgressCandidateKey(operation.entityKey, candidateId),
      'value': jsonEncode({
        'snapshot': snapshot,
        'received_at': DateTime.now().toUtc().toIso8601String(),
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }
}

class BookmarksSyncAdapter extends _BaseAdapter {
  BookmarksSyncAdapter(super.store, super.database);

  @override
  String get dataset => 'bookmarks';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final db = await database();
    final uids = await bookUids();
    final rows = await db.query('bookmarks');
    final seen = <String>{};
    for (final row in rows) {
      final bookUid = uids[row['bookId']];
      if (bookUid == null) continue;
      final identity =
          '$bookUid|${row['anchor_key'] ?? row['cfi'] ?? row['canonical_locator'] ?? row['pageNumber']}|${row['createDate']}';
      final recordId = stableRecordId('bookmark', identity);
      seen.add(recordId);
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: bookUid,
        payload: {
          'book_uid': bookUid,
          'page_number': row['pageNumber'],
          'note': row['note'],
          'create_date': row['createDate'],
          'cfi': row['cfi'],
          'canonical_locator': _decodeOptionalJson(row['canonical_locator']),
          'anchor_key': row['anchor_key'],
          'chapter_index': row['chapter_index'],
          'chapter_title': row['chapter_title'],
          'excerpt': row['excerpt'],
        },
        deleted: false,
        clock: clock,
      );
    }
    await tombstoneMissing(seen, clock);
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.entityKey.isEmpty) {
      throw _corruptSyncData('A synced bookmark has an invalid book.');
    }
    if (!operation.deleted && operation.payload == null) {
      throw _corruptSyncData('A synced bookmark is missing data.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    final bookId = await localBookId(txn, operation.entityKey);
    if (bookId == null) return false;
    final localRows = await txn.query(
      'bookmarks',
      where: 'bookId = ?',
      whereArgs: [bookId],
    );
    int? existingId;
    for (final row in localRows) {
      final identity =
          '${operation.entityKey}|${row['anchor_key'] ?? row['cfi'] ?? row['canonical_locator'] ?? row['pageNumber']}|${row['createDate']}';
      if (stableRecordId('bookmark', identity) == operation.recordId) {
        existingId = row['id'] as int?;
        break;
      }
    }
    if (operation.deleted) {
      if (existingId != null) {
        await txn.delete('bookmarks', where: 'id = ?', whereArgs: [existingId]);
      }
      return true;
    }
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced bookmark is missing data.');
    }
    final values = {
      'bookId': bookId,
      'pageNumber': payload['page_number'],
      'note': payload['note'],
      'createDate': payload['create_date'],
      'cfi': payload['cfi'],
      'canonical_locator': payload['canonical_locator'] == null
          ? null
          : jsonEncode(payload['canonical_locator']),
      'anchor_key': payload['anchor_key'],
      'chapter_index': payload['chapter_index'],
      'chapter_title': payload['chapter_title'],
      'excerpt': payload['excerpt'],
    };
    if (existingId == null) {
      await txn.insert('bookmarks', values);
    } else {
      await txn.update(
        'bookmarks',
        values,
        where: 'id = ?',
        whereArgs: [existingId],
      );
    }
    return true;
  }
}

class NotesSyncAdapter extends _BaseAdapter {
  NotesSyncAdapter(super.store, super.database);

  @override
  String get dataset => 'notes';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final db = await database();
    final uids = await bookUids();
    final rows = await db.query('book_notes');
    final syncedRecords = await store.recordsForDataset(dataset);
    final seen = <String>{};
    for (final row in rows) {
      final bookUid = uids[row['book_id']];
      if (bookUid == null) continue;
      final legacyRecordId = stableRecordId(
        'note',
        '$bookUid|${row['cfi']}|${row['create_time'] ?? row['update_time']}',
      );
      final annotationId = _nonEmptyString(row['annotation_id']);
      final aliases =
          annotationId == null
                ? const <SyncRecord>[]
                : syncedRecords.where((record) {
                    return !record.deleted &&
                        _nonEmptyString(record.payload?['annotation_id']) ==
                            annotationId;
                  }).toList()
            ..sort((a, b) {
              final byClock = HybridLogicalTimestamp.parse(
                b.hlc,
              ).compareTo(HybridLogicalTimestamp.parse(a.hlc));
              if (byClock != 0) return byClock;
              if (a.recordId == annotationId) return -1;
              if (b.recordId == annotationId) return 1;
              return a.recordId.compareTo(b.recordId);
            });
      final recordId = aliases.isEmpty
          ? annotationId ?? legacyRecordId
          : aliases.first.recordId;
      seen.add(recordId);
      // An existing annotation keeps its compatibility aliases alive. Once
      // the business row is deleted, none of its aliases are seen and their
      // observed mirrors can publish the deletion normally.
      seen.addAll(aliases.map((record) => record.recordId));
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: bookUid,
        payload: {
          'annotation_id': annotationId ?? recordId,
          'book_uid': bookUid,
          'content': row['content'],
          'cfi': row['cfi'],
          'chapter': row['chapter'],
          'type': row['type'],
          'color': row['color'],
          'reader_note': row['reader_note'],
          'page_number': row['page_number'],
          'start_offset': row['start_offset'],
          'end_offset': row['end_offset'],
          'canonical_locator': _decodeOptionalJson(row['canonical_locator']),
          'payload_json': _decodeOptionalJson(row['payload_json']),
          'create_time': row['create_time'],
          'update_time': row['update_time'],
        },
        deleted: false,
        clock: clock,
      );
    }
    await tombstoneMissing(seen, clock);
  }

  Future<SyncOperation> normalizeRemoteWinner(
    Transaction txn,
    SyncOperation operation,
  ) async {
    final annotationId =
        _nonEmptyString(operation.payload?['annotation_id']) ??
        operation.recordId;
    final candidates = <SyncOperation>[operation];
    final rows = await txn.query(
      'sync_records',
      where: 'dataset = ?',
      whereArgs: [dataset],
    );
    for (final row in rows) {
      final candidate = SyncRecord.fromMap(row).toOperation();
      final candidateAnnotationId =
          _nonEmptyString(candidate.payload?['annotation_id']) ??
          candidate.recordId;
      if (candidateAnnotationId == annotationId) candidates.add(candidate);
    }
    candidates.sort((a, b) {
      final byClock = HybridLogicalTimestamp.parse(
        b.hlc,
      ).compareTo(HybridLogicalTimestamp.parse(a.hlc));
      if (byClock != 0) return byClock;
      return a.recordId.compareTo(b.recordId);
    });
    final winner = candidates.first;
    return SyncOperation(
      dataset: winner.dataset,
      recordId: annotationId,
      entityKey: winner.entityKey,
      hlc: winner.hlc,
      deleted: winner.deleted,
      payload: winner.payload,
    );
  }

  Future<void> cleanupRemoteWinnerAliases(
    Transaction txn,
    SyncOperation operation,
  ) async {
    final annotationId = operation.recordId;
    final rows = await txn.query(
      'sync_records',
      where: 'dataset = ? AND record_id != ?',
      whereArgs: [dataset, annotationId],
    );
    for (final row in rows) {
      final record = SyncRecord.fromMap(row);
      if (_nonEmptyString(record.payload?['annotation_id']) != annotationId) {
        continue;
      }
      if (record.dirty && record.hlc == operation.hlc) {
        // Normalization may select an unpublished local alias over an older
        // remote operation. Move its pending publication to the canonical
        // mirror before removing the alias.
        await txn.update(
          'sync_records',
          {'dirty': 1},
          where: 'dataset = ? AND record_id = ?',
          whereArgs: [dataset, annotationId],
        );
      }
      await txn.delete(
        'sync_records',
        where: 'dataset = ? AND record_id = ?',
        whereArgs: [dataset, record.recordId],
      );
      await txn.delete(
        'sync_local_state',
        where: 'key = ?',
        whereArgs: ['locally_observed:$dataset:${record.recordId}'],
      );
    }
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.entityKey.isEmpty) {
      throw _corruptSyncData('A synced note has an invalid book.');
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced note is missing data.');
    }
    for (final key in const [
      'content',
      'cfi',
      'chapter',
      'type',
      'color',
      'update_time',
    ]) {
      if (payload[key] is! String) {
        throw _corruptSyncData('A synced note contains an invalid value.');
      }
    }
    final annotationId = payload['annotation_id'];
    if (annotationId != null &&
        (annotationId is! String || annotationId.isEmpty)) {
      throw _corruptSyncData('A synced note has an invalid annotation ID.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    final payload = operation.payload;
    if (!operation.deleted && payload == null) {
      throw _corruptSyncData('A synced note is missing data.');
    }
    final bookId = await localBookId(txn, operation.entityKey);
    if (bookId == null) return operation.deleted;
    final localRows = await txn.query(
      'book_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    var annotationId =
        _nonEmptyString(payload?['annotation_id']) ?? operation.recordId;
    int? existingId;
    for (final row in localRows) {
      if (row['annotation_id'] == annotationId) {
        existingId = row['id'] as int?;
        break;
      }
    }
    for (final row in localRows) {
      if (existingId != null) break;
      final identity =
          '${operation.entityKey}|${row['cfi']}|${row['create_time'] ?? row['update_time']}';
      if (stableRecordId('note', identity) == operation.recordId) {
        existingId = row['id'] as int?;
        annotationId = _nonEmptyString(row['annotation_id']) ?? annotationId;
        break;
      }
    }
    if (operation.deleted) {
      if (existingId != null) {
        await txn.delete(
          'book_notes',
          where: 'id = ?',
          whereArgs: [existingId],
        );
      }
      return true;
    }
    final notePayload = payload!;
    final values = {
      'annotation_id': annotationId,
      'book_id': bookId,
      'content': notePayload['content'],
      'cfi': notePayload['cfi'],
      'chapter': notePayload['chapter'],
      'type': notePayload['type'],
      'color': notePayload['color'],
      'reader_note': notePayload['reader_note'],
      'page_number': notePayload['page_number'],
      'start_offset': notePayload['start_offset'],
      'end_offset': notePayload['end_offset'],
      'canonical_locator': notePayload['canonical_locator'] == null
          ? null
          : jsonEncode(notePayload['canonical_locator']),
      'payload_json': notePayload['payload_json'] == null
          ? null
          : jsonEncode(notePayload['payload_json']),
      'create_time': notePayload['create_time'],
      'update_time': notePayload['update_time'],
    };
    if (existingId == null) {
      await txn.insert('book_notes', values);
    } else {
      await txn.update(
        'book_notes',
        values,
        where: 'id = ?',
        whereArgs: [existingId],
      );
    }
    return true;
  }
}

class ReadingSessionsSyncAdapter extends _BaseAdapter {
  ReadingSessionsSyncAdapter(super.store, super.database);

  @override
  String get dataset => 'reading_sessions';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final db = await database();
    final uids = await bookUids();
    final rows = await db.query('reading_sessions');
    final seen = <String>{};
    for (final row in rows) {
      final bookUid = row['bookId'] == null ? null : uids[row['bookId']];
      final recordId = stableRecordId(
        'session',
        '${bookUid ?? 'unknown'}|${row['startTimeMs']}|${row['endTimeMs']}',
      );
      seen.add(recordId);
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: bookUid ?? 'unknown',
        payload: {
          'book_uid': bookUid,
          'date': row['date'],
          'start_time_ms': row['startTimeMs'],
          'end_time_ms': row['endTimeMs'],
          'duration_seconds': row['durationInSeconds'],
          'pages_read': row['pagesRead'],
        },
        deleted: false,
        clock: clock,
      );
    }
    // Sessions are append-only. A missing local row must not delete a remote event.
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null ||
        payload['start_time_ms'] is! num ||
        payload['end_time_ms'] is! num ||
        payload['duration_seconds'] is! num ||
        payload['pages_read'] is! num) {
      throw _corruptSyncData('A synced reading session is invalid.');
    }
    if (payload['book_uid'] != null && payload['book_uid'] is! String) {
      throw _corruptSyncData('A synced reading session has an invalid book.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.deleted) return true;
    if (operation.payload == null) {
      throw _corruptSyncData('A synced reading session is missing data.');
    }
    final payload = operation.payload!;
    final bookUid = payload['book_uid'] as String?;
    final bookId = bookUid == null ? null : await localBookId(txn, bookUid);
    if (bookUid != null && bookId == null) return false;
    final existing = await txn.query(
      'reading_sessions',
      columns: ['id'],
      where:
          'startTimeMs = ? AND endTimeMs = ? AND '
          '((bookId IS NULL AND ? IS NULL) OR bookId = ?)',
      whereArgs: [
        payload['start_time_ms'],
        payload['end_time_ms'],
        bookId,
        bookId,
      ],
      limit: 1,
    );
    if (existing.isNotEmpty) return true;
    await txn.insert('reading_sessions', {
      'date': payload['date'],
      'bookId': bookId,
      'startTimeMs': payload['start_time_ms'],
      'endTimeMs': payload['end_time_ms'],
      'durationInSeconds': payload['duration_seconds'],
      'pagesRead': payload['pages_read'],
    });
    return true;
  }
}

/// Syncs the current text, paging, tap-zone, and image-reader preferences.
///
/// Each setting is a separate protocol record so concurrent changes to, for
/// example, font size and page mode merge independently instead of replacing
/// one another as a single preferences blob would.
class ReaderSettingsSyncAdapter extends _BaseAdapter {
  ReaderSettingsSyncAdapter(super.store, super.database);

  static const _imageDirectionPrefix = 'image_direction:';
  static const _knownSettingKeys = <String>{
    'font_size',
    'text_brightness',
    'dim_text_in_dark_mode',
    'font_weight',
    'line_height',
    'letter_spacing',
    'text_alignment',
    'horizontal_margin',
    'top_margin',
    'bottom_margin',
    'theme_id',
    'page_mode',
    'first_line_indent',
    'paragraph_spacing',
    'pull_bookmark',
    'tap_page_animation',
    'tablet_two_page',
    'scroll_by_chapter',
    'txt_chapter_title_page',
    'tap_zones',
    'image_reader_background',
  };

  @override
  String get dataset => 'reader_settings';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    const settingsStore = ReaderSettingsStore();
    final settings = await settingsStore.load();
    final values = <String, Object?>{
      'font_size': settings.fontSize,
      'text_brightness': settings.textBrightness,
      'dim_text_in_dark_mode': settings.dimTextInDarkMode,
      'font_weight': settings.fontWeight,
      'line_height': settings.lineHeight,
      'letter_spacing': settings.letterSpacing,
      'text_alignment': settings.textAlignment.name,
      'horizontal_margin': settings.horizontalMargin,
      'top_margin': settings.topMargin,
      'bottom_margin': settings.bottomMargin,
      'theme_id': settings.themeId,
      'page_mode': settings.pageMode.name,
      'first_line_indent': settings.firstLineIndent,
      'paragraph_spacing': settings.paragraphSpacing,
      'pull_bookmark': settings.pullBookmarkEnabled,
      'tap_page_animation': settings.tapPageAnimationEnabled,
      'tablet_two_page': settings.tabletTwoPageEnabled,
      'scroll_by_chapter': await settingsStore.loadScrollByChapter(),
      'txt_chapter_title_page': await settingsStore
          .loadTxtChapterTitlePageEnabled(),
      'tap_zones': (await settingsStore.loadTapZones()).encode(),
      'image_reader_background':
          (await const PagedImageReaderSettingsStore().loadBackground()).name,
    };
    for (final entry in values.entries) {
      await store.recordLocal(
        dataset: dataset,
        recordId: entry.key,
        entityKey: entry.key,
        payload: {'value': entry.value},
        deleted: false,
        clock: clock,
      );
    }
    // Per-book direction keys may contain source URLs, queries, or tokens.
    // Keep those device-local until the app has an opaque cross-device book
    // identity mapping; also discard any unpublished records produced by
    // earlier builds so the reader-settings scope cannot bypass Books privacy.
    await store.forgetDirtyRecordsWithPrefix(dataset, _imageDirectionPrefix);
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId.startsWith(_imageDirectionPrefix)) {
      final expected =
          '$_imageDirectionPrefix${stableRecordId('direction', operation.entityKey)}';
      if (operation.recordId != expected ||
          (!operation.entityKey.startsWith('comic:') &&
              !operation.entityKey.startsWith('book:'))) {
        throw _corruptSyncData(
          'A synced image direction has an invalid identity.',
        );
      }
      if (!operation.deleted) {
        final name = _syncString(operation.payload?['value']);
        if (!ImageReaderDirection.values.any((item) => item.name == name)) {
          throw _corruptSyncData('A synced image direction is invalid.');
        }
      }
      return;
    }
    if (operation.recordId != operation.entityKey) {
      throw _corruptSyncData('A synced reader setting has an invalid ID.');
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null || !payload.containsKey('value')) {
      throw _corruptSyncData('A synced reader setting has no value.');
    }
    final value = payload['value'];
    switch (operation.entityKey) {
      case 'font_size':
      case 'text_brightness':
      case 'font_weight':
      case 'line_height':
      case 'letter_spacing':
      case 'horizontal_margin':
      case 'top_margin':
      case 'bottom_margin':
      case 'first_line_indent':
      case 'paragraph_spacing':
        _syncNum(value);
      case 'dim_text_in_dark_mode':
      case 'pull_bookmark':
      case 'tap_page_animation':
      case 'tablet_two_page':
      case 'scroll_by_chapter':
      case 'txt_chapter_title_page':
        _syncBool(value);
      case 'theme_id':
        _syncString(value, maxLength: 160);
      case 'text_alignment':
        final name = _syncString(value);
        if (!ReaderTextAlignment.values.any((item) => item.name == name)) {
          throw _corruptSyncData('A synced text alignment is invalid.');
        }
      case 'page_mode':
        final name = _syncString(value);
        if (!ReaderPageMode.values.any((item) => item.name == name)) {
          throw _corruptSyncData('A synced reader page mode is invalid.');
        }
      case 'tap_zones':
        final encoded = _syncString(value, maxLength: 320);
        if (ReaderTapZones.decode(encoded).encode() != encoded) {
          throw _corruptSyncData('Synced reader tap zones are invalid.');
        }
      case 'image_reader_background':
        final name = _syncString(value);
        if (!ImageReaderBackground.values.any((item) => item.name == name)) {
          throw _corruptSyncData('A synced image background is invalid.');
        }
      default:
        return;
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.recordId.startsWith(_imageDirectionPrefix)) {
      return _applyImageDirection(txn, operation);
    }
    if (operation.recordId != operation.entityKey) return true;
    if (operation.deleted) {
      return _knownSettingKeys.contains(operation.entityKey);
    }
    final payload = operation.payload;
    if (payload == null || !payload.containsKey('value')) {
      throw _corruptSyncData('A synced reader setting has no value.');
    }
    final value = payload['value'];
    const settingsStore = ReaderSettingsStore();
    final settings = await settingsStore.load();
    switch (operation.entityKey) {
      case 'font_size':
        await settingsStore.save(
          settings.copyWith(fontSize: _syncNum(value).toDouble()),
        );
      case 'text_brightness':
        await settingsStore.save(
          settings.copyWith(textBrightness: _syncNum(value).toInt()),
        );
      case 'dim_text_in_dark_mode':
        await settingsStore.save(
          settings.copyWith(dimTextInDarkMode: _syncBool(value)),
        );
      case 'font_weight':
        await settingsStore.save(
          settings.copyWith(fontWeight: _syncNum(value).toInt()),
        );
      case 'line_height':
        await settingsStore.save(
          settings.copyWith(lineHeight: _syncNum(value).toDouble()),
        );
      case 'letter_spacing':
        await settingsStore.save(
          settings.copyWith(letterSpacing: _syncNum(value).toDouble()),
        );
      case 'text_alignment':
        final name = _syncString(value);
        final alignment = ReaderTextAlignment.values
            .where((item) => item.name == name)
            .firstOrNull;
        if (alignment == null) {
          throw _corruptSyncData('A synced text alignment is invalid.');
        }
        await settingsStore.save(settings.copyWith(textAlignment: alignment));
      case 'horizontal_margin':
        await settingsStore.save(
          settings.copyWith(horizontalMargin: _syncNum(value).toDouble()),
        );
      case 'top_margin':
        await settingsStore.save(
          settings.copyWith(topMargin: _syncNum(value).toDouble()),
        );
      case 'bottom_margin':
        await settingsStore.save(
          settings.copyWith(bottomMargin: _syncNum(value).toDouble()),
        );
      case 'theme_id':
        await settingsStore.save(
          settings.copyWith(themeId: _syncString(value, maxLength: 160)),
        );
        ReaderThemes.invalidateSavedPaletteCache();
      case 'page_mode':
        final name = _syncString(value);
        final mode = ReaderPageMode.values
            .where((item) => item.name == name)
            .firstOrNull;
        if (mode == null) {
          throw _corruptSyncData('A synced reader page mode is invalid.');
        }
        await settingsStore.save(settings.copyWith(pageMode: mode));
      case 'first_line_indent':
        await settingsStore.save(
          settings.copyWith(firstLineIndent: _syncNum(value).toInt()),
        );
      case 'paragraph_spacing':
        await settingsStore.save(
          settings.copyWith(paragraphSpacing: _syncNum(value).toInt()),
        );
      case 'pull_bookmark':
        await settingsStore.save(
          settings.copyWith(pullBookmarkEnabled: _syncBool(value)),
        );
      case 'tap_page_animation':
        await settingsStore.save(
          settings.copyWith(tapPageAnimationEnabled: _syncBool(value)),
        );
      case 'tablet_two_page':
        await settingsStore.save(
          settings.copyWith(tabletTwoPageEnabled: _syncBool(value)),
        );
      case 'scroll_by_chapter':
        await settingsStore.saveScrollByChapter(_syncBool(value));
      case 'txt_chapter_title_page':
        await settingsStore.saveTxtChapterTitlePageEnabled(_syncBool(value));
      case 'tap_zones':
        final encoded = _syncString(value, maxLength: 320);
        final zones = ReaderTapZones.decode(encoded);
        if (zones.encode() != encoded) {
          throw _corruptSyncData('Synced reader tap zones are invalid.');
        }
        await settingsStore.saveTapZones(zones);
      case 'image_reader_background':
        final name = _syncString(value);
        final background = ImageReaderBackground.values
            .where((item) => item.name == name)
            .firstOrNull;
        if (background == null) {
          throw _corruptSyncData('A synced image background is invalid.');
        }
        await const PagedImageReaderSettingsStore().saveBackground(background);
      default:
        // A newer client may add reader settings without raising the protocol
        // major version. Keep the record unobserved so a future client can
        // materialize it after upgrading instead of overwriting it locally.
        return false;
    }
    return true;
  }

  Future<bool> _applyImageDirection(
    Transaction txn,
    SyncOperation operation,
  ) async {
    final expected =
        '$_imageDirectionPrefix${stableRecordId('direction', operation.entityKey)}';
    if (operation.recordId != expected) {
      throw _corruptSyncData(
        'A synced image direction has an invalid identity.',
      );
    }
    String? localKey;
    if (operation.entityKey.startsWith('comic:')) {
      localKey = operation.entityKey;
    } else if (operation.entityKey.startsWith('book:')) {
      final bookId = await localBookId(
        txn,
        operation.entityKey.substring('book:'.length),
      );
      if (bookId == null) return false;
      localKey = '$bookId';
    } else {
      throw _corruptSyncData(
        'A synced image direction targets an invalid book.',
      );
    }
    final preferences = await SharedPreferences.getInstance();
    final overrides = _decodeDirectionOverrides(
      preferences.getString(
        PagedImageReaderSettingsStore.directionOverridesKey,
      ),
    );
    if (operation.deleted) {
      overrides.remove(localKey);
    } else {
      final name = _syncString(operation.payload?['value']);
      if (!ImageReaderDirection.values.any((item) => item.name == name)) {
        throw _corruptSyncData('A synced image direction is invalid.');
      }
      overrides[localKey] = name;
    }
    await preferences.setString(
      PagedImageReaderSettingsStore.directionOverridesKey,
      jsonEncode(overrides),
    );
    return true;
  }
}

/// Syncs user-created reader palettes and their ordering. Device-local image
/// paths are deliberately omitted; an existing image on the receiving device
/// is preserved when the same theme's colors are updated remotely.
class ReaderThemesSyncAdapter implements MetadataSyncAdapter {
  ReaderThemesSyncAdapter(this.store);

  final SyncChangeStore store;

  @override
  String get dataset => 'reader_themes';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final themes = await _loadThemesForSync();
    final seen = <String>{'theme_order'};
    for (final theme in themes) {
      final recordId = stableRecordId('reader_theme', theme.id);
      seen.add(recordId);
      final payload = Map<String, dynamic>.from(theme.toSyncMap());
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: theme.id,
        payload: payload,
        deleted: false,
        clock: clock,
      );
    }
    await store.recordLocal(
      dataset: dataset,
      recordId: 'theme_order',
      entityKey: 'theme_order',
      payload: {'value': await const ReaderThemeOrderStore().load()},
      deleted: false,
      clock: clock,
    );
    for (final record in await store.recordsForDataset(dataset)) {
      final locallyObserved = await store.getState(
        'locally_observed:$dataset:${record.recordId}',
      );
      if (!record.deleted &&
          locallyObserved != null &&
          !seen.contains(record.recordId)) {
        await store.recordLocal(
          dataset: dataset,
          recordId: record.recordId,
          entityKey: record.entityKey,
          payload: record.payload,
          deleted: true,
          clock: clock,
        );
      }
    }
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId == 'theme_order') {
      if (operation.entityKey != 'theme_order') {
        throw _corruptSyncData('A synced theme order has an invalid identity.');
      }
      if (operation.deleted) return;
      final raw = operation.payload?['value'];
      if (raw is! List) {
        throw _corruptSyncData('A synced theme order is invalid.');
      }
      for (final value in raw) {
        _syncString(value, maxLength: 160);
      }
      return;
    }
    if (!ReaderCustomTheme.isCustomThemeId(operation.entityKey) ||
        operation.recordId !=
            stableRecordId('reader_theme', operation.entityKey)) {
      throw _corruptSyncData('A synced reader theme has an invalid identity.');
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null || payload['id'] != operation.entityKey) {
      throw _corruptSyncData('A synced reader theme is missing data.');
    }
    for (final key in const ['background', 'text', 'controlBar']) {
      if (payload[key] is! int) {
        throw _corruptSyncData('A synced reader theme color is invalid.');
      }
    }
    if (payload['name'] is! String ||
        payload['backgroundImageOpacity'] is! num) {
      throw _corruptSyncData('A synced reader theme value is invalid.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.recordId == 'theme_order') {
      if (operation.entityKey != 'theme_order') {
        throw _corruptSyncData('A synced theme order has an invalid identity.');
      }
      final raw = operation.payload?['value'];
      if (operation.deleted) {
        await const ReaderThemeOrderStore().save(const []);
        ReaderThemes.setThemeOrder(const []);
        return true;
      }
      if (raw is! List) {
        throw _corruptSyncData('A synced theme order is invalid.');
      }
      final ids = <String>[];
      for (final value in raw) {
        ids.add(_syncString(value, maxLength: 160));
      }
      await const ReaderThemeOrderStore().save(ids);
      ReaderThemes.setThemeOrder(ids);
      return true;
    }

    if (!ReaderCustomTheme.isCustomThemeId(operation.entityKey) ||
        operation.recordId !=
            stableRecordId('reader_theme', operation.entityKey)) {
      throw _corruptSyncData('A synced reader theme has an invalid identity.');
    }
    final themeStore = const ReaderCustomThemeStore();
    final themes = [...await _loadThemesForSync()];
    final index = themes.indexWhere((theme) => theme.id == operation.entityKey);
    if (operation.deleted) {
      if (index >= 0) themes.removeAt(index);
      await themeStore.saveAll(themes);
      ReaderThemes.setCustomThemes(themes);
      final settings = await const ReaderSettingsStore().load();
      if (settings.themeId == operation.entityKey) {
        await const ReaderSettingsStore().save(
          settings.copyWith(themeId: ReaderThemes.day.id),
        );
        ReaderThemes.rememberSavedPalette(ReaderThemes.day);
      }
      return true;
    }
    final payload = operation.payload;
    if (payload == null || payload['id'] != operation.entityKey) {
      throw _corruptSyncData('A synced reader theme is missing data.');
    }
    for (final key in const ['background', 'text', 'controlBar']) {
      if (payload[key] is! int) {
        throw _corruptSyncData('A synced reader theme color is invalid.');
      }
    }
    if (payload['name'] is! String ||
        payload['backgroundImageOpacity'] is! num) {
      throw _corruptSyncData('A synced reader theme value is invalid.');
    }
    final incoming = ReaderCustomTheme.fromMap(
      Map<String, Object?>.from(payload),
    );
    final restored = incoming.copyWith(
      backgroundImagePath: index < 0 ? null : themes[index].backgroundImagePath,
    );
    if (index < 0) {
      themes.add(restored);
    } else {
      themes[index] = restored;
    }
    await themeStore.saveAll(themes);
    ReaderThemes.setCustomThemes(themes);
    return true;
  }

  Future<List<ReaderCustomTheme>> _loadThemesForSync() async {
    try {
      return await const ReaderCustomThemeStore().loadAllForSync();
    } on WebDavSyncFailure {
      rethrow;
    } catch (_) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'Local custom reader themes are damaged; sync was stopped without '
        'deleting the remote backup.',
      );
    }
  }
}

/// Syncs user-authored replacement rules as independent LWW records.
class ReplaceRulesSyncAdapter implements MetadataSyncAdapter {
  ReplaceRulesSyncAdapter(this.store, {this.service});

  final SyncChangeStore store;
  final ReplaceRuleService? service;

  @override
  String get dataset => 'replace_rules';

  @override
  Future<void> scan(HybridLogicalClock clock) async {
    final rules = await _loadRules();
    final seen = <String>{};
    for (final rule in rules) {
      final recordId = stableRecordId('replace_rule', rule.id);
      seen.add(recordId);
      await store.recordLocal(
        dataset: dataset,
        recordId: recordId,
        entityKey: rule.id,
        payload: rule.toJson(),
        deleted: false,
        clock: clock,
      );
    }
    for (final record in await store.recordsForDataset(dataset)) {
      final locallyObserved = await store.getState(
        'locally_observed:$dataset:${record.recordId}',
      );
      if (!record.deleted &&
          locallyObserved != null &&
          !seen.contains(record.recordId)) {
        await store.recordLocal(
          dataset: dataset,
          recordId: record.recordId,
          entityKey: record.entityKey,
          payload: record.payload,
          deleted: true,
          clock: clock,
        );
      }
    }
  }

  @override
  Future<void> validate(SyncOperation operation) async {
    if (operation.recordId !=
        stableRecordId('replace_rule', operation.entityKey)) {
      throw _corruptSyncData(
        'A synced replacement rule has an invalid identity.',
      );
    }
    if (operation.deleted) return;
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced replacement rule is missing data.');
    }
    late final ReplaceRule incoming;
    try {
      incoming = ReplaceRule.fromJson(payload, 0);
      ReplaceRuleService.validate(incoming);
    } on FormatException {
      throw _corruptSyncData('A synced replacement rule is invalid.');
    }
    if (incoming.id != operation.entityKey) {
      throw _corruptSyncData('A synced replacement rule has a mismatched ID.');
    }
  }

  @override
  Future<bool> apply(Transaction txn, SyncOperation operation) async {
    if (operation.recordId !=
        stableRecordId('replace_rule', operation.entityKey)) {
      throw _corruptSyncData(
        'A synced replacement rule has an invalid identity.',
      );
    }
    final rules = [...await _loadRules()];
    final index = rules.indexWhere((rule) => rule.id == operation.entityKey);
    if (operation.deleted) {
      if (index >= 0) rules.removeAt(index);
      await _saveRules(rules);
      return true;
    }
    final payload = operation.payload;
    if (payload == null) {
      throw _corruptSyncData('A synced replacement rule is missing data.');
    }
    late final ReplaceRule incoming;
    try {
      incoming = ReplaceRule.fromJson(payload, 0);
      ReplaceRuleService.validate(incoming);
    } on FormatException {
      throw _corruptSyncData('A synced replacement rule is invalid.');
    }
    if (incoming.id != operation.entityKey) {
      throw _corruptSyncData('A synced replacement rule has a mismatched ID.');
    }
    if (index < 0) {
      rules.add(incoming);
    } else {
      rules[index] = incoming;
    }
    await _saveRules(rules);
    return true;
  }

  Future<List<ReplaceRule>> _loadRules() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(ReplaceRuleService.preferenceKey);
    if (raw == null || raw.isEmpty) return <ReplaceRule>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Replacement rules must be a list.');
      }
      if (decoded.length > ReplaceRuleService.maxRules) {
        throw const FormatException('Too many replacement rules.');
      }
      final rules = <ReplaceRule>[];
      final ids = <String>{};
      for (var index = 0; index < decoded.length; index++) {
        final item = decoded[index];
        if (item is! Map) {
          throw const FormatException('A replacement rule is malformed.');
        }
        final ruleJson = Map<String, dynamic>.from(item);
        final rawId = ruleJson['id'];
        final rawPattern = ruleJson['pattern'] ?? ruleJson['regex'];
        if ((rawId is! String && rawId is! num) ||
            '$rawId'.trim().isEmpty ||
            rawPattern is! String ||
            rawPattern.trim().isEmpty) {
          throw const FormatException(
            'Replacement rules require stable IDs and string patterns.',
          );
        }
        for (final key in const [
          'name',
          'replacement',
          'group',
          'scope',
          'excludeScope',
        ]) {
          if (ruleJson[key] != null && ruleJson[key] is! String) {
            throw const FormatException(
              'A replacement rule contains an invalid string field.',
            );
          }
        }
        for (final key in const [
          'enabled',
          'isEnabled',
          'isRegex',
          'scopeTitle',
          'scopeContent',
        ]) {
          if (ruleJson[key] != null && ruleJson[key] is! bool) {
            throw const FormatException(
              'A replacement rule contains an invalid boolean field.',
            );
          }
        }
        if (ruleJson['order'] != null && ruleJson['order'] is! num) {
          throw const FormatException(
            'A replacement rule contains an invalid order.',
          );
        }
        final rule = ReplaceRule.fromJson(ruleJson, index);
        ReplaceRuleService.validate(rule);
        if (!ids.add(rule.id)) {
          throw const FormatException('Replacement rule IDs must be unique.');
        }
        rules.add(rule);
      }
      rules.sort((a, b) => a.order.compareTo(b.order));
      return rules;
    } on WebDavSyncFailure {
      rethrow;
    } catch (_) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'Local replacement rules are damaged; sync was stopped without '
        'deleting the remote backup.',
      );
    }
  }

  Future<void> _saveRules(List<ReplaceRule> rules) async {
    if (rules.length > ReplaceRuleService.maxRules) {
      throw _corruptSyncData('Too many synced replacement rules.');
    }
    final activeService = service;
    if (activeService != null) {
      await activeService.replaceFromSync(rules);
      return;
    }
    rules.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
    });
    for (final rule in rules) {
      try {
        ReplaceRuleService.validate(rule);
      } on FormatException {
        throw _corruptSyncData('A synced replacement rule is invalid.');
      }
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      ReplaceRuleService.preferenceKey,
      jsonEncode(rules.map((rule) => rule.toJson()).toList()),
    );
  }
}

Future<String> bookUidForMap(Map<String, Object?> row) async {
  return initialBookUidForMap(row);
}

bool _rowHasPrivateSourceIdentity(Map<String, Object?> row) {
  return SyncDatasetCatalog.hasPrivateSourceIdentity(
        row['source_id'] as String?,
      ) ||
      SyncDatasetCatalog.hasPrivateSourceIdentity(
        row['source_book_id'] as String?,
      );
}

Map<String, dynamic>? _publicBookSourceSyncPayload(
  RegisteredBookSource source,
) {
  if (source.sourceProtocol != BookSourceProtocolKind.orsp ||
      SyncDatasetCatalog.hasPrivateSourceIdentity(source.id)) {
    return null;
  }
  final uris = <Uri?>[
    source.manifestUrl,
    source.apiBaseUrl,
    source.iconUrl,
    source.websiteUrl,
    source.contactUrl,
  ];
  if (uris.whereType<Uri>().any((uri) => !_isPublicSyncUri(uri))) return null;
  return <String, dynamic>{
    'sync_schema': 1,
    'id': source.id,
    'name': source.name,
    'description': source.description,
    'manifestUrl': source.manifestUrl.toString(),
    'apiBaseUrl': source.apiBaseUrl.toString(),
    if (source.iconUrl != null) 'iconUrl': source.iconUrl.toString(),
    if (source.websiteUrl != null) 'websiteUrl': source.websiteUrl.toString(),
    if (source.operatorName.isNotEmpty) 'operatorName': source.operatorName,
    if (source.contactUrl != null) 'contactUrl': source.contactUrl.toString(),
    if (source.contentLicense.isNotEmpty)
      'contentLicense': source.contentLicense,
    if (source.rightsStatement.isNotEmpty)
      'rightsStatement': source.rightsStatement,
    'protocolVersion': source.protocolVersion,
    'languages': source.languages,
    'capabilities': source.capabilities.toList()..sort(),
    if (source.maxCatalogPageSize != null)
      'maxCatalogPageSize': source.maxCatalogPageSize,
    'enabled': source.enabled,
    'isFavorite': source.isFavorite,
    'groups': source.groups,
    'addedAt': source.addedAt.toIso8601String(),
    'sourceProtocol': source.sourceProtocol.name,
  };
}

String? _publicBookSourceSnapshot(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final source = RegisteredBookSource.fromJson(
      decoded.cast<String, dynamic>(),
    );
    final projected = _publicBookSourceSyncPayload(source);
    return projected == null ? null : jsonEncode(projected);
  } catch (_) {
    return null;
  }
}

String? _publicSourceBookSnapshot(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    const allowedKeys = <String>{
      'id',
      'title',
      'author',
      'description',
      'type',
      'categories',
      'status',
      'latestChapter',
      'updatedAt',
    };
    final projected = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final key = '${entry.key}';
      if (allowedKeys.contains(key)) projected[key] = entry.value;
    }
    return jsonEncode(projected);
  } catch (_) {
    return null;
  }
}

bool _isPublicSyncUri(Uri uri) {
  return (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

String stableRecordId(String type, String identity) {
  final hex = sha256.convert(utf8.encode('$type\u0000$identity')).toString();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-5${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}

Object? _decodeOptionalJson(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

Map<String, String> _decodeDirectionOverrides(String? raw) {
  if (raw == null || raw.isEmpty) return <String, String>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, String>{};
    return <String, String>{
      for (final entry in decoded.entries)
        if (entry.value is String) '${entry.key}': entry.value as String,
    };
  } on FormatException {
    return <String, String>{};
  }
}

num _syncNum(Object? value) {
  if (value is num && value.isFinite) return value;
  throw _corruptSyncData('A synced numeric setting is invalid.');
}

bool _syncBool(Object? value) {
  if (value is bool) return value;
  throw _corruptSyncData('A synced boolean setting is invalid.');
}

String _syncString(Object? value, {int maxLength = 80}) {
  if (value is String && value.isNotEmpty && value.length <= maxLength) {
    return value;
  }
  throw _corruptSyncData('A synced text setting is invalid.');
}

WebDavSyncFailure _corruptSyncData(String message) =>
    WebDavSyncFailure(WebDavSyncErrorCode.corruptRemoteData, message);

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : value;
}
