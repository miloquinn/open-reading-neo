import 'package:sqflite/sqflite.dart';

import '../../services/core/database_service.dart';

/// Reads only source identities, without loading books or their stored rules.
Future<Set<String>> referencedBookSourceIds({
  DatabaseExecutor? database,
}) async {
  final db = database ?? await DatabaseService().database;
  final rows = await db.query(
    'books',
    columns: const ['source_id'],
    distinct: true,
    where: 'storage_type = ? AND source_id IS NOT NULL',
    whereArgs: const ['online'],
  );
  return rows
      .map((row) => row['source_id'])
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
}
