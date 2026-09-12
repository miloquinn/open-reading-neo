import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/services/sync/book_sync_identity.dart';

void main() {
  late Database db;
  late Directory root;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    root = await Directory.systemTemp.createTemp('stable-book-identity-');
    await db.execute(
      'CREATE TABLE sync_local_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute('''CREATE TABLE sync_book_files(
      book_uid TEXT PRIMARY KEY, local_book_id INTEGER, updated_at TEXT)''');
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('frozen identity wins over a later remote file binding', () async {
    await db.insert('sync_local_state', {
      'key': 'frozen_book_uid:1',
      'value': 'original-book',
    });
    await db.insert('sync_book_files', {
      'book_uid': 'different-book',
      'local_book_id': 1,
      'updated_at': '2099-01-01',
    });
    expect(await stableBookUidForMap(db, {'id': 1}), 'original-book');
  });

  test(
    'download, editing and source changes keep the frozen identity',
    () async {
      final row = <String, Object?>{
        'id': 2,
        'title': '连载',
        'source_id': 'first-source',
        'source_book_id': 'serial',
        'filePath': '',
        'format': 'source',
      };
      final original = await stableBookUidForMap(db, row);
      final file = File('${root.path}/连载.txt');
      await file.writeAsString('第一章\n原文');
      row.addAll({'filePath': file.path, 'format': 'txt'});
      expect(await stableBookUidForMap(db, row), original);
      await file.writeAsString('第一章\n用户修改\n第二章\n新增');
      row.addAll({'source_id': 'other-source', 'source_book_id': 'new-id'});
      expect(await stableBookUidForMap(db, row), original);
      row.addAll({'source_id': null, 'source_book_id': null});
      expect(await stableBookUidForMap(db, row), original);
    },
  );

  test(
    'restored identity cannot silently replace an existing identity',
    () async {
      expect(await freezeBookUid(db, 3, 'remote-entity'), 'remote-entity');
      expect(await freezeBookUid(db, 3, 'remote-entity'), 'remote-entity');
      await expectLater(freezeBookUid(db, 3, 'other-entity'), throwsStateError);
      expect(await stableBookUidForMap(db, {'id': 3}), 'remote-entity');
    },
  );
}
