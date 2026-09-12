import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_import_models.dart';
import 'package:xxread/services/sync/book_file_sync_service.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/sync_models.dart';

void main() {
  late Directory root;
  late Database database;
  late MemorySyncStorage storage;

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('book-file-sync-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL,
        filePath TEXT NOT NULL, format TEXT NOT NULL, currentPage INTEGER NOT NULL,
        totalPages INTEGER NOT NULL, importDate INTEGER NOT NULL,
        storage_type TEXT NOT NULL DEFAULT 'local', reading_progress REAL,
        cached_content TEXT, cached_pages TEXT, file_modified_time INTEGER,
        content_hash TEXT, table_of_contents TEXT, cover_image_path TEXT,
        text_encoding TEXT, last_canonical_locator TEXT,
        last_rendered_locator TEXT, layout_signature TEXT, source_id TEXT,
        source_book_id TEXT, source_json TEXT, source_book_json TEXT,
        source_kind TEXT, source_locator TEXT, source_modified_time INTEGER
      )
    ''');
    await database.execute(
      'CREATE TABLE book_notes(id INTEGER PRIMARY KEY, book_id INTEGER)',
    );
    await database.execute(
      'CREATE TABLE bookmarks(id INTEGER PRIMARY KEY, bookId INTEGER)',
    );
    await WebDavSyncSchemaMigration.migrate(database);
    storage = MemorySyncStorage(spaceKey: 'memory:file-test');
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('upload reports available only after current and head verify', () async {
    final file = File('${root.path}/原书.epub');
    await file.writeAsBytes([1, 2, 3, 4], flush: true);
    final book = Book(
      id: 1,
      title: '原书',
      author: '作者',
      filePath: file.path,
      format: 'epub',
    );
    await database.insert('books', {
      'id': 1,
      'title': book.title,
      'author': book.author,
      'filePath': book.filePath,
      'format': book.format,
      'currentPage': 0,
      'totalPages': 1,
      'importDate': book.importDate.millisecondsSinceEpoch,
    });
    final service = BookFileSyncService(
      storageProvider: () async => storage,
      database: () async => database,
      temporaryDirectory: () async => root,
      documentsDirectory: () async => root,
      contentStateDirectory: () async => Directory('${root.path}/state'),
    );

    final descriptor = await service.upload(book);
    expect(descriptor.fileAvailable, isTrue);
    expect(descriptor.remotePath, contains('/current.epub'));
    expect(descriptor.remotePath, isNot(startsWith('root:')));
    expect(descriptor.remotePath, isNot(contains('/v2/')));
    expect(await storage.stat(SyncPath(descriptor.remotePath!)), isNotNull);
    final directory = descriptor.remotePath!.substring(
      0,
      descriptor.remotePath!.lastIndexOf('/'),
    );
    expect(await storage.stat(SyncPath('$directory/book.json')), isNotNull);
  });

  test('corrupt download is rejected before importer sees it', () async {
    final bytes = [1, 2, 3, 4];
    await storage.create(
      SyncPath('books/a/current.epub'),
      Stream.value(bytes),
      length: bytes.length,
      contentType: 'application/epub+zip',
    );
    final importer = _Importer();
    final service = BookFileSyncService(
      storageProvider: () async => storage,
      database: () async => database,
      importer: importer,
      temporaryDirectory: () async => root,
      documentsDirectory: () async => root,
      contentStateDirectory: () async => Directory('${root.path}/state'),
    );

    await expectLater(
      service.download(
        const RemoteBookDescriptor(
          bookUid: 'remote-book',
          title: 'Remote',
          author: 'Author',
          format: 'epub',
          fileAvailable: true,
          sizeBytes: 4,
          blobSha256: 'bad',
          remotePath: 'books/a/current.epub',
          fileName: '原书.epub',
        ),
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (failure) => failure.code,
          'code',
          WebDavSyncErrorCode.corruptRemoteData,
        ),
      ),
    );
    expect(importer.called, isFalse);
  });
}

class _Importer implements BookFileImporter {
  bool called = false;

  @override
  Future<BookImportResult> importFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    called = true;
    throw StateError('not expected');
  }
}
