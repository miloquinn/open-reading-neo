import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/services/book_source_usage_service.dart';

void main() {
  test(
    'shelf references include distinct online source IDs without local books',
    () async {
      sqfliteFfiInit();
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await database.execute(
        'CREATE TABLE books (storage_type TEXT, source_id TEXT)',
      );
      for (final row in [
        {'storage_type': 'online', 'source_id': 'used'},
        {'storage_type': 'online', 'source_id': 'used'},
        {'storage_type': 'local', 'source_id': 'downloaded'},
        {'storage_type': 'online', 'source_id': null},
        {'storage_type': 'online', 'source_id': ''},
      ]) {
        await database.insert('books', row);
      }
      expect(await referencedBookSourceIds(database: database), {'used'});
    },
  );
}
