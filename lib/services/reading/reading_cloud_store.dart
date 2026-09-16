import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../core/database_service.dart';

class ReadingCloudStore {
  ReadingCloudStore({Future<Database> Function()? database})
    : _database = database ?? (() => DatabaseService().database);

  final Future<Database> Function() _database;

  Future<void> record({
    required String eventId,
    required String? owner,
    required int startMs,
    required int seconds,
  }) async {
    if (seconds <= 0) return;
    final db = await _database();
    await db.insert('reading_cloud_events', {
      'event_id': eventId,
      'owner_id': owner,
      'start_ms': startMs,
      'end_ms': startMs + seconds * 1000,
      'seconds': seconds,
      'kind': owner == null ? 'history' : 'reading',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static String newId() => const Uuid().v4();

  Future<int> guestSeconds() async {
    final db = await _database();
    final result = await db.rawQuery(
      '''SELECT COALESCE(SUM(seconds), 0) AS seconds
      FROM reading_cloud_events WHERE owner_id IS NULL''',
    );
    return (result.single['seconds'] as num).toInt();
  }

  Future<void> claimGuest(String owner) async {
    final db = await _database();
    // Ownership is committed locally before any request. A failed upload does
    // not turn these rows into guests and a subsequent login cannot re-claim.
    await db.update('reading_cloud_events', {
      'owner_id': owner,
    }, where: 'owner_id IS NULL');
  }

  Future<List<Map<String, Object?>>> pending(String owner) async {
    final db = await _database();
    return db.query(
      'reading_cloud_events',
      where: "owner_id = ? AND state = 'pending'",
      whereArgs: [owner],
      orderBy: 'start_ms, event_id',
      limit: 200,
    );
  }

  Map<String, Object?> payload(Map<String, Object?> row) => {
    for (final key in ['event_id', 'start_ms', 'end_ms', 'seconds', 'kind'])
      key: row[key],
  };

  Future<void> acknowledge(String owner, Map<String, dynamic> result) async {
    final db = await _database();
    await db.transaction((txn) async {
      for (final id in result['accepted'] as List) {
        await txn.update(
          'reading_cloud_events',
          {'state': 'synced'},
          where: 'event_id = ? AND owner_id = ?',
          whereArgs: [id, owner],
        );
      }
      for (final item in result['rejected'] as List) {
        await txn.update(
          'reading_cloud_events',
          {'state': 'rejected', 'rejection': item['reason']},
          where: 'event_id = ? AND owner_id = ?',
          whereArgs: [item['event_id'], owner],
        );
      }
    });
  }

  Future<({int pending, int rejected})> counts(String owner) async {
    final db = await _database();
    final rows = await db.rawQuery(
      '''SELECT state, COUNT(*) AS count
      FROM reading_cloud_events WHERE owner_id = ? GROUP BY state''',
      [owner],
    );
    var pending = 0, rejected = 0;
    for (final row in rows) {
      if (row['state'] == 'pending') pending = row['count'] as int;
      if (row['state'] == 'rejected') rejected = row['count'] as int;
    }
    return (pending: pending, rejected: rejected);
  }

  Future<Map<String, dynamic>?> cached(String owner) async {
    final db = await _database();
    final rows = await db.query(
      'reading_cloud_cache',
      where: 'owner_id = ?',
      whereArgs: [owner],
    );
    if (rows.isEmpty) return null;
    return (jsonDecode(rows.single['payload'] as String) as Map)
        .cast<String, dynamic>();
  }

  Future<void> cache(String owner, Map<String, dynamic> payload) async {
    final db = await _database();
    await db.insert('reading_cloud_cache', {
      'owner_id': owner,
      'payload': jsonEncode(payload),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
