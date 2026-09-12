import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/services/sync/adapters/metadata_sync_adapters.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_protocol.dart';

void main() {
  late Database db;
  late BooksSyncAdapter adapter;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await WebDavSyncSchemaMigration.migrate(db);
    await db.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT,
        filePath TEXT NOT NULL,
        format TEXT NOT NULL,
        currentPage INTEGER,
        totalPages INTEGER,
        importDate INTEGER NOT NULL,
        storage_type TEXT,
        source_id TEXT,
        source_book_id TEXT,
        source_json TEXT,
        source_book_json TEXT
      )
    ''');
    final store = SyncChangeStore(database: () async => db);
    adapter = BooksSyncAdapter(store, () async => db);
  });

  tearDown(() => db.close());

  test(
    'source change on downloaded book preserves local content fields',
    () async {
      final id = await db.insert('books', {
        'title': '连载',
        'author': '作者',
        'filePath': '/local/serial.txt',
        'format': 'txt',
        'currentPage': 8,
        'totalPages': 100,
        'importDate': 1,
        'storage_type': 'local',
        'source_id': 'old-source',
        'source_book_id': 'old-book',
        'source_json': '{}',
        'source_book_json': '{}',
      });
      await db.insert('sync_local_state', {
        'key': 'frozen_book_uid:$id',
        'value': 'book-uid',
      });

      await db.transaction(
        (txn) => adapter.apply(
          txn,
          _operation(storageType: 'local', sourceId: 'new-source'),
        ),
      );

      final row = (await db.query(
        'books',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['filePath'], '/local/serial.txt');
      expect(row['format'], 'txt');
      expect(row['storage_type'], 'local');
      expect(row['source_id'], 'new-source');
      expect(row['source_book_id'], 'source-book');
    },
  );

  test(
    'remote source-linked local metadata restores a frozen online shell',
    () async {
      await db.transaction(
        (txn) => adapter.apply(
          txn,
          _operation(storageType: 'local', sourceId: 'source-a'),
        ),
      );

      final row = (await db.query('books')).single;
      expect(row['storage_type'], 'online');
      expect(row['filePath'], '');
      final frozen = await db.query(
        'sync_local_state',
        where: 'key = ?',
        whereArgs: ['frozen_book_uid:${row['id']}'],
      );
      expect(frozen.single['value'], 'book-uid');
    },
  );
}

SyncOperation _operation({
  required String storageType,
  required String sourceId,
}) => SyncOperation(
  dataset: 'books',
  recordId: 'book-uid',
  entityKey: 'book-uid',
  hlc: '2000-0000-remote',
  deleted: false,
  payload: {
    'title': '连载（新）',
    'author': '作者',
    'format': 'txt',
    'import_date': 1,
    'storage_type': storageType,
    'source_id': sourceId,
    'source_book_id': 'source-book',
    'source_json': '{}',
    'source_book_json': '{}',
  },
);
