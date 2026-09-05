import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/database_service.dart';
import 'reading_progress_event.dart';
import 'sync_clock.dart';
import 'sync_protocol.dart';

class SyncRecord {
  const SyncRecord({
    required this.dataset,
    required this.recordId,
    required this.entityKey,
    required this.payload,
    required this.hlc,
    required this.deleted,
    required this.dirty,
  });

  final String dataset;
  final String recordId;
  final String entityKey;
  final Map<String, dynamic>? payload;
  final String hlc;
  final bool deleted;
  final bool dirty;

  SyncOperation toOperation() => SyncOperation(
    dataset: dataset,
    recordId: recordId,
    entityKey: entityKey,
    hlc: hlc,
    deleted: deleted,
    payload: payload,
  );

  factory SyncRecord.fromMap(Map<String, Object?> map) => SyncRecord(
    dataset: map['dataset']! as String,
    recordId: map['record_id']! as String,
    entityKey: map['entity_key']! as String,
    payload: map['payload_json'] == null
        ? null
        : (jsonDecode(map['payload_json']! as String) as Map)
              .cast<String, dynamic>(),
    hlc: map['hlc']! as String,
    deleted: map['deleted'] == 1,
    dirty: map['dirty'] == 1,
  );
}

class SyncChangeStore {
  SyncChangeStore({
    DatabaseService? databaseService,
    Future<Database> Function()? database,
  }) : _databaseService = databaseService ?? DatabaseService(),
       _databaseProvider = database;

  final DatabaseService _databaseService;
  final Future<Database> Function()? _databaseProvider;

  Future<Database> get _db =>
      _databaseProvider?.call() ?? _databaseService.database;

