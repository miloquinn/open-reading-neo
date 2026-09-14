import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'package:xxread/services/sync/book_revision_repository.dart';
import 'package:xxread/services/sync/storage/immutable_object_store.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_models.dart';

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

  Future<BookRevisionRepository> repo(String device) async =>
      BookRevisionRepository(
        ImmutableObjectStore(storage, Directory('${root.path}/$device-cache')),
      );

  Future<BookRevision> current(String uid) async {
    final id = (await service.listStates())
        .singleWhere((s) => s.bookUid == uid)
        .remoteVersion!;
    return (await repo('inspect')).read(uid, id);
  }

  Future<BookRevision> remoteEdit(String uid, String content) async {
    final base = await current(uid);
    final file = File('${root.path}/remote.txt');
    await file.writeAsString(content, flush: true);
    return (await repo('remote')).publish(
      bookUid: uid,
      file: file,
      hash: await ImmutableObjectStore.hashFile(file),
      format: 'txt',
      fileName: 'book.txt',
      parents: [base.id],
      metadata: {'source_state_sha256': null, 'source_assets': []},
      base: base,
    );
  }

  test(
    'one immutable revision replaces current plus duplicate history; idle transfers zero bytes',
    () async {
      final book = await _book(database, root, '正文第一版');
      await service.join(book, bookUid: 'stable-book');
      final first = await service.reconcile();
      expect(first.failed, 0);
      expect(first.uploaded, 1);
      final revision = await current('stable-book');
      expect(revision.hash, sha256.convert(utf8.encode('正文第一版')).toString());
      final objects = await _allObjects(storage, SyncPath('books'));
      expect(
        objects.where((o) => o.path.value.contains('/revisions/')),
        hasLength(1),
      );
      expect(
        objects.where((o) => o.path.value.contains('/chunks/')),
        hasLength(1),
      );
      expect(
        objects.any(
          (o) =>
              o.path.value.endsWith('/current.txt') ||
              o.path.value ==
                  'books/${BookRevisionRepository.folder('stable-book')}/book.json',
        ),
        isFalse,
      );
      final second = await service.reconcile();
      expect(second.failed, 0);
      expect(second.uploaded, 0);
      expect(second.downloaded, 0);
      expect(second.uploadedBytes, 0);
      expect(second.downloadedBytes, 0);
      expect(
        (await service.listStates()).single.status,
        BookContentSyncStatus.synced,
      );
    },
  );

  test(
    'revision publication failure remains unavailable and retry reuses uploaded blocks',
    () async {
      final book = await _book(database, root, '断点恢复');
      final failing = _RevisionFaultStorage(storage);
      final recovering = BookContentSyncService(
        storageProvider: () async => failing,
        database: () async => database,
        stateDirectory: () async => Directory('${root.path}/state'),
      );
      await recovering.join(book, bookUid: 'recover-book');
      expect((await recovering.reconcile()).failed, 1);
      expect(await database.query('sync_book_files'), isEmpty);
      final chunks = (await _allObjects(
        storage,
        SyncPath('books'),
      )).where((o) => o.path.value.contains('/chunks/')).toList();
      final result = await recovering.reconcile();
      expect(result.failed, 0);
      expect(
        (await recovering.listStates()).single.status,
        BookContentSyncStatus.synced,
      );
      expect(await storage.stat(chunks.single.path), isNotNull);
      expect(result.uploadedBytes, lessThan(2048));
    },
  );

  test('GBK bytes remain byte identical after chunk reconstruction', () async {
    final book = await _book(database, root, 'placeholder');
    final bytes = gbk.encode('第一章\n中文正文');
    await File(book.filePath).writeAsBytes(bytes);
    await service.join(book, bookUid: 'gbk');
    expect((await service.reconcile()).failed, 0);
    final output = File('${root.path}/restored.txt');
    final revision = await current('gbk');
    await (await repo('restore')).materialize(revision, output);
    expect(await output.readAsBytes(), await File(book.filePath).readAsBytes());
  });

  test(
    'paused books do not upload and resume with latest local revision',
    () async {
      final book = await _book(database, root, '暂停前');
      await service.join(book, bookUid: 'paused');
      await service.setEnabled('paused', false);
      await File(book.filePath).writeAsString('暂停后');
      await service.enqueueLocalUpdate(book, bookUid: 'paused');
      expect((await service.reconcile()).uploaded, 0);
      expect(await _allObjects(storage, SyncPath('books')), isEmpty);
      await service.setEnabled('paused', true);
      expect((await service.reconcile()).uploaded, 1);
    },
  );

  test(
    'a prefix insertion reuses most blocks and another device reconstructs exact bytes',
    () async {
      final random = Random(7);
      final bytes = List<int>.generate(
        8 * 1024 * 1024,
        (_) => random.nextInt(256),
      );
      final book = await _book(database, root, 'placeholder');
      await File(book.filePath).writeAsBytes(bytes);
      await service.join(book, bookUid: 'large');
      expect((await service.reconcile()).failed, 0);
      final first = await current('large');
      final edited = [65, 66, 67, ...bytes];
      await File(book.filePath).writeAsBytes(edited);
      await service.enqueueLocalUpdate(book, bookUid: 'large');
      final result = await service.reconcile();
      expect(result.failed, 0);
      expect(result.uploadedBytes, lessThan(1024 * 1024));
      final second = await current('large');
      expect(second.parents, [first.id]);
      final output = File('${root.path}/large-restored.txt');
      await (await repo('second-device')).materialize(second, output);
      expect(
        await ImmutableObjectStore.hashFile(output),
        sha256.convert(edited).toString(),
      );
      expect(await output.length(), edited.length);
    },
  );

  test(
    'remote successor is applied without overwriting unrelated local changes',
    () async {
      final book = await _book(database, root, '基线');
      await service.join(book, bookUid: 'remote');
      await service.reconcile();
      await remoteEdit('remote', '远端新版');
      final result = await service.reconcile();
      expect(result.failed, 0);
      expect(result.downloaded, 1);
      expect(await File(book.filePath).readAsString(), '远端新版');
    },
  );

  test(
    'concurrent edits preserve both snapshots and explicit local choice merges parents',
    () async {
      final book = await _book(database, root, '共同基线');
      await service.join(book, bookUid: 'conflict');
      await service.reconcile();
      final remote = await remoteEdit('conflict', '远端修改');
      await File(book.filePath).writeAsString('本地修改');
      await service.enqueueLocalUpdate(book, bookUid: 'conflict');
      expect((await service.reconcile()).conflicts, 1);
      final conflict = (await service.listConflicts()).single;
      expect(await File(conflict.localSnapshotPath).readAsString(), '本地修改');
      expect(await File(conflict.remoteSnapshotPath).readAsString(), '远端修改');
      await service.resolveConflict(
        conflict.id,
        BookContentConflictChoice.keepLocal,
      );
      expect((await service.reconcile()).conflicts, 0);
      final tips = await (await repo('review')).tips('conflict');
      expect(tips, hasLength(1));
      expect(tips.single.parents, contains(remote.id));
      expect(await File(book.filePath).readAsString(), '本地修改');
    },
  );

  test(
    'active reader stages the remote revision before an explicit safe apply',
    () async {
      final book = await _book(database, root, '旧正文');
      await service.join(book, bookUid: 'reading');
      await service.reconcile();
      await remoteEdit('reading', '新正文');
      ReadingProgressSyncService.instance.beginOpening(book);
      expect((await service.reconcile()).downloaded, 0);
      expect(
        (await service.listStates()).single.status,
        BookContentSyncStatus.updateAvailable,
      );
      expect(await File(book.filePath).readAsString(), '旧正文');
      ReadingProgressSyncService.instance.abandonSession(1);
      expect(await service.applyAvailableUpdate('reading'), isTrue);
      expect(await File(book.filePath).readAsString(), '新正文');
    },
  );

  test(
    'explicit remote choice commits the decision before applying the file',
    () async {
      final book = await _book(database, root, 'base');
      await service.join(book, bookUid: 'remote-choice');
      await service.reconcile();
      final remote = await remoteEdit('remote-choice', 'remote edit');
      await File(book.filePath).writeAsString('local edit');
      await service.enqueueLocalUpdate(book, bookUid: 'remote-choice');
      expect((await service.reconcile()).conflicts, 1);
      final conflict = (await service.listConflicts()).single;
      await service.resolveConflict(
        conflict.id,
        BookContentConflictChoice.useRemote,
      );
      expect(await File(book.filePath).readAsString(), 'remote edit');
      expect(
        await File(conflict.localSnapshotPath).readAsString(),
        'local edit',
      );
      final tips = await (await repo('review')).tips('remote-choice');
      expect(tips, hasLength(1));
      expect(tips.single.parents, contains(remote.id));
      expect((await service.reconcile()).conflicts, 0);
      expect(await service.listConflicts(), isEmpty);
    },
  );

  test(
    'a new cloud branch invalidates an already displayed conflict choice',
    () async {
      final book = await _book(database, root, 'base');
      await service.join(book, bookUid: 'stale-choice');
      await service.reconcile();
      await remoteEdit('stale-choice', 'first remote edit');
      await File(book.filePath).writeAsString('local edit');
      await service.enqueueLocalUpdate(book, bookUid: 'stale-choice');
      expect((await service.reconcile()).conflicts, 1);
      final conflict = (await service.listConflicts()).single;
      await remoteEdit('stale-choice', 'concurrent third device');
      await expectLater(
        service.resolveConflict(
          conflict.id,
          BookContentConflictChoice.useRemote,
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (e) => e.code,
            'code',
            WebDavSyncErrorCode.conflict,
          ),
        ),
      );
      expect(await File(book.filePath).readAsString(), 'local edit');
      expect(await service.listConflicts(), hasLength(1));
      expect(await (await repo('review')).tips('stale-choice'), hasLength(2));
    },
  );

  test(
    'explicit export creates a readable immutable copy without another sync mode',
    () async {
      final book = await _book(database, root, '可读导出');
      await service.join(book, bookUid: 'export');
      await service.reconcile();
      final remote = await service.exportBook('export');
      expect(remote, startsWith('exports/'));
      expect(remote, endsWith('.txt'));
      expect(await _read(storage, SyncPath(remote)), utf8.encode('可读导出'));
      final idle = await service.reconcile();
      expect(idle.uploadedBytes, 0);
      expect(idle.downloadedBytes, 0);
    },
  );

  test(
    'an edit during upload stays pending instead of being marked uploaded',
    () async {
      final book = await _book(database, root, 'first');
      final fault = _RevisionFaultStorage(storage)..failNextRevision = false;
      final active = BookContentSyncService(
        storageProvider: () async => fault,
        database: () async => database,
        stateDirectory: () async => Directory('${root.path}/state'),
      );
      await active.join(book, bookUid: 'inflight');
      fault.beforeRevision = () async {
        await File(book.filePath).writeAsString('edited while uploading');
        await active.enqueueLocalUpdate(book, bookUid: 'inflight');
      };
      final result = await active.reconcile();
      expect(result.failed, 0);
      expect(
        (await active.listStates()).single.status,
        BookContentSyncStatus.pending,
      );
      expect(
        await File(book.filePath).readAsString(),
        'edited while uploading',
      );
      expect((await active.reconcile()).uploaded, 1);
      expect(
        (await active.listStates()).single.status,
        BookContentSyncStatus.synced,
      );
    },
  );

  test(
    'recreating a cloud space cannot reuse cached upload completion',
    () async {
      final book = await _book(database, root, 'preserve local');
      await service.join(book, bookUid: 'recreated');
      await service.reconcile();
      for (final object in await _allObjects(storage, SyncPath('books'))) {
        await storage.delete(object.path, expectedVersion: object.version);
      }
      final marker = (await storage.stat(SyncPath('format.json')))!;
      await storage.delete(marker.path, expectedVersion: marker.version);
      final result = await service.reconcile();
      expect(result.uploaded, 1);
      expect(result.uploadedBytes, greaterThan(0));
      expect(result.downloadedBytes, greaterThan(0));
      expect(await File(book.filePath).readAsString(), 'preserve local');
    },
  );

  test(
    'metadata initialization preserves files already committed to the same space',
    () async {
      final book = await _book(database, root, 'committed first');
      await service.join(book, bookUid: 'first-file');
      await service.reconcile();
      final binding = (await database.query('book_content_bindings')).single;
      await SyncChangeStore(
        database: () async => database,
      ).resetRemoteMirrorForNewSpace(
        preserveFileSpace: binding['space_key'] as String,
      );
      expect(
        (await database.query('sync_book_files')).single['book_uid'],
        'first-file',
      );
    },
  );

  test(
    'manual retry bypasses durable file backoff while automatic attempts wait',
    () async {
      final book = await _book(database, root, 'retry');
      final failing = _RevisionFaultStorage(storage);
      final active = BookContentSyncService(
        storageProvider: () async => failing,
        database: () async => database,
        stateDirectory: () async => Directory('${root.path}/state'),
      );
      await active.join(book, bookUid: 'retry');
      expect((await active.reconcile()).failed, 1);
      expect((await active.reconcile(respectBackoff: true)).uploaded, 0);
      expect(
        (await active.listStates()).single.status,
        BookContentSyncStatus.failed,
      );
      expect((await active.reconcile()).uploaded, 1);
    },
  );

  test(
    'a second device restores source baseline and shared chapter identity',
    () async {
      final book = await _book(database, root, '连载正文');
      final contentHash = sha256.convert(utf8.encode('连载正文')).toString();
      await const SourceChapterStateStore().save(
        book,
        SourceChapterState(
          schemaVersion: 1,
          bookUid: 'serial',
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
      await service.join(book, bookUid: 'serial');
      expect((await service.reconcile()).failed, 0);
      final secondRoot = await Directory('${root.path}/second').create();
      final secondDb = await databaseFactoryFfi.openDatabase(
        '${secondRoot.path}/second.sqlite',
      );
      try {
        await _createBookTables(secondDb);
        await WebDavSyncSchemaMigration.migrate(secondDb);
        final secondBook = await _book(secondDb, secondRoot, '连载正文');
        final second = BookContentSyncService(
          storageProvider: () async => storage,
          database: () async => secondDb,
          stateDirectory: () async => Directory('${secondRoot.path}/state'),
        );
        await second.join(secondBook, bookUid: 'serial');
        final result = await second.reconcile();
        expect(result.failed, 0);
        expect(result.downloaded, 1);
        final restored = await const SourceChapterStateStore().load(secondBook);
        expect(restored?.catalogChapterIds, ['chapter-1']);
        expect(restored?.materializedContentHash, contentHash);
      } finally {
        await secondDb.close();
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
    return await file.readAsBytes();
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

class _RevisionFaultStorage implements SyncStorage {
  _RevisionFaultStorage(this.delegate);
  final MemorySyncStorage delegate;
  bool failNextRevision = true;
  Future<void> Function()? beforeRevision;

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
  }) async {
    if (path.value.contains('/revisions/') && beforeRevision != null) {
      final callback = beforeRevision!;
      beforeRevision = null;
      await callback();
    }
    if (failNextRevision && path.value.contains('/revisions/')) {
      failNextRevision = false;
      throw const SyncStorageException(
        SyncStorageErrorCode.network,
        'Injected head failure',
      );
    }
    return await delegate.create(
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
