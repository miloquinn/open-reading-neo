import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';

void main() {
  late Directory root;
  late Database database;
  late MemorySyncStorage storage;
  late BookContentSyncService service;

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('book-content-sync-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await _createBookTables(database);
    await WebDavSyncSchemaMigration.migrate(database);
    storage = MemorySyncStorage(spaceKey: 'memory:test');
    service = BookContentSyncService(
      storageProvider: () async => storage,
      database: () async => database,
      stateDirectory: () async => Directory('${root.path}/state'),
    );
  });

  tearDown(() async {
    ReadingProgressSyncService.instance.abandonSession(1);
    await database.close();
    await root.delete(recursive: true);
  });

  test(
    'publishes one readable current, immutable history and CAS head',
    () async {
      final book = await _book(database, root, '正文第一版');
      await service.join(book, bookUid: 'stable-book-uid');

      final first = await service.reconcile();
      expect(first.uploaded, 1);
      final objects = await _allObjects(storage, SyncPath('books'));
      expect(
        objects.where((o) => o.path.value.endsWith('/current.txt')),
        hasLength(1),
      );
      expect(
        objects.where((o) => o.path.value.contains('/history/')),
        hasLength(1),
      );
      expect(
        objects.where((o) => o.path.value.endsWith('/book.json')),
        hasLength(1),
      );
      expect(
        objects.every(
          (o) =>
              !o.path.value.contains('/v1/') &&
              !o.path.value.contains('/v2/') &&
              !o.path.value.contains('/v3/'),
        ),
        isTrue,
      );

      final current = objects.singleWhere(
        (o) => o.path.value.endsWith('/current.txt'),
      );
      expect(await _read(storage, current.path), utf8.encode('正文第一版'));
      final unchangedVersion = current.version;
      final second = await service.reconcile();
      expect(second.uploaded, 0);
      expect((await storage.stat(current.path))!.version, unchangedVersion);

      final state = (await service.listStates()).single;
      expect(state.status, BookContentSyncStatus.synced);
      expect(state.localHash, state.baseHash);
      expect(state.remotePath, current.path.value);
    },
  );

  test(
    'head failure stays unavailable and a retry repairs the exact current',
    () async {
      final book = await _book(database, root, '断点恢复');
      final failing = _FailHeadStorage(storage);
      final recovering = BookContentSyncService(
        storageProvider: () async => failing,
        database: () async => database,
        stateDirectory: () async => Directory('${root.path}/state'),
      );
      await recovering.join(book, bookUid: 'recover-book');
      final first = await recovering.reconcile();
      expect(first.failed, 1);
      expect(
        (await recovering.listStates()).single.status,
        BookContentSyncStatus.failed,
      );
      expect(await database.query('sync_book_files'), isEmpty);

      final second = await recovering.reconcile();
      expect(second.failed, 0);
      expect(
        (await recovering.listStates()).single.status,
        BookContentSyncStatus.synced,
      );
      expect(
        (await database.query('sync_book_files')).single['blob_sha256'],
        isNotNull,
      );
    },
  );

  test(
    'GBK bytes remain byte-identical and retain a readable txt extension',
    () async {
      final bytes = gbk.encode('第一章\n中文正文');
      final file = File('${root.path}/国标编码.txt');
      await file.writeAsBytes(bytes, flush: true);
      final storedBytes = await file.readAsBytes();
      final book = Book(
        id: 1,
        title: '国标编码',
        author: '作者',
        filePath: file.path,
        format: 'txt',
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
      await service.join(book, bookUid: 'gbk-book');
      await service.reconcile();
      final current = (await _allObjects(
        storage,
        SyncPath('books'),
      )).singleWhere((object) => object.path.value.endsWith('/current.txt'));
      expect(await _read(storage, current.path), storedBytes);
    },
  );

  test(
    'paused books do not upload and resume with the latest revision',
    () async {
      final book = await _book(database, root, '暂停前');
      await service.join(book, bookUid: 'paused-book');
      await service.setEnabled('paused-book', false);
      await File(book.filePath).writeAsString('暂停后修改', flush: true);
      await service.enqueueLocalUpdate(book, bookUid: 'paused-book');
      expect((await service.reconcile()).uploaded, 0);
      expect((await _allObjects(storage, SyncPath('books'))), isEmpty);
      await service.setEnabled('paused-book', true);
      expect((await service.reconcile()).uploaded, 1);
    },
  );

  test(
    'changed content uploads the full current and retains both histories',
    () async {
      final book = await _book(database, root, '第一版');
      await service.join(book, bookUid: 'edited-book');
      await service.reconcile();
      final current = (await _allObjects(
        storage,
        SyncPath('books'),
      )).singleWhere((o) => o.path.value.endsWith('/current.txt'));
      final firstVersion = current.version;

      await File(book.filePath).writeAsString('第二版', flush: true);
      await service.enqueueLocalUpdate(book, bookUid: 'edited-book');
      final result = await service.reconcile();

      expect(result.uploaded, 1);
      expect(result.uploadedBytes, utf8.encode('第二版').length);
      expect((await storage.stat(current.path))!.version, isNot(firstVersion));
      expect(
        (await _allObjects(
          storage,
          SyncPath('books'),
        )).where((o) => o.path.value.contains('/history/')),
        hasLength(2),
      );
    },
  );

  test('external cloud edit is adopted without a GET then HEAD race', () async {
    final book = await _book(database, root, '本地基线');
    await service.join(book, bookUid: 'external-edit');
    await service.reconcile();
    final current = (await _allObjects(
      storage,
      SyncPath('books'),
    )).singleWhere((o) => o.path.value.endsWith('/current.txt'));
    final bytes = utf8.encode('坚果云里直接修改');
    await storage.compareAndSwap(
      current.path,
      Stream.value(bytes),
      length: bytes.length,
      contentType: 'text/plain',
      expectedVersion: current.version,
    );

    final observed = await service.reconcile();
    expect(observed.downloaded, 0);
    expect(
      (await service.listStates()).single.status,
      BookContentSyncStatus.updateAvailable,
    );
    final result = await service.reconcile();
    expect(result.downloaded, 1);
    expect(await File(book.filePath).readAsString(), '坚果云里直接修改');
    final head = (await _allObjects(
      storage,
      SyncPath('books'),
    )).singleWhere((o) => o.path.value.endsWith('/book.json'));
    final json =
        jsonDecode(
              (await storage.readText(
                head.path,
                expectedVersion: head.version,
              )).text,
            )
            as Map<String, dynamic>;
    expect(json['current_sha256'], sha256.convert(bytes).toString());
  });

  test(
    'divergent local and cloud edits preserve both conflict snapshots',
    () async {
      final book = await _book(database, root, '共同基线');
      await service.join(book, bookUid: 'conflict-book');
      await service.reconcile();
      final current = (await _allObjects(
        storage,
        SyncPath('books'),
      )).singleWhere((o) => o.path.value.endsWith('/current.txt'));
      final remoteBytes = utf8.encode('云端编辑');
      await storage.compareAndSwap(
        current.path,
        Stream.value(remoteBytes),
        length: remoteBytes.length,
        contentType: 'text/plain',
        expectedVersion: current.version,
      );
      await File(book.filePath).writeAsString('本地编辑', flush: true);
      await service.enqueueLocalUpdate(book, bookUid: 'conflict-book');

      final observed = await service.reconcile();
      expect(observed.conflicts, 0);
      final result = await service.reconcile();
      expect(result.conflicts, 1);
      expect(await File(book.filePath).readAsString(), '本地编辑');
      final conflict = (await service.listConflicts()).single;
      expect(await File(conflict.localSnapshotPath).readAsString(), '本地编辑');
      expect(await File(conflict.remoteSnapshotPath).readAsString(), '云端编辑');
      expect(
        (await service.listStates()).single.status,
        BookContentSyncStatus.conflict,
      );
    },
  );

  test(
    'active reader stages a remote revision until explicitly applied',
    () async {
      final book = await _book(database, root, '正在阅读');
      await service.join(book, bookUid: 'active-reader');
      await service.reconcile();
      final current = (await _allObjects(
        storage,
        SyncPath('books'),
      )).singleWhere((o) => o.path.value.endsWith('/current.txt'));
      final bytes = utf8.encode('云端新正文');
      await storage.compareAndSwap(
        current.path,
        Stream.value(bytes),
        length: bytes.length,
        contentType: 'text/plain',
        expectedVersion: current.version,
      );
      ReadingProgressSyncService.instance.beginOpening(book);
      await service.reconcile();
      expect(
        (await service.listStates()).single.status,
        BookContentSyncStatus.updateAvailable,
      );
      expect(await File(book.filePath).readAsString(), '正在阅读');
      expect(await service.applyAvailableUpdate('active-reader'), isFalse);
      ReadingProgressSyncService.instance.cancelOpening(book.id!);
      expect(await service.applyAvailableUpdate('active-reader'), isTrue);
      expect(await File(book.filePath).readAsString(), '云端新正文');
    },
  );

  test(
    'source sidecar change advances head without rewriting current',
    () async {
      final book = await _book(database, root, '连载正文');
      await service.join(book, bookUid: 'serial-book');
      await service.reconcile();
      final current = (await _allObjects(
        storage,
        SyncPath('books'),
      )).singleWhere((o) => o.path.value.endsWith('/current.txt'));
      final currentVersion = current.version;
      final hash = sha256.convert(utf8.encode('连载正文')).toString();
      await const SourceChapterStateStore().save(
        book,
        SourceChapterState(
          schemaVersion: 1,
          bookUid: 'serial-book',
          sourceId: 'source',
          sourceBookId: 'novel',
          materializedContentHash: hash,
          baselineKnown: true,
          chapters: const [],
          catalogChapterIds: const [],
          conflicts: const [],
          revisionOrigin: SourceRevisionOrigin.sourceAppend,
        ),
      );
      await service.enqueueLocalUpdate(
        book,
        bookUid: 'serial-book',
        origin: 'source_append',
      );
      final result = await service.reconcile();
      expect(result.uploadedBytes, 0);
      expect((await storage.stat(current.path))!.version, currentVersion);
      final sourceFiles = (await storage.list(
        SyncPath(
          current.path.value.substring(0, current.path.value.lastIndexOf('/')),
        ),
      )).prefixes;
      expect(sourceFiles.map((p) => p.value), contains(endsWith('/source')));
    },
  );

  test(
    'a second device restores source baseline instead of clearing it',
    () async {
      final book = await _book(database, root, '连载正文');
      final contentHash = sha256.convert(utf8.encode('连载正文')).toString();
      await const SourceChapterStateStore().save(
        book,
        SourceChapterState(
          schemaVersion: 1,
          bookUid: 'cross-device-serial',
          sourceId: 'source',
          sourceBookId: 'novel',
          materializedContentHash: contentHash,
          baselineKnown: true,
          chapters: const [],
          catalogChapterIds: const ['chapter-1'],
          conflicts: const [],
          revisionOrigin: SourceRevisionOrigin.initialDownload,
        ),
      );
      await service.join(book, bookUid: 'cross-device-serial');
      await service.reconcile();

      final secondRoot = await Directory.systemTemp.createTemp(
        'second-device-',
      );
      final secondDb = await databaseFactoryFfi.openDatabase(
        '${secondRoot.path}/second.sqlite',
      );
      try {
        await _createBookTables(secondDb);
        await WebDavSyncSchemaMigration.migrate(secondDb);
        final second = await _book(secondDb, secondRoot, '连载正文');
        final secondService = BookContentSyncService(
          storageProvider: () async => storage,
          database: () async => secondDb,
          stateDirectory: () async => Directory('${secondRoot.path}/state'),
        );
        await secondService.join(second, bookUid: 'cross-device-serial');
        final result = await secondService.reconcile();
        expect(result.downloaded, 1);
        final restored = await const SourceChapterStateStore().load(second);
        expect(restored?.bookUid, 'cross-device-serial');
        expect(restored?.catalogChapterIds, ['chapter-1']);
        expect(restored?.materializedContentHash, contentHash);
      } finally {
        await secondDb.close();
        await secondRoot.delete(recursive: true);
      }
    },
  );
}

