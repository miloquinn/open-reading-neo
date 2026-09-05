import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_import_models.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/mutable_txt_sync_service.dart';
import 'package:xxread/services/sync/txt_chunk_manifest.dart';
import 'package:xxread/services/sync/webdav_book_file_service.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  late Directory temporaryDirectory;
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'open-reading-webdav-book-test-',
    );
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        filePath TEXT NOT NULL DEFAULT '',
        format TEXT NOT NULL DEFAULT 'txt',
        currentPage INTEGER NOT NULL DEFAULT 0,
        totalPages INTEGER NOT NULL DEFAULT 1,
        importDate INTEGER NOT NULL DEFAULT 0,
        storage_type TEXT NOT NULL DEFAULT 'local',
        reading_progress REAL,
        cached_content TEXT,
        cached_pages TEXT,
        file_modified_time INTEGER,
        content_hash TEXT,
        table_of_contents TEXT,
        cover_image_path TEXT,
        text_encoding TEXT,
        last_canonical_locator TEXT,
        last_rendered_locator TEXT,
        layout_signature TEXT,
        source_id TEXT,
        source_book_id TEXT,
        source_json TEXT,
        source_book_json TEXT,
        source_kind TEXT,
        source_locator TEXT,
        source_modified_time INTEGER
      )
    ''');
    await WebDavSyncSchemaMigration.migrate(database);
  });

  tearDown(() async {
    await database.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('download rejects corrupted content before importing it', () async {
    final remoteBytes = [1, 2, 3, 4];
    final progress = <BookFileTransferProgress>[];
    final importer = _RejectingImporter();
    final client = _DownloadClient(remoteBytes);
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      mutableStateDirectory: () async => temporaryDirectory,
      clientFactory: (_) => client,
      importer: importer,
      temporaryDirectory: () async => temporaryDirectory,
      database: () async => database,
    );

    await expectLater(
      service.download(
        const RemoteBookDescriptor(
          bookUid: 'book-1',
          title: 'Remote book',
          author: 'Author',
          format: 'epub',
          fileAvailable: true,
          sizeBytes: 4,
          blobSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
          remotePath: 'blobs/books/sha256/00/bad',
          fileName: 'remote.epub',
        ),
        onProgress: progress.add,
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
    expect(progress.single.transferredBytes, remoteBytes.length);
    expect(progress.single.fraction, 1);
    expect(client.downloadedUri?.path, endsWith('/blobs/books/sha256/00/bad'));
    expect(temporaryDirectory.listSync().whereType<File>(), isEmpty);
  });

  test('upload rejects files beyond the recoverable import limit', () async {
    final source = File('${temporaryDirectory.path}/large.pdf');
    await source.open(mode: FileMode.write).then((file) async {
      await file.truncate(WebDavBookFileService.maxRecoverableFileBytes + 1);
      await file.close();
    });
    final service = WebDavBookFileService();

    await expectLater(
      service.upload(
        Book(title: 'Large', filePath: source.path, format: 'pdf'),
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (failure) => failure.code,
          'code',
          WebDavSyncErrorCode.invalidConfiguration,
        ),
      ),
    );
  });

  test(
    'upload rejects a downloaded book with a private source identity',
    () async {
      final service = WebDavBookFileService();

      await expectLater(
        service.upload(
          Book(
            title: 'Private source book',
            filePath: '${temporaryDirectory.path}/private.epub',
            format: 'epub',
            sourceId: 'https://example.org/source?token=secret',
            sourceBookId: 'book-1',
          ),
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (failure) => failure.code,
            'code',
            WebDavSyncErrorCode.invalidConfiguration,
          ),
        ),
      );
    },
  );

  test(
    'upload keeps the original book bytes and file name in WebDAV',
    () async {
      final bookBytes = [80, 75, 3, 4, 10, 20, 30, 40];
      final source = File('${temporaryDirectory.path}/我的 书.epub');
      await source.writeAsBytes(bookBytes);
      final client = _MemoryWebDavClient();
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        mutableStateDirectory: () async => temporaryDirectory,
        clientFactory: (_) => client,
        database: () async => database,
      );

      final descriptor = await service.upload(
        Book(
          title: '三体/全集',
          author: '刘慈欣:著',
          filePath: source.path,
          format: 'epub',
        ),
      );

      expect(descriptor.remotePath, 'books/三体_全集 - 刘慈欣_著/我的 书.epub');
      expect(descriptor.fileName, '我的 书.epub');
      expect(client.movedDestinations.single.pathSegments.last, '我的 书.epub');
      expect(
        client.uploadedFiles
            .singleWhere((upload) => upload.uri.path.contains('/books/'))
            .bytes,
        bookBytes,
      );
    },
  );

  test(
    'upload uses a readable number when the cloud name is occupied',
    () async {
      final source = File('${temporaryDirectory.path}/原书.epub');
      await source.writeAsBytes([9, 8, 7, 6]);
      final client = _MemoryWebDavClient(
        existingFiles: {
          '/OpenReading/v1/books/同名书 - 作者/原书.epub': [1, 2, 3, 4],
        },
      );
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        mutableStateDirectory: () async => temporaryDirectory,
        clientFactory: (_) => client,
        temporaryDirectory: () async => temporaryDirectory,
        database: () async => database,
      );

      final descriptor = await service.upload(
        Book(title: '同名书', author: '作者', filePath: source.path, format: 'epub'),
      );

      expect(descriptor.remotePath, 'books/同名书 - 作者 (2)/原书.epub');
      expect(
        client.movedDestinations.single.pathSegments,
        containsAllInOrder(['books', '同名书 - 作者 (2)', '原书.epub']),
      );
    },
  );

  test('upload reuses a readable cloud path when content matches', () async {
    final bytes = [4, 3, 2, 1];
    final source = File('${temporaryDirectory.path}/原书.epub');
    await source.writeAsBytes(bytes);
    final client = _MemoryWebDavClient(
      existingFiles: {'/OpenReading/v1/books/同名书 - 作者/原书.epub': bytes},
    );
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      mutableStateDirectory: () async => temporaryDirectory,
      clientFactory: (_) => client,
      temporaryDirectory: () async => temporaryDirectory,
      database: () async => database,
    );

    final descriptor = await service.upload(
      Book(title: '同名书', author: '作者', filePath: source.path, format: 'epub'),
    );

    expect(descriptor.remotePath, 'books/同名书 - 作者/原书.epub');
    expect(client.movedDestinations, isEmpty);
  });

  test(
    'download restores remote title, author, and cover after import',
    () async {
      final bookBytes = [10, 20, 30, 40];
      final coverBytes = [137, 80, 78, 71, 1, 2, 3];
      final wrongCover = File('${temporaryDirectory.path}/wrong-cover.jpg');
      await wrongCover.writeAsBytes([0, 0, 0]);
      final importer = _DatabaseImporter(database, wrongCover.path);
      final client = _MemoryWebDavClient(
        bookBytes: bookBytes,
        coverBytes: coverBytes,
      );
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        mutableStateDirectory: () async => temporaryDirectory,
        clientFactory: (_) => client,
        importer: importer,
        temporaryDirectory: () async => temporaryDirectory,
        documentsDirectory: () async => temporaryDirectory,
        database: () async => database,
      );
      final bookHash = sha256.convert(bookBytes).toString();
      final coverHash = sha256.convert(coverBytes).toString();

      final restored = await service.download(
        RemoteBookDescriptor(
          bookUid: 'source:source-a:book-a',
          title: '远端正确书名',
          author: '远端正确作者',
          format: 'txt',
          fileAvailable: true,
          sizeBytes: bookBytes.length,
          blobSha256: bookHash,
          remotePath:
              'blobs/books/sha256/${bookHash.substring(0, 2)}/$bookHash',
          fileName: 'book-a.txt',
          sourceId: 'source-a',
          sourceBookId: 'book-a',
          coverAvailable: true,
          coverSizeBytes: coverBytes.length,
          coverBlobSha256: coverHash,
          coverRemotePath:
              'blobs/covers/sha256/${coverHash.substring(0, 2)}/$coverHash',
          coverFileName: 'source-cover.img',
        ),
      );

      expect(restored.title, '远端正确书名');
      expect(restored.author, '远端正确作者');
      expect(restored.sourceId, 'source-a');
      expect(restored.sourceBookId, 'book-a');
      expect(restored.coverImagePath, wrongCover.path);
      expect(await wrongCover.readAsBytes(), coverBytes);

      final bookRow = (await database.query(
        'books',
        where: 'id = ?',
        whereArgs: [restored.id],
      )).single;
      expect(bookRow['title'], '远端正确书名');
      expect(bookRow['author'], '远端正确作者');
      expect(bookRow['cover_image_path'], wrongCover.path);
      expect(bookRow['source_id'], 'source-a');
      expect(bookRow['source_book_id'], 'book-a');

      final fileRow = (await database.query('sync_book_files')).single;
      expect(fileRow['cover_blob_sha256'], coverHash);
      expect(fileRow['cover_file_size'], coverBytes.length);
      expect(fileRow['cover_remote_path'], contains('blobs/covers/sha256/'));
      expect(
        temporaryDirectory.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.part'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'download rejects a corrupted cover before importing and cleans parts',
    () async {
      final bookBytes = [1, 3, 5, 7];
      final coverBytes = [2, 4, 6, 8];
      final importer = _RejectingImporter();
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        mutableStateDirectory: () async => temporaryDirectory,
        clientFactory: (_) =>
            _MemoryWebDavClient(bookBytes: bookBytes, coverBytes: coverBytes),
        importer: importer,
        temporaryDirectory: () async => temporaryDirectory,
        database: () async => database,
      );
      final bookHash = sha256.convert(bookBytes).toString();

      await expectLater(
        service.download(
          RemoteBookDescriptor(
            bookUid: 'book-with-bad-cover',
            title: 'Remote book',
            author: 'Author',
            format: 'txt',
            fileAvailable: true,
            sizeBytes: bookBytes.length,
            blobSha256: bookHash,
            remotePath: 'blobs/books/sha256/00/book',
            fileName: 'book.txt',
            coverAvailable: true,
            coverSizeBytes: coverBytes.length,
            coverBlobSha256: List.filled(64, '0').join(),
            coverRemotePath: 'blobs/covers/sha256/00/cover',
            coverFileName: 'cover.img',
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
      expect(
        temporaryDirectory.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.part'),
        ),
        isEmpty,
      );
    },
  );

  test('upload stores a content-addressed cover reference', () async {
    final bookFile = File('${temporaryDirectory.path}/source-book.txt');
    final coverFile = File('${temporaryDirectory.path}/source-cover.img');
    await bookFile.writeAsBytes([11, 12, 13]);
    await coverFile.writeAsBytes([21, 22, 23, 24]);
    final client = _MemoryWebDavClient();
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      mutableStateDirectory: () async => temporaryDirectory,
      clientFactory: (_) => client,
      database: () async => database,
    );

    final descriptor = await service.upload(
      Book(
        id: 8,
        title: '书源书名',
        author: '书源作者',
        filePath: bookFile.path,
        format: 'txt',
        coverImagePath: coverFile.path,
        sourceId: 'source-a',
        sourceBookId: 'book-a',
      ),
    );

    final coverHash = sha256.convert(await coverFile.readAsBytes()).toString();
    expect(descriptor.title, '书源书名');
    expect(descriptor.author, '书源作者');
    expect(descriptor.coverAvailable, isTrue);
    expect(descriptor.coverBlobSha256, coverHash);
    expect(
      descriptor.coverRemotePath,
      'blobs/covers/sha256/${coverHash.substring(0, 2)}/$coverHash',
    );
    expect(
      client.movedDestinations.where(
        (uri) => uri.path.contains('/blobs/covers/sha256/'),
      ),
      hasLength(1),
    );

    final row = (await database.query('sync_book_files')).single;
    expect(row['cover_blob_sha256'], coverHash);
    expect(row['cover_file_name'], 'source-cover.img');
    expect(row['cover_file_size'], 4);
  });

  test('upload reuses a cover blob that already exists remotely', () async {
    final bookFile = File('${temporaryDirectory.path}/source-book.txt');
    final coverFile = File('${temporaryDirectory.path}/source-cover.img');
    await bookFile.writeAsBytes([31, 32, 33]);
    await coverFile.writeAsBytes([41, 42, 43]);
    final client = _MemoryWebDavClient(coverExists: true);
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      mutableStateDirectory: () async => temporaryDirectory,
      clientFactory: (_) => client,
      database: () async => database,
    );

    await service.upload(
      Book(
        title: 'Book',
        filePath: bookFile.path,
        format: 'txt',
        coverImagePath: coverFile.path,
      ),
    );

    expect(
      client.uploadedUris.where(
        (uri) => uri.path.contains('/blobs/covers/sha256/'),
      ),
      isEmpty,
    );
  });

  test(
    'v2 TXT download stays bound and receives later remote updates',
    () async {
      final firstBytes = utf8.encode('云端第一版');
      final secondBytes = utf8.encode('云端第二版');
      const remoteKey = '/OpenReading/v2/books/c3RhYmxl/current.txt';
      final client = _MemoryWebDavClient(
        existingFiles: {remoteKey: firstBytes},
      );
      final importer = _CopyingDatabaseImporter(database, temporaryDirectory);
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        clientFactory: (_) => client,
        importer: importer,
        temporaryDirectory: () async => temporaryDirectory,
        mutableStateDirectory: () async => temporaryDirectory,
        database: () async => database,
      );

      final restored = await service.download(
        RemoteBookDescriptor(
          bookUid: 'stable',
          title: '同步书',
          author: '作者',
          format: 'txt',
          fileAvailable: true,
          sizeBytes: firstBytes.length,
          blobSha256: sha256.convert(firstBytes).toString(),
          remotePath: 'v2:books/c3RhYmxl/current.txt',
          fileName: '同步书.txt',
        ),
      );

      expect(await File(restored.filePath).readAsString(), '云端第一版');
      expect(
        (await database.query('mutable_txt_bindings')).single['local_book_id'],
        restored.id,
      );
      client.remoteFiles[remoteKey] = secondBytes;
      client._versions[remoteKey] = 2;
      final mutable = MutableTxtSyncService(
        configStore: _CredentialsStore(),
        clientFactory: (_) => client,
        database: () async => database,
        stateDirectory: () async => temporaryDirectory,
      );
      await mutable.reconcile();

      expect(await File(restored.filePath).readAsString(), '云端第二版');
    },
  );

  test('v2 first download persists immutable no-BOM UTF-16 encoding', () async {
    final remoteBytes = <int>[
      for (final unit in '无BOM云端正文'.codeUnits) ...[unit & 0xff, unit >> 8],
    ];
    final remoteHash = sha256.convert(remoteBytes).toString();
    const currentKey = '/OpenReading/v2/books/c3RhYmxl/current.txt';
    final metadataKey = '/OpenReading/v2/revisions/c3RhYmxl/$remoteHash.json';
    final client = _MemoryWebDavClient(
      existingFiles: {
        currentKey: remoteBytes,
        metadataKey: utf8.encode(
          jsonEncode({
            'version': 1,
            'sha256': remoteHash,
            'textEncoding': 'utf16le',
          }),
        ),
      },
    );
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      clientFactory: (_) => client,
      importer: _CopyingDatabaseImporter(database, temporaryDirectory),
      temporaryDirectory: () async => temporaryDirectory,
      mutableStateDirectory: () async => temporaryDirectory,
      database: () async => database,
    );

    final restored = await service.download(
      RemoteBookDescriptor(
        bookUid: 'stable',
        title: 'UTF-16书',
        author: '作者',
        format: 'txt',
        fileAvailable: true,
        sizeBytes: remoteBytes.length,
        blobSha256: remoteHash,
        remotePath: 'v2:books/c3RhYmxl/current.txt',
        fileName: 'utf16.txt',
      ),
    );

    expect(await File(restored.filePath).readAsBytes(), remoteBytes);
    expect(restored.textEncoding, 'utf16le');
    expect(
      (await database.query(
        'books',
        where: 'id = ?',
        whereArgs: [restored.id],
      )).single['text_encoding'],
      'utf16le',
    );
  });

  test(
    'v3 first download reconstructs chunks and keeps incremental binding',
    () async {
      final source = File('${temporaryDirectory.path}/v3-source.txt');
      await source.writeAsString(List.filled(300000, '云端分块正文').join());
      final chunkStore = TxtChunkStore(
        Directory('${temporaryDirectory.path}/source-chunks'),
      );
      final manifest = await chunkStore.capture(source, textEncoding: 'utf-8');
      final remoteFiles = <String, List<int>>{
        '/OpenReading/v3/books/c3RhYmxl/current.json': utf8.encode(
          manifest.encode(),
        ),
      };
      for (final chunk in manifest.chunks) {
        remoteFiles['/OpenReading/v3/chunks/sha256/'
                '${chunk.sha256.substring(0, 2)}/${chunk.sha256}.chunk'] =
            await chunkStore.fileForHash(chunk.sha256).readAsBytes();
      }
      final client = _MemoryWebDavClient(existingFiles: remoteFiles);
      final service = WebDavBookFileService(
        configStore: _CredentialsStore(),
        clientFactory: (_) => client,
        importer: _CopyingDatabaseImporter(database, temporaryDirectory),
        temporaryDirectory: () async => temporaryDirectory,
        mutableStateDirectory: () async =>
            Directory('${temporaryDirectory.path}/receiver-state'),
        database: () async => database,
      );

      final restored = await service.download(
        RemoteBookDescriptor(
          bookUid: 'stable',
          title: '分块书',
          author: '作者',
          format: 'txt',
          fileAvailable: true,
          sizeBytes: manifest.byteLength,
          blobSha256: manifest.contentSha256,
          remotePath: 'v3:books/c3RhYmxl/current.json',
          fileName: 'chunked.txt',
        ),
      );

      expect(
        await File(restored.filePath).readAsBytes(),
        await source.readAsBytes(),
      );
      final binding = (await database.query('mutable_txt_bindings')).single;
      expect(binding['local_book_id'], restored.id);
      expect(binding['protocol_mode'], MutableTxtSyncMode.chunkedV3.name);
      expect(binding['remote_path'], 'v3:books/c3RhYmxl/current.json');
    },
  );

  test('v2 TXT download updates an existing stable UID in place', () async {
    final localFile = File('${temporaryDirectory.path}/existing.txt');
    await localFile.writeAsString('本机已同步旧版');
    final oldHash = sha256.convert(utf8.encode('本机已同步旧版')).toString();
    final remoteBytes = utf8.encode('云端新版');
    final remoteHash = sha256.convert(remoteBytes).toString();
    const remoteKey = '/OpenReading/v2/books/c3RhYmxl/current.txt';
    final bookId = await database.insert('books', {
      'title': '已有书',
      'author': '原作者',
      'filePath': localFile.path,
      'format': 'txt',
      'importDate': DateTime(2026).millisecondsSinceEpoch,
      'content_hash': oldHash,
      'text_encoding': 'utf-8',
    });
    await database.insert('sync_book_files', {
      'book_uid': 'stable',
      'local_book_id': bookId,
      'blob_sha256': oldHash,
      'file_name': 'existing.txt',
      'file_size': await localFile.length(),
      'remote_path': 'v2:books/c3RhYmxl/current.txt',
      'sync_enabled': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    final client = _MemoryWebDavClient(existingFiles: {remoteKey: remoteBytes});
    final importer = _RejectingImporter();
    final service = WebDavBookFileService(
      configStore: _CredentialsStore(),
      clientFactory: (_) => client,
      importer: importer,
      temporaryDirectory: () async => temporaryDirectory,
      mutableStateDirectory: () async => temporaryDirectory,
      database: () async => database,
    );

    final restored = await service.download(
      RemoteBookDescriptor(
        bookUid: 'stable',
        title: '云端书名',
        author: '云端作者',
        format: 'txt',
        fileAvailable: true,
        sizeBytes: remoteBytes.length,
        blobSha256: remoteHash,
        remotePath: 'v2:books/c3RhYmxl/current.txt',
        fileName: 'existing.txt',
      ),
    );

    expect(importer.called, isFalse);
    expect(restored.id, bookId);
    expect(restored.filePath, localFile.path);
    expect(restored.contentHash, remoteHash);
    expect(await localFile.readAsString(), '云端新版');
    expect(await database.query('books'), hasLength(1));
    final row = (await database.query('books')).single;
    expect(row['title'], '云端书名');
    expect(row['author'], '云端作者');
    expect(row['content_hash'], remoteHash);
  });
}

const _credentials = StoredSyncCredentials(
  WebDavSyncConfiguration(
    serverUrl: 'https://dav.example.com',
    username: 'reader',
  ),
  'secret',
);

class _CredentialsStore extends SecureSyncConfigStore {
  @override
  Future<StoredSyncCredentials?> readCredentials() async => _credentials;

  @override
  Future<WebDavSyncScope> readScope() async =>
      const WebDavSyncScope(bookFiles: true);
}

class _DownloadClient extends WebDavClient {
  _DownloadClient(this.bytes) : super(dio: Dio(), credentials: _credentials);

  final List<int> bytes;
  Uri? downloadedUri;

  @override
  Future<void> downloadFile(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    downloadedUri = uri;
    await target.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}

class _MemoryWebDavClient extends WebDavClient {
  _MemoryWebDavClient({
    this.bookBytes = const [],
    this.coverBytes = const [],
    this.coverExists = false,
    Map<String, List<int>> existingFiles = const {},
  }) : remoteFiles = {
         for (final entry in existingFiles.entries)
           entry.key: List<int>.from(entry.value),
       },
       super(dio: Dio(), credentials: _credentials);

  final List<int> bookBytes;
  final List<int> coverBytes;
  final bool coverExists;
  final Map<String, List<int>> remoteFiles;
  final Map<String, List<int>> pendingUploads = {};
  final List<Uri> uploadedUris = [];
  final List<({Uri uri, List<int> bytes})> uploadedFiles = [];
  final List<Uri> movedDestinations = [];
  final Map<String, int> _versions = {};

  @override
  Future<void> ensureProtocolPath(List<String> relativeSegments) async {}

  @override
  Future<void> ensureMutableProtocolPath(List<String> relativeSegments) async {}

  @override
  Future<void> ensureIncrementalMutableProtocolPath(
    List<String> relativeSegments,
  ) async {}

  @override
  Future<void> verifyMutableWritePreconditions() async {}

  @override
  Future<WebDavResourceState> resourceState(Uri uri) async {
    final key = _uriKey(uri);
    final bytes = remoteFiles[key];
    if (bytes == null) return const WebDavResourceState.missing();
    return WebDavResourceState(
      exists: true,
      etag: '"${_versions[key] ?? 1}"',
      contentLength: bytes.length,
    );
  }

  @override
  Future<String?> getText(Uri uri, {bool allowNotFound = false}) async {
    final bytes = remoteFiles[_uriKey(uri)];
    if (bytes == null) {
      if (allowNotFound) return null;
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'missing',
        statusCode: 404,
      );
    }
    return utf8.decode(bytes);
  }

  @override
  Future<WebDavConditionalWriteResult> putFileConditionally(
    Uri uri,
    File file, {
    String? ifMatch,
    bool ifNoneMatch = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final key = _uriKey(uri);
    final exists = remoteFiles.containsKey(key);
    final etag = '"${_versions[key] ?? 1}"';
    if ((ifNoneMatch && exists) ||
        (ifMatch != null && (!exists || ifMatch != etag))) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'precondition failed',
        statusCode: 412,
      );
    }
    final bytes = await file.readAsBytes();
    remoteFiles[key] = bytes;
    final version = (_versions[key] ?? 0) + 1;
    _versions[key] = version;
    onProgress?.call(bytes.length, bytes.length);
    return WebDavConditionalWriteResult(
      etag: '"$version"',
      contentLength: bytes.length,
    );
  }

  @override
  Future<bool> exists(Uri uri) async =>
      remoteFiles.containsKey(_uriKey(uri)) ||
      (coverExists && uri.path.contains('/blobs/covers/sha256/'));

  @override
  Future<void> putFile(
    Uri uri,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    uploadedUris.add(uri);
    final bytes = await file.readAsBytes();
    uploadedFiles.add((uri: uri, bytes: bytes));
    pendingUploads[_uriKey(uri)] = bytes;
    final size = await file.length();
    onProgress?.call(size, size);
  }

  @override
  Future<void> move(
    Uri source,
    Uri destination, {
    bool overwrite = false,
  }) async {
    movedDestinations.add(destination);
    final bytes = pendingUploads[_uriKey(source)];
    if (bytes != null) {
      remoteFiles[_uriKey(destination)] = List<int>.from(bytes);
    }
  }

  @override
  Future<void> delete(Uri uri, {bool allowNotFound = true}) async {}

  @override
  Future<void> downloadFile(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    final bytes =
        remoteFiles[_uriKey(uri)] ??
        (uri.path.contains('/blobs/covers/') ? coverBytes : bookBytes);
    await target.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }

  String _uriKey(Uri uri) => '/${uri.pathSegments.join('/')}';
}

class _DatabaseImporter implements BookFileImporter {
  _DatabaseImporter(this.database, this.wrongCoverPath);

  final Database database;
  final String wrongCoverPath;

  @override
  Future<BookImportResult> importFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    final id = await database.insert('books', {
      'title': '第一章',
      'author': '错误作者',
      'cover_image_path': wrongCoverPath,
    });
    return BookImportResult(
      source: source,
      outcome: BookImportOutcome.imported,
      book: Book(
        id: id,
        title: '第一章',
        author: '错误作者',
        filePath: source.localPath!,
        format: source.extension,
        coverImagePath: wrongCoverPath,
      ),
    );
  }
}

class _RejectingImporter implements BookFileImporter {
  bool called = false;

  @override
  Future<BookImportResult> importFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    called = true;
    throw StateError('Corrupted files must not reach the importer.');
  }
}

class _CopyingDatabaseImporter implements BookFileImporter {
  _CopyingDatabaseImporter(this.database, this.directory);

  final Database database;
  final Directory directory;

  @override
  Future<BookImportResult> importFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    final destination = File('${directory.path}/managed-${source.displayName}');
    await File(source.localPath!).copy(destination.path);
    final id = await database.insert('books', {
      'title': source.displayName,
      'author': '作者',
    });
    return BookImportResult(
      source: source,
      outcome: BookImportOutcome.imported,
      book: Book(
        id: id,
        title: source.displayName,
        author: '作者',
        filePath: destination.path,
        format: 'txt',
      ),
    );
  }
}
