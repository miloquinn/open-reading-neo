import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class ReadingCloudSchemaMigration {
  static const migrationVersion = 26;

  static Future<void> migrate(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS reading_cloud_events (
      event_id TEXT PRIMARY KEY,
      owner_id TEXT,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      seconds INTEGER NOT NULL,
      kind TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending',
      rejection TEXT
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS reading_cloud_pending
      ON reading_cloud_events(owner_id, state, start_ms)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS reading_cloud_cache (
      owner_id TEXT PRIMARY KEY, payload TEXT NOT NULL
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS reading_cloud_meta (
      key TEXT PRIMARY KEY, value TEXT NOT NULL
    )''');
    await db.insert('reading_cloud_meta', {
      'key': 'legacy_origin',
      'value': const Uuid().v4(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final metadata = await db.query(
      'reading_cloud_meta',
      where: 'key = ?',
      whereArgs: ['legacy_origin'],
    );
    final origin = metadata.single['value'] as String;
    // This is a one-time snapshot of pre-cloud history. WebDAV imports after
    // this migration never enter the cloud outbox or acquire ranking credit.
    final sessions = await db.query('reading_sessions');
    final datesWithSessions = <String>{};
    for (final row in sessions) {
      final start = row['startTimeMs'] as int;
      final end = row['endTimeMs'] as int;
      if (start < 946684800000 || end <= start) continue;
      datesWithSessions.add(row['date'] as String);
      for (var left = start; left < end; left += 86400000) {
        final right = math.min(left + 86400000, end);
        final seconds = (right - left) ~/ 1000;
        if (seconds <= 0) continue;
        await db.insert('reading_cloud_events', {
          'event_id': const Uuid().v5(
            Namespace.url.value,
            'open-reading:history:$left:$right',
          ),
          'start_ms': left,
          'end_ms': right,
          'seconds': seconds,
          'kind': 'legacy_session',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    final daily = await db.rawQuery(
      '''SELECT date, SUM(durationInSeconds) AS seconds
      FROM reading_stats GROUP BY date''',
    );
    for (final row in daily) {
      final day = row['date'] as String;
      if (datesWithSessions.contains(day)) continue;
      final parsed = DateTime.tryParse('${day}T00:00:00+08:00');
      final seconds = math.min(86400, (row['seconds'] as num).toInt());
      if (parsed == null || seconds <= 0) continue;
      final start = parsed.millisecondsSinceEpoch;
      await db.insert('reading_cloud_events', {
        'event_id': const Uuid().v5(origin, 'open-reading:daily:$day:$seconds'),
        'start_ms': start,
        'end_ms': start + 86400000,
        'seconds': seconds,
        'kind': 'legacy_daily',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}
