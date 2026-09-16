import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';

void main() {
  test(
    'source metadata CAS preserves concurrent progress and rejects a rebind',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE books (id INTEGER PRIMARY KEY, source_id TEXT, source_book_id TEXT, source_book_json TEXT, currentPage INTEGER, cover_image_path TEXT, storage_type TEXT, content_hash TEXT, file_modified_time INTEGER)',
      );
      await db.insert('books', {
        'id': 7,
        'source_id': 's',
        'source_book_id': 'b',
        'source_book_json': '{}',
        'currentPage': 80,
        'storage_type': 'local',
        'cover_image_path': 'custom.png',
      });
      final dao = BookDao(
        database: () async => db,
        documentsDirectory: () async => Directory('/tmp'),
      );
      final snapshot = Book(
        id: 7,
        title: 'Book',
        filePath: '',
        format: 'source',
        sourceId: 's',
        sourceBookId: 'b',
        sourceBookJson: '{}',
        currentPage: 1,
      );
      expect(
        await dao.updateSourceBookMetadata(snapshot, '{"checked":true}'),
        isTrue,
      );
      final row = (await db.query('books')).single;
      expect(row['currentPage'], 80);
      expect(row['cover_image_path'], 'custom.png');
      expect(
        await dao.updateSourceBookMetadata(snapshot, '{"stale":true}'),
        isFalse,
      );
      await db.update('books', {
        'source_book_json': '{}',
        'content_hash': 'new-content',
        'file_modified_time': 42,
      });
      expect(
        await dao.updateSourceBookMetadata(snapshot, '{"stale":true}'),
        isFalse,
      );
      expect((await db.query('books')).single['source_book_json'], '{}');
      await db.update('books', {
        'source_id': 'new-source',
        'source_book_json': '{}',
      });
      expect(
        await dao.updateSourceBookMetadata(snapshot, '{"stale":true}'),
        isFalse,
      );
      expect((await db.query('books')).single['source_book_json'], '{}');
    },
  );
}