  Future<String?> getState(String key) async {
    final db = await _db;
    final rows = await db.query(
      'sync_local_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setState(String key, String value) async {
    final db = await _db;
    await db.insert('sync_local_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteState(String key) async {
    final db = await _db;
    await db.delete('sync_local_state', where: 'key = ?', whereArgs: [key]);
  }

  Future<Map<String, String>> statesWithPrefix(String prefix) async {
    final db = await _db;
    final rows = await db.query(
      'sync_local_state',
      columns: ['key', 'value'],
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [prefix.length, prefix],
    );
    return {
      for (final row in rows) row['key']! as String: row['value']! as String,
    };
  }

  /// Detaches protocol state from the previous WebDAV space.
  ///
  /// Local books, explicit progress events and frozen identities survive. All
  /// remote cursors, materialization markers, conflict candidates and legacy
  /// remote file paths are removed so they cannot leak into another account.
  Future<void> resetRemoteMirrorForNewSpace() async {
    final db = await _db;
    await db.transaction((txn) async {
      final bindings = await txn.query(
        'sync_book_files',
        columns: ['book_uid', 'local_book_id'],
      );
      for (final binding in bindings) {
        final bookId = binding['local_book_id'] as int?;
        final uid = binding['book_uid'] as String?;
        if (bookId == null || uid == null || uid.isEmpty) continue;
        await txn.insert('sync_local_state', {
          'key': 'frozen_book_uid:$bookId',
          'value': uid,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.delete('sync_records');
      await txn.delete('sync_device_cursors');
      await txn.delete('sync_book_files');
      await txn.delete(
        'sync_local_state',
        where:
            'key NOT GLOB ? AND key NOT GLOB ? AND key NOT GLOB ? '
            'AND key NOT GLOB ?',
        whereArgs: [
          'frozen_book_uid:*',
          'progress_event:*',
          'progress_head:*',
          'progress_device_sequence:*',
        ],
      );
    });
  }

  Future<int> cursorFor(String deviceId) async {
    final db = await _db;
    final rows = await db.query(
      'sync_device_cursors',
      columns: ['applied_sequence'],
      where: 'remote_device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.first['applied_sequence'] as int;
  }

  Future<List<SyncRecord>> recordsForDataset(String dataset) async {
    final db = await _db;
    final rows = await db.query(
      'sync_records',
      where: 'dataset = ?',
      whereArgs: [dataset],
    );
    return rows.map(SyncRecord.fromMap).toList(growable: false);
  }

  /// Removes local protocol records that must never be published, together
  /// with their materialization markers. This does not mutate business data.
  Future<void> forgetDirtyRecordsWithPrefix(
    String dataset,
    String prefix,
  ) async {
    final db = await _db;
    final rows = await db.query(
      'sync_records',
      columns: ['record_id'],
      where: 'dataset = ? AND dirty = 1',
      whereArgs: [dataset],
    );
    final recordIds = rows
        .map((row) => row['record_id']! as String)
        .where((recordId) => recordId.startsWith(prefix))
        .toList(growable: false);
    if (recordIds.isEmpty) return;
    await db.transaction((txn) async {
      for (final recordId in recordIds) {
        await txn.delete(
          'sync_records',
          where: 'dataset = ? AND record_id = ?',
          whereArgs: [dataset, recordId],
        );
        await txn.delete(
          'sync_local_state',
          where: 'key = ?',
          whereArgs: ['locally_observed:$dataset:$recordId'],
        );
      }
    });
  }

  Future<List<SyncRecord>> dirtyRecords({
    int limit = 500,
    Set<String>? datasets,
  }) async {
    if (datasets != null && datasets.isEmpty) return const [];
    final db = await _db;
    final orderedDatasets = datasets == null
        ? null
        : (datasets.toList()..sort());
    final rows = await db.query(
      'sync_records',
      where: orderedDatasets == null
          ? 'dirty = 1'
          : 'dirty = 1 AND dataset IN '
                '(${List.filled(orderedDatasets.length, '?').join(', ')})',
      whereArgs: orderedDatasets,
      orderBy: 'dataset, record_id',
      limit: limit,
    );
    return rows.map(SyncRecord.fromMap).toList(growable: false);
  }

  Future<int> pendingCount({Set<String>? datasets}) async {
    if (datasets != null && datasets.isEmpty) return 0;
    final db = await _db;
    final orderedDatasets = datasets == null
        ? null
        : (datasets.toList()..sort());
    final rows = await db.rawQuery(
      orderedDatasets == null
          ? 'SELECT COUNT(*) AS count FROM sync_records WHERE dirty = 1'
          : 'SELECT COUNT(*) AS count FROM sync_records '
                'WHERE dirty = 1 AND dataset IN '
                '(${List.filled(orderedDatasets.length, '?').join(', ')})',
      orderedDatasets,
    );
    return (rows.first['count'] as num).toInt();
  }

  Future<HybridLogicalTimestamp?> latestTimestamp() async {
    final db = await _db;
    final rows = await db.query('sync_records', columns: ['hlc']);
    HybridLogicalTimestamp? latest;
    for (final row in rows) {
      final timestamp = HybridLogicalTimestamp.parse(row['hlc']! as String);
      if (latest == null || timestamp.compareTo(latest) > 0) {
        latest = timestamp;
      }
    }
    return latest;
  }

  /// Records a local snapshot only when its protocol representation changed.
  Future<void> recordLocal({
    required String dataset,
    required String recordId,
    required String entityKey,
    required Map<String, dynamic>? payload,
    required bool deleted,
    required HybridLogicalClock clock,
  }) async {
    final db = await _db;
    final payloadJson = payload == null ? null : jsonEncode(payload);
    final rows = await db.query(
      'sync_records',
      where: 'dataset = ? AND record_id = ?',
      whereArgs: [dataset, recordId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final current = rows.first;
      final currentPayload = current['payload_json'] == null
          ? null
          : jsonDecode(current['payload_json']! as String);
      if (current['entity_key'] == entityKey &&
          sha256OfCanonicalJson(currentPayload) ==
              sha256OfCanonicalJson(payload) &&
          (current['deleted'] == 1) == deleted) {
        await db.insert('sync_local_state', {
          'key': 'locally_observed:$dataset:$recordId',
          'value': current['hlc']! as String,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return;
      }
    }
    final hlc = clock.tick().toString();
    await db.insert('sync_records', {
      'dataset': dataset,
      'record_id': recordId,
      'entity_key': entityKey,
      'payload_json': payloadJson,
      'hlc': hlc,
      'deleted': deleted ? 1 : 0,
      'dirty': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('sync_local_state', {
      'key': 'locally_observed:$dataset:$recordId',
      'value': hlc,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> applyRemoteBatch(
    SyncBatch batch, {
    required Future<void> Function(SyncOperation operation) validateWinner,
    required Future<bool> Function(Transaction txn, SyncOperation operation)
    applyWinner,
    Future<SyncOperation> Function(Transaction txn, SyncOperation operation)?
    normalizeWinner,
    Future<void> Function(Transaction txn, SyncOperation operation)?
    cleanupWinnerAliases,
  }) async {
    final db = await _db;
    final winners = <SyncOperation>[];
    await db.transaction((txn) async {
      final candidates = <String, SyncOperation>{};
      final wireCandidates = <String, SyncOperation>{};
      for (final operation in batch.operations) {
        final key = '${operation.dataset}\u0000${operation.recordId}';
        final earlierCandidate = wireCandidates[key];
        SyncOperation? current = earlierCandidate;
        if (current == null) {
          final rows = await txn.query(
            'sync_records',
            where: 'dataset = ? AND record_id = ?',
            whereArgs: [operation.dataset, operation.recordId],
            limit: 1,
          );
          if (rows.isNotEmpty) {
            current = SyncRecord.fromMap(rows.first).toOperation();
          }
        }
        // Tombstones are allowed to omit their payload. Preserve the last
        // known identity metadata so adapters can still locate the business
        // row when applying a deletion.
        var effectiveOperation = SyncOperation(
          dataset: operation.dataset,
          recordId: operation.recordId,
          entityKey: operation.entityKey,
          hlc: operation.hlc,
          deleted: operation.deleted,
          payload: operation.deleted && operation.payload == null
              ? current?.payload
              : operation.payload,
        );
        var forceProgressWinner = false;
        if (operation.dataset == 'progress' &&
            !operation.deleted &&
            current != null) {
          final relation = compareReadingProgressEvents(
            current.payload?['position_event'],
            operation.payload?['position_event'],
          );
          if (relation == ReadingProgressEventRelation.currentDominates) {
            continue;
          }
          if (relation == ReadingProgressEventRelation.concurrent ||
              relation == ReadingProgressEventRelation.unknown) {
            await _storeProgressCandidate(txn, operation);
            continue;
          }
          forceProgressWinner =
              relation == ReadingProgressEventRelation.incomingDominates;
        }
        if (current == null ||
            forceProgressWinner ||
            HybridLogicalTimestamp.parse(current.hlc).compareTo(
                  HybridLogicalTimestamp.parse(effectiveOperation.hlc),
                ) <
                0) {
          wireCandidates[key] = effectiveOperation;
        }
        if (normalizeWinner != null) {
          effectiveOperation = await normalizeWinner(txn, effectiveOperation);
        }
        final normalizedKey =
            '${effectiveOperation.dataset}\u0000${effectiveOperation.recordId}';
        var normalizedCurrent = candidates[normalizedKey];
        if (normalizedCurrent == null) {
          final rows = await txn.query(
            'sync_records',
            where: 'dataset = ? AND record_id = ?',
            whereArgs: [
              effectiveOperation.dataset,
              effectiveOperation.recordId,
            ],
            limit: 1,
          );
          if (rows.isNotEmpty) {
            normalizedCurrent = SyncRecord.fromMap(rows.first).toOperation();
          }
        }
        if (normalizedCurrent != null &&
            !forceProgressWinner &&
            HybridLogicalTimestamp.parse(normalizedCurrent.hlc).compareTo(
                  HybridLogicalTimestamp.parse(effectiveOperation.hlc),
                ) >=
                0) {
          continue;
        }
        candidates[normalizedKey] = effectiveOperation;
      }

      winners.addAll(candidates.values);
      // Validation is side-effect free and covers the complete winning set.
      // Any malformed operation aborts before mirror/cursor state changes.
      for (final operation in winners) {
        await validateWinner(operation);
      }

      for (final effectiveOperation in winners) {
        await txn.insert('sync_records', {
          'dataset': effectiveOperation.dataset,
          'record_id': effectiveOperation.recordId,
          'entity_key': effectiveOperation.entityKey,
          'payload_json': effectiveOperation.payload == null
              ? null
              : jsonEncode(effectiveOperation.payload),
          'hlc': effectiveOperation.hlc,
          'deleted': effectiveOperation.deleted ? 1 : 0,
          'dirty': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // Absence of this versioned marker is the durable materialization
        // queue. It survives failures and scope changes without mixing
        // non-transactional preference writes into the mirror transaction.
        await txn.delete(
          'sync_local_state',
          where: 'key = ?',
          whereArgs: [
            'locally_observed:${effectiveOperation.dataset}:${effectiveOperation.recordId}',
          ],
        );
        if (cleanupWinnerAliases != null) {
          await cleanupWinnerAliases(txn, effectiveOperation);
        }
      }
      await txn.insert('sync_device_cursors', {
        'remote_device_id': batch.deviceId,
        'applied_sequence': batch.sequence,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    // Materialize after the mirror and cursor commit. Each operation is
    // independently idempotent: a failed preference/database write leaves
    // its marker absent and is retried before the next local scan.
    for (final operation in winners) {
      await db.transaction((txn) async {
        final materialized = await applyWinner(txn, operation);
        if (!materialized) return;
        await txn.insert('sync_local_state', {
          'key': 'locally_observed:${operation.dataset}:${operation.recordId}',
          'value': operation.hlc,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
    }
    return winners.length;
  }

  Future<void> markUploaded(List<SyncRecord> records) async {
    if (records.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final record in records) {
        await txn.update(
          'sync_records',
          {'dirty': 0},
          where: 'dataset = ? AND record_id = ? AND hlc = ?',
          whereArgs: [record.dataset, record.recordId, record.hlc],
        );
      }
    });
  }
}

Future<void> _storeProgressCandidate(
  Transaction txn,
  SyncOperation operation,
) async {
  final event = operation.payload?['position_event'];
  final eventId = readingProgressEventId(event) == null
      ? 'legacy-${operation.hlc}'
      : readingProgressCandidateId(event);
  await txn.insert('sync_local_state', {
    'key': readingProgressCandidateKey(operation.entityKey, eventId),
    'value': jsonEncode({
      'snapshot': _progressSnapshot(operation.payload),
      'received_at': DateTime.now().toUtc().toIso8601String(),
    }),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Map<String, Object?> _progressSnapshot(Map<String, dynamic>? payload) {
  final event = payload?['position_event'];
  return {
    'current_page': (payload?['current_page'] as num?)?.toInt() ?? 0,
    'reading_progress': (payload?['reading_progress'] as num?)?.toDouble(),
    'canonical_locator': payload?['canonical_locator'] == null
        ? null
        : jsonEncode(payload!['canonical_locator']),
    if (event is Map) 'event_id': event['event_id'],
    if (event is Map) 'saved_at': event['saved_at'],
    if (event is Map) 'device_id': event['device_id'],
    if (event is Map) 'device_sequence': event['device_sequence'],
    if (event is Map) 'vector': event['vector'],
    if (event is Map) 'locator_revision': event['locator_revision'],
  };
}