Future<List<int>> _read(MemorySyncStorage storage, SyncPath path) async {
  final temp = await Directory.systemTemp.createTemp('storage-read-');
  final file = File('${temp.path}/value');
  try {
    final info = await storage.stat(path);
    final sink = file.openWrite();
    try {
      await storage.download(path, sink, expectedVersion: info!.version);
    } finally {
      await sink.close();
    }
    return file.readAsBytes();
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<List<SyncObjectInfo>> _allObjects(
  MemorySyncStorage storage,
  SyncPath prefix,
) async {
  final listing = await storage.list(prefix);
  final result = <SyncObjectInfo>[...listing.objects];
  for (final child in listing.prefixes) {
    result.addAll(await _allObjects(storage, child));
  }
  return result;
}

Future<Book> _book(Database db, Directory root, String content) async {
  final file = File('${root.path}/小说.txt');
  await file.writeAsString(content, flush: true);
  final book = Book(
    id: 1,
    title: '小说',
    author: '作者',
    filePath: file.path,
    format: 'txt',
  );
  await db.insert('books', {
    'id': 1,
    'title': book.title,
    'author': book.author,
    'filePath': book.filePath,
    'format': book.format,
    'currentPage': 0,
    'totalPages': 1,
    'importDate': book.importDate.millisecondsSinceEpoch,
  });
  return book;
}

Future<void> _createBookTables(Database db) async {
  await db.execute('''
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
  await db.execute('''
    CREATE TABLE book_notes(
      id INTEGER PRIMARY KEY, book_id INTEGER, canonical_locator TEXT,
      payload_json TEXT, start_offset INTEGER, end_offset INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE bookmarks(
      id INTEGER PRIMARY KEY, bookId INTEGER, canonical_locator TEXT,
      anchor_key TEXT
    )
  ''');
}

class _FailHeadStorage implements SyncStorage {
  _FailHeadStorage(this.delegate);
  final MemorySyncStorage delegate;
  bool failNextHead = true;

  @override
  SyncStorageCapabilities get capabilities => delegate.capabilities;
  @override
  String get spaceKey => delegate.spaceKey;
  @override
  DateTime? get serverDate => delegate.serverDate;
  @override
  Future<SyncListing> list(SyncPath prefix) => delegate.list(prefix);
  @override
  Future<SyncObjectInfo?> stat(SyncPath path) => delegate.stat(path);
  @override
  Future<SyncTextRead> readText(
    SyncPath path, {
    SyncObjectVersion? expectedVersion,
  }) => delegate.readText(path, expectedVersion: expectedVersion);
  @override
  Future<SyncDownload> download(
    SyncPath path,
    IOSink destination, {
    SyncObjectVersion? expectedVersion,
  }) => delegate.download(path, destination, expectedVersion: expectedVersion);
  @override
  Future<SyncWrite> create(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
  }) {
    if (failNextHead && path.value.endsWith('/book.json')) {
      failNextHead = false;
      throw const SyncStorageException(
        SyncStorageErrorCode.network,
        'Injected head failure',
      );
    }
    return delegate.create(
      path,
      bytes,
      length: length,
      contentType: contentType,
    );
  }

  @override
  Future<SyncWrite> compareAndSwap(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    required SyncObjectVersion expectedVersion,
  }) => delegate.compareAndSwap(
    path,
    bytes,
    length: length,
    contentType: contentType,
    expectedVersion: expectedVersion,
  );
  @override
  Future<void> delete(
    SyncPath path, {
    required SyncObjectVersion expectedVersion,
  }) => delegate.delete(path, expectedVersion: expectedVersion);
}
