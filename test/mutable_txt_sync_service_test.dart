import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/webdav_sync_schema_migration.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/mutable_txt_sync_service.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/txt_chunk_manifest.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  late Directory root;
  late Database database;
  late _FakeDavStore dav;
  late _TestConfigStore config;

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('mutable-txt-sync-test-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books(
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        filePath TEXT NOT NULL,
        format TEXT NOT NULL,
        currentPage INTEGER NOT NULL DEFAULT 0,
        totalPages INTEGER NOT NULL DEFAULT 1,
        importDate INTEGER NOT NULL,
        storage_type TEXT NOT NULL DEFAULT 'local',
        content_hash TEXT,
        file_modified_time INTEGER,
        cached_content TEXT,
        cached_pages TEXT,
        table_of_contents TEXT,
        text_encoding TEXT,
        last_canonical_locator TEXT,
        last_rendered_locator TEXT,
        layout_signature TEXT,
        reading_progress REAL,
        cover_image_path TEXT,
        source_id TEXT,
        source_book_id TEXT,
        source_json TEXT,
        source_book_json TEXT,
        source_kind TEXT,
        source_locator TEXT,
        source_modified_time INTEGER
      )
    ''');
    await database.execute('''
      CREATE TABLE book_notes (
        id INTEGER PRIMARY KEY, book_id INTEGER, content TEXT, cfi TEXT,
        canonical_locator TEXT, payload_json TEXT, chapter TEXT, type TEXT,
        color TEXT, reader_note TEXT, page_number INTEGER,
        start_offset INTEGER, end_offset INTEGER, create_time TEXT,
        update_time TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY, bookId INTEGER, pageNumber INTEGER,
        note TEXT, createDate INTEGER, cfi TEXT, canonical_locator TEXT,
        anchor_key TEXT, chapter_index INTEGER, chapter_title TEXT,
        excerpt TEXT
      )
    ''');
    await WebDavSyncSchemaMigration.migrate(database);
    dav = _FakeDavStore();
    config = _TestConfigStore();
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  MutableTxtSyncService service(Directory stateRoot) => MutableTxtSyncService(
    configStore: config,
    clientFactory: (_) => _FakeDavClient(dav),
    database: () async => database,
    stateDirectory: () async => stateRoot,
  );

  Future<Book> createBook(String name, String content, {int id = 1}) async {
    final file = File('${root.path}/$name.txt');
    await file.writeAsString(content);
    final book = Book(
      id: id,
      title: name,
      author: '作者',
      filePath: file.path,
      format: 'txt',
    );
    await database.insert('books', {
      'id': id,
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

  test(
    'publishes edits to one stable current path and durable revisions',
    () async {
      final book = await createBook('同一本书', '第一版');
      final sync = service(Directory('${root.path}/state'));

      await sync.join(book, bookUid: 'stable-book');
      final first = await sync.reconcile();
      expect(first.uploaded, 1);
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      expect(dav.text(currentPath), '第一版');

      await File(book.filePath).writeAsString('第二版');
      await sync.enqueueLocalUpdate(book, bookUid: 'stable-book');
      final second = await sync.reconcile();

      expect(second.uploaded, 1);
      expect(dav.paths.where((key) => key.endsWith('/current.txt')), [
        currentPath,
      ]);
      expect(dav.text(currentPath), '第二版');
      expect(
        dav.paths.where(
          (key) => key.contains('/v2/revisions/') && key.endsWith('.txt'),
        ),
        hasLength(2),
      );
      final state = (await sync.listStates()).single;
      expect(state.status, MutableTxtSyncStatus.synced);
      expect(state.remotePath, startsWith('v2:books/'));
    },
  );

  test(
    'explicit v3 upgrade uploads only nearby chunks after an edit',
    () async {
      final random = Random(812);
      final content = String.fromCharCodes(
        List<int>.generate(4 * 1024 * 1024, (_) => 32 + random.nextInt(95)),
      );
      final book = await createBook('增量书', content);
      final sync = service(Directory('${root.path}/state'));

      await sync.join(book, bookUid: 'incremental-book');
      await sync.enableIncremental('incremental-book');
      final first = await sync.reconcile();
      final firstChunkBytes = dav.chunkUploadBytes;

      expect(first.uploaded, 1);
      expect(firstChunkBytes, content.length);
      expect(
        (await sync.listStates()).single.mode,
        MutableTxtSyncMode.chunkedV3,
      );
      expect((await sync.listStates()).single.remotePath, startsWith('v3:'));
      expect(dav.paths.where((path) => path.endsWith('/current.txt')), isEmpty);
      expect(
        dav.paths.where((path) => path.endsWith('/current.json')),
        hasLength(1),
      );

      final file = File(book.filePath);
      final edited =
          '${content.substring(0, 4096)}新增正文${content.substring(4096)}';
      await file.writeAsString(edited);
      await sync.enqueueLocalUpdate(book, bookUid: 'incremental-book');
      final second = await sync.reconcile();
      final incrementalBytes = dav.chunkUploadBytes - firstChunkBytes;

      expect(second.uploaded, 1);
      expect(incrementalBytes, lessThan(1024 * 1024));
      expect(incrementalBytes, lessThan(edited.length ~/ 4));
    },
  );

  test(
    'same content hash with altered chunks never clears the queued edit',
    () async {
      final book = await createBook('伪造分块清单', '第一版');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'bad-same-hash', incremental: true);
      await sync.reconcile();
      await File(book.filePath).writeAsString('第二版正文');
      await sync.enqueueLocalUpdate(book, bookUid: 'bad-same-hash');
      final localManifest = await const TxtChunkManifestBuilder().build(
        File(book.filePath),
        textEncoding: 'utf8',
      );
      final originalChunk = localManifest.chunks.single;
      final altered = TxtChunkManifest(
        contentSha256: localManifest.contentSha256,
        byteLength: localManifest.byteLength,
        textEncoding: localManifest.textEncoding,
        minChunkBytes: localManifest.minChunkBytes,
        averageChunkBytes: localManifest.averageChunkBytes,
        maxChunkBytes: localManifest.maxChunkBytes,
        chunks: [
          TxtChunkReference(
            sha256: List.filled(64, '0').join(),
            offset: originalChunk.offset,
            length: originalChunk.length,
          ),
        ],
      );
      final current = dav.paths.singleWhere(
        (path) => path.endsWith('/current.json'),
      );
      dav.externalWrite(current, altered.encode());

      expect((await sync.reconcile()).failed, 1);
      expect((await sync.reconcile()).failed, 1);
      expect(
        await database.query(
          'mutable_txt_jobs',
          where: 'book_uid = ?',
          whereArgs: ['bad-same-hash'],
        ),
        hasLength(1),
      );
      expect(
        (await sync.listStates()).single.baseHash,
        isNot(localManifest.contentSha256),
      );
    },
  );

  test(
    'v3 upgrade waits for an active v2 publish and retains the old copy',
    () async {
      final book = await createBook('迁移中的书', '迁移基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'migrating-book');
      dav.blockNextCurrentWrite = Completer<void>();

      final publishing = sync.reconcile();
      await dav.currentWriteStarted.future;
      final upgrading = sync.enableIncremental('migrating-book');
      var upgraded = false;
      upgrading.then((_) => upgraded = true);
      await Future<void>.delayed(Duration.zero);
      expect(upgraded, isFalse);

      dav.blockNextCurrentWrite!.complete();
      await publishing;
      await upgrading;
      expect(
        (await sync.listStates()).single.mode,
        MutableTxtSyncMode.chunkedV3,
      );
      expect(
        dav.paths.where((path) => path.endsWith('/current.txt')),
        hasLength(1),
      );

      await sync.reconcile();
      expect(
        dav.paths.where((path) => path.endsWith('/current.json')),
        hasLength(1),
      );
      expect(
        dav.paths.where((path) => path.endsWith('/current.txt')),
        hasLength(1),
      );
    },
  );

  test('an existing v2 device follows a synced v3 descriptor', () async {
    const oldText = '共同旧版';
    const newText = '设备A在v3发布的新正文';
    final book = await createBook('跨设备升级', oldText);
    final a = service(Directory('${root.path}/state-a'));
    await a.join(book, bookUid: 'cross-device-upgrade');
    await a.reconcile();
    final oldHash = sha256.convert(utf8.encode(oldText)).toString();
    final v2Path = dav.paths.singleWhere(
      (path) => path.endsWith('/current.txt'),
    );

    await a.enableIncremental('cross-device-upgrade');
    await a.reconcile();
    await File(book.filePath).writeAsString(newText);
    await a.enqueueLocalUpdate(book, bookUid: 'cross-device-upgrade');
    await a.reconcile();
    final remoteState = (await a.listStates()).single;

    await File(book.filePath).writeAsString(oldText);
    await database.delete('mutable_txt_jobs');
    await database.update(
      'mutable_txt_bindings',
      {
        'protocol_mode': MutableTxtSyncMode.plainV2.name,
        'remote_path':
            'v2:books/${_encodedUid('cross-device-upgrade')}/current.txt',
        'local_hash': oldHash,
        'base_hash': oldHash,
        'remote_etag': dav.etag(v2Path),
        'status': MutableTxtSyncStatus.synced.name,
      },
      where: 'book_uid = ?',
      whereArgs: ['cross-device-upgrade'],
    );
    final b = service(Directory('${root.path}/state-b'));

    expect(
      await b.followRemoteStorage(
        bookUid: 'cross-device-upgrade',
        remotePath: remoteState.remotePath,
        contentHash: remoteState.localHash!,
        fileSize: utf8.encode(newText).length,
      ),
      isTrue,
    );
    final result = await b.reconcile();

    expect(result.downloaded, 1);
    expect(await File(book.filePath).readAsString(), newText);
    expect((await b.listStates()).single.mode, MutableTxtSyncMode.chunkedV3);
  });

  test(
    'v2 device local edits become a conflict when following changed v3',
    () async {
      const oldText = '共同旧版';
      final book = await createBook('跨设备升级冲突', oldText);
      final a = service(Directory('${root.path}/state-a'));
      await a.join(book, bookUid: 'upgrade-conflict');
      await a.reconcile();
      final oldHash = sha256.convert(utf8.encode(oldText)).toString();
      final v2Path = dav.paths.singleWhere(
        (path) => path.endsWith('/current.txt'),
      );
      await a.enableIncremental('upgrade-conflict');
      await a.reconcile();
      await File(book.filePath).writeAsString('设备A的新正文');
      await a.enqueueLocalUpdate(book, bookUid: 'upgrade-conflict');
      await a.reconcile();
      final remoteState = (await a.listStates()).single;

      await File(book.filePath).writeAsString(oldText);
      await database.delete('mutable_txt_jobs');
      await database.update(
        'mutable_txt_bindings',
        {
          'protocol_mode': MutableTxtSyncMode.plainV2.name,
          'remote_path':
              'v2:books/${_encodedUid('upgrade-conflict')}/current.txt',
          'local_hash': oldHash,
          'base_hash': oldHash,
          'remote_etag': dav.etag(v2Path),
          'status': MutableTxtSyncStatus.synced.name,
        },
        where: 'book_uid = ?',
        whereArgs: ['upgrade-conflict'],
      );
      final b = service(Directory('${root.path}/state-b'));
      await File(book.filePath).writeAsString('设备B的本地编辑');
      await b.enqueueLocalUpdate(book, bookUid: 'upgrade-conflict');

      await b.followRemoteStorage(
        bookUid: 'upgrade-conflict',
        remotePath: remoteState.remotePath,
        contentHash: remoteState.localHash!,
        fileSize: utf8.encode('设备A的新正文').length,
      );
      final result = await b.reconcile();

      expect(result.conflicts, 1);
      expect(await File(book.filePath).readAsString(), '设备B的本地编辑');
      expect(
        (await b.listStates()).single.status,
        MutableTxtSyncStatus.conflict,
      );
    },
  );

  test('v3 upgrade refuses unresolved remote state', () async {
    final book = await createBook('待处理迁移', '正文');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'blocked-upgrade');
    await database.update(
      'mutable_txt_bindings',
      {'status': MutableTxtSyncStatus.updateAvailable.name},
      where: 'book_uid = ?',
      whereArgs: ['blocked-upgrade'],
    );

    await expectLater(
      sync.enableIncremental('blocked-upgrade'),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.conflict,
        ),
      ),
    );
    expect((await sync.listStates()).single.mode, MutableTxtSyncMode.plainV2);
  });

  test(
    'a second device pulls a remote edit into the same local book',
    () async {
      final aBook = await createBook('设备A', '共同版本', id: 1);
      final a = service(Directory('${root.path}/state-a'));
      await a.join(aBook, bookUid: 'same-book');
      await a.reconcile();

      final bFile = File('${root.path}/设备B.txt');
      await bFile.writeAsString('共同版本');
      final bBook = Book(
        id: 2,
        title: '设备B',
        filePath: bFile.path,
        format: 'txt',
      );
      await database.insert('books', {
        'id': 2,
        'title': bBook.title,
        'author': bBook.author,
        'filePath': bBook.filePath,
        'format': bBook.format,
        'currentPage': 0,
        'totalPages': 1,
        'importDate': bBook.importDate.millisecondsSinceEpoch,
      });
      await database.update(
        'mutable_txt_bindings',
        {'local_book_id': 2, 'local_path': bFile.path},
        where: 'book_uid = ?',
        whereArgs: ['same-book'],
      );
      final b = service(Directory('${root.path}/state-b'));
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '设备A的新内容');
      final result = await b.reconcile();

      expect(result.downloaded, 1);
      expect(await bFile.readAsString(), '设备A的新内容');
      expect((await database.query('books', where: 'id = 2')).single['id'], 2);
    },
  );

  test(
    'remote UTF-8 revision replaces stale UTF-16 encoding metadata',
    () async {
      final file = File('${root.path}/编码变化.txt');
      await file.writeAsBytes(<int>[
        0xff,
        0xfe,
        for (final unit in '旧内容'.codeUnits) ...[unit & 0xff, unit >> 8],
      ]);
      final book = Book(
        id: 1,
        title: '编码变化',
        author: '作者',
        filePath: file.path,
        format: 'txt',
        textEncoding: 'utf16le',
      );
      await database.insert('books', book.toMap());
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'encoding-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '设备A编辑后保存为UTF-8');

      expect((await sync.reconcile()).downloaded, 1);

      expect(await file.readAsString(), '设备A编辑后保存为UTF-8');
      expect((await database.query('books')).single['text_encoding'], 'utf8');
    },
  );

  test('valid GBK TXT can establish its initial mutable baseline', () async {
    final file = File('${root.path}/GBK原书.txt');
    final bytes = gbk_bytes.encode('中文GBK原文');
    await file.writeAsBytes(bytes);
    final book = Book(
      id: 1,
      title: 'GBK原书',
      filePath: file.path,
      format: 'txt',
      textEncoding: 'gbk',
    );
    await database.insert('books', book.toMap());
    final sync = service(Directory('${root.path}/state'));

    await sync.join(book, bookUid: 'gbk-book');
    expect((await sync.reconcile()).uploaded, 1);

    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    expect(dav.files[currentPath], bytes);
    expect(
      (await sync.listStates()).single.status,
      MutableTxtSyncStatus.synced,
    );

    final remoteBytes = gbk_bytes.encode('另一台设备保存的GBK新版');
    final remoteHash = sha256.convert(remoteBytes).toString();
    final segment = base64Url
        .encode(utf8.encode('gbk-book'))
        .replaceAll('=', '');
    dav.files['/OpenReading/v2/revisions/$segment/$remoteHash.txt'] =
        remoteBytes;
    dav.files['/OpenReading/v2/revisions/$segment/$remoteHash.json'] = utf8
        .encode(
          jsonEncode({
            'version': 1,
            'sha256': remoteHash,
            'textEncoding': 'gbk',
          }),
        );
    dav.files[currentPath] = remoteBytes;
    dav.versions[currentPath] = (dav.versions[currentPath] ?? 0) + 1;

    expect((await sync.reconcile()).downloaded, 1);
    expect(await file.readAsBytes(), remoteBytes);
    expect((await database.query('books')).single['text_encoding'], 'gbk');
  });

  test(
    'no-BOM UTF-16 revision metadata supports byte-preserving sync',
    () async {
      List<int> utf16le(String value) => [
        for (final unit in value.codeUnits) ...[unit & 0xff, unit >> 8],
      ];

      final file = File('${root.path}/UTF16无BOM.txt');
      await file.writeAsBytes(utf16le('无BOM旧版'));
      final book = Book(
        id: 1,
        title: 'UTF16无BOM',
        filePath: file.path,
        format: 'txt',
        textEncoding: 'utf16le',
      );
      await database.insert('books', book.toMap());
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'utf16-book');
      expect((await sync.reconcile()).uploaded, 1);
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      final remoteBytes = utf16le('无BOM远端新版');
      final remoteHash = sha256.convert(remoteBytes).toString();
      final segment = base64Url
          .encode(utf8.encode('utf16-book'))
          .replaceAll('=', '');
      dav.files['/OpenReading/v2/revisions/$segment/$remoteHash.txt'] =
          remoteBytes;
      dav.files['/OpenReading/v2/revisions/$segment/$remoteHash.json'] = utf8
          .encode(
            jsonEncode({
              'version': 1,
              'sha256': remoteHash,
              'textEncoding': 'utf16le',
            }),
          );
      dav.files[currentPath] = remoteBytes;
      dav.versions[currentPath] = (dav.versions[currentPath] ?? 0) + 1;

      expect((await sync.reconcile()).downloaded, 1);
      expect(await file.readAsBytes(), remoteBytes);
      expect(
        (await database.query('books')).single['text_encoding'],
        'utf16le',
      );
    },
  );

  test(
    'invalid non-UTF byte stream is rejected without replacing local TXT',
    () async {
      final book = await createBook('非法编码', '本机正文');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'invalid-encoding-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.files[currentPath] = <int>[0x81, 0x30, 0xff];
      dav.versions[currentPath] = (dav.versions[currentPath] ?? 0) + 1;

      final result = await sync.reconcile();

      expect(result.failed, 1);
      expect(await File(book.filePath).readAsString(), '本机正文');
    },
  );

  test(
    'UTF-8 detection validates the full file across sample boundaries',
    () async {
      final book = await createBook('编码边界', '基线');
      await database.update(
        'books',
        {'text_encoding': 'utf16le'},
        where: 'id = ?',
        whereArgs: [book.id],
      );
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'encoding-boundary-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      final remoteText = '${List.filled(256 * 1024 + 3, 'a').join()}你tail';
      dav.externalWrite(currentPath, remoteText);

      expect((await sync.reconcile()).downloaded, 1);

      expect(await File(book.filePath).readAsString(), remoteText);
      expect((await database.query('books')).single['text_encoding'], 'utf8');
    },
  );

  test(
    'concurrent edits preserve both files as a resolvable conflict',
    () async {
      final book = await createBook('冲突书', '基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'conflict-book');
      await sync.reconcile();

      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      await File(book.filePath).writeAsString('本机修改');
      await sync.enqueueLocalUpdate(book, bookUid: 'conflict-book');
      dav.externalWrite(currentPath, '另一台设备修改');

      final result = await sync.reconcile();
      expect(result.conflicts, 1);
      expect(await File(book.filePath).readAsString(), '本机修改');
      expect(dav.text(currentPath), '另一台设备修改');
      final conflict = (await sync.listConflicts()).single;
      expect(await File(conflict.localSnapshotPath).readAsString(), '本机修改');
      expect(await File(conflict.remoteSnapshotPath).readAsString(), '另一台设备修改');

      await sync.resolveConflict(
        conflict.id,
        MutableTxtConflictChoice.useRemote,
      );
      expect(await File(book.filePath).readAsString(), '另一台设备修改');
      expect((await sync.listConflicts()), isEmpty);
    },
  );

  test('queued snapshot survives service recreation and is uploaded', () async {
    final book = await createBook('离线书', '初始');
    final stateRoot = Directory('${root.path}/state');
    final first = service(stateRoot);
    await first.join(book, bookUid: 'offline-book');
    await first.reconcile();
    await File(book.filePath).writeAsString('离线保存');
    await first.enqueueLocalUpdate(book, bookUid: 'offline-book');

    final restarted = service(stateRoot);
    final result = await restarted.reconcile();

    expect(result.uploaded, 1);
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    expect(dav.text(currentPath), '离线保存');
  });

  test('startup rolls back an interrupted remote file replacement', () async {
    final book = await createBook('崩溃恢复', '已确认本地版本');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'journal-book');
    await sync.reconcile();
    final target = File(book.filePath);
    final backup = File('${book.filePath}.interrupted.backup');
    final originalHash = sha256.convert(utf8.encode('已确认本地版本')).toString();
    await database.update(
      'books',
      {
        'content_hash': originalHash,
        'cached_content': '旧缓存',
        'last_canonical_locator': '{"offset":2}',
        'last_rendered_locator': '{"page":1}',
        'layout_signature': 'layout-old',
      },
      where: 'id = ?',
      whereArgs: [book.id],
    );
    await database.insert('book_notes', {
      'id': 1,
      'book_id': book.id,
      'content': '原摘录',
      'canonical_locator': '{"offset":2}',
      'start_offset': 2,
      'end_offset': 5,
    });
    await database.insert('bookmarks', {
      'id': 1,
      'bookId': book.id,
      'canonical_locator': '{"offset":2}',
      'anchor_key': 'txt-0:2',
      'excerpt': '原书签',
    });
    await target.rename(backup.path);
    await target.writeAsString('尚未提交的远端版本');
    await database.insert('mutable_txt_apply_journal', {
      'book_uid': 'journal-book',
      'target_path': target.path,
      'backup_path': backup.path,
      'incoming_path': '${book.filePath}.missing.part',
      'remote_hash': 'uncommitted-remote-hash',
      'original_hash': originalHash,
      'remote_etag': '"remote"',
      'phase': 'replaced',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    final recoveryOnly = MutableTxtSyncService(
      configStore: _UnreadableConfigStore(),
      clientFactory: (_) => throw StateError('network must stay unused'),
      database: () async => database,
      stateDirectory: () async => Directory('${root.path}/state'),
    );
    await recoveryOnly.recoverLocalState();

    expect(await target.readAsString(), '已确认本地版本');
    expect(await backup.exists(), isFalse);
    expect(await database.query('mutable_txt_apply_journal'), isEmpty);
    final restoredBook = (await database.query('books')).single;
    expect(restoredBook['content_hash'], originalHash);
    expect(restoredBook['cached_content'], isNull);
    expect(restoredBook['last_canonical_locator'], '{"offset":2}');
    expect(restoredBook['last_rendered_locator'], '{"page":1}');
    expect(restoredBook['layout_signature'], 'layout-old');
    final note = (await database.query('book_notes')).single;
    expect(note['canonical_locator'], '{"offset":2}');
    expect(note['start_offset'], 2);
    final bookmark = (await database.query('bookmarks')).single;
    expect(bookmark['anchor_key'], 'txt-0:2');
  });

  test('startup refuses a rollback copy with the wrong checksum', () async {
    final book = await createBook('损坏回滚', '原文件');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'corrupt-rollback-book');
    await sync.reconcile();
    final target = File(book.filePath);
    final backup = File('${book.filePath}.corrupt.backup');
    await backup.writeAsString('损坏的备份');
    await target.writeAsString('尚未提交的远端版本');
    await database.insert('mutable_txt_apply_journal', {
      'book_uid': 'corrupt-rollback-book',
      'target_path': target.path,
      'backup_path': backup.path,
      'incoming_path': '${book.filePath}.missing.part',
      'remote_hash': 'uncommitted-remote-hash',
      'original_hash': sha256.convert(utf8.encode('原文件')).toString(),
      'remote_etag': '"remote"',
      'phase': 'replaced',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    await expectLater(
      sync.recoverLocalState(),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (failure) => failure.code,
          'code',
          WebDavSyncErrorCode.localDataCorrupt,
        ),
      ),
    );

    expect(await target.readAsString(), '尚未提交的远端版本');
    expect(await backup.readAsString(), '损坏的备份');
    expect(await database.query('mutable_txt_apply_journal'), hasLength(1));
  });

  test(
    'startup finishes cleanup after a committed remote replacement',
    () async {
      final book = await createBook('提交后清理', '旧版本');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'committed-journal-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '已提交远端版本');
      final cleanupFailing = MutableTxtSyncService(
        configStore: config,
        clientFactory: (_) => _FakeDavClient(dav),
        database: () async => database,
        stateDirectory: () async => Directory('${root.path}/state'),
        committedBackupCleanup: (_) async => throw FileSystemException('busy'),
      );

      expect((await cleanupFailing.reconcile()).downloaded, 1);
      expect(await File(book.filePath).readAsString(), '已提交远端版本');
      expect(await database.query('mutable_txt_apply_journal'), hasLength(1));

      await sync.reconcile(allowNetwork: false);

      expect(await File(book.filePath).readAsString(), '已提交远端版本');
      expect(await database.query('mutable_txt_apply_journal'), isEmpty);
      expect(
        (await database.query(
          'books',
          where: 'id = ?',
          whereArgs: [book.id],
        )).single['content_hash'],
        sha256.convert(utf8.encode('已提交远端版本')).toString(),
      );
    },
  );

  test('binding database failure rolls back file and book metadata', () async {
    final book = await createBook('事务回滚', '本机基线');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'transaction-book');
    await sync.reconcile();
    final baselineRow = (await database.query(
      'books',
      where: 'id = ?',
      whereArgs: [book.id],
    )).single;
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    dav.externalWrite(currentPath, '远端新版');
    await database.execute('''
      CREATE TRIGGER fail_binding_commit
      BEFORE UPDATE OF base_hash ON mutable_txt_bindings
      BEGIN
        SELECT RAISE(ABORT, 'injected binding failure');
      END
    ''');

    final result = await sync.reconcile();

    expect(result.failed, 1);
    expect(await File(book.filePath).readAsString(), '本机基线');
    final after = (await database.query(
      'books',
      where: 'id = ?',
      whereArgs: [book.id],
    )).single;
    expect(after['content_hash'], baselineRow['content_hash']);
    expect(await database.query('mutable_txt_apply_journal'), hasLength(1));
    await database.execute('DROP TRIGGER fail_binding_commit');

    await sync.reconcile(allowNetwork: false);
    expect(await database.query('mutable_txt_apply_journal'), isEmpty);
  });

  test(
    'remote whole-file revision conservatively invalidates references',
    () async {
      final book = await createBook('引用失效', '旧正文');
      await database.update(
        'books',
        {
          'last_canonical_locator': '{"old":true}',
          'last_rendered_locator': '{"page":3}',
          'layout_signature': 'old-layout',
          'text_encoding': 'utf-8',
        },
        where: 'id = ?',
        whereArgs: [book.id],
      );
      await database.insert('book_notes', {
        'id': 1,
        'book_id': book.id,
        'content': '保留的摘录',
        'canonical_locator': '{"old":true}',
        'payload_json': jsonEncode({'kept': true}),
        'start_offset': 2,
        'end_offset': 7,
      });
      await database.insert('bookmarks', {
        'id': 1,
        'bookId': book.id,
        'canonical_locator': '{"old":true}',
        'anchor_key': 'txt-0:2',
        'excerpt': '保留的书签摘录',
      });
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'references-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '完全不同的远端正文');

      expect((await sync.reconcile()).downloaded, 1);

      final bookRow = (await database.query('books')).single;
      expect(bookRow['last_canonical_locator'], isNull);
      expect(bookRow['last_rendered_locator'], isNull);
      expect(bookRow['layout_signature'], isNull);
      final note = (await database.query('book_notes')).single;
      expect(note['content'], '保留的摘录');
      expect(note['canonical_locator'], isNull);
      expect(note['start_offset'], isNull);
      expect(note['payload_json'], contains('unresolved'));
      final bookmark = (await database.query('bookmarks')).single;
      expect(bookmark['excerpt'], '保留的书签摘录');
      expect(bookmark['canonical_locator'], isNull);
      expect(bookmark['anchor_key'], startsWith('openreading:txt-unresolved:'));
    },
  );

  test(
    'stale conditional write becomes a conflict instead of overwriting',
    () async {
      final book = await createBook('竞争书', '基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'race-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      await File(book.filePath).writeAsString('本机新版');
      await sync.enqueueLocalUpdate(book, bookUid: 'race-book');
      dav.mutateBeforeNextCurrentWrite = '并发远端新版';

      final result = await sync.reconcile();

      expect(result.conflicts, 1);
      expect(dav.text(currentPath), '并发远端新版');
      expect(await File(book.filePath).readAsString(), '本机新版');
    },
  );

  test(
    'active reader stages a remote update until explicitly applied',
    () async {
      final book = await createBook('阅读中', '基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'active-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '远端更新');
      ReadingProgressSyncService.instance.beginOpening(book);

      await sync.reconcile();
      expect(await File(book.filePath).readAsString(), '基线');
      expect(
        (await sync.listStates()).single.status,
        MutableTxtSyncStatus.updateAvailable,
      );
      expect(await sync.applyAvailableUpdate('active-book'), isFalse);

      ReadingProgressSyncService.instance.cancelOpening(book.id!);
      expect(await sync.applyAvailableUpdate('active-book'), isTrue);
      expect(await File(book.filePath).readAsString(), '远端更新');
    },
  );

  test('editing during conflict updates the kept-local revision', () async {
    final book = await createBook('手工合并', '基线');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'merge-book');
    await sync.reconcile();
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    await File(book.filePath).writeAsString('本机冲突版本');
    await sync.enqueueLocalUpdate(book, bookUid: 'merge-book');
    dav.externalWrite(currentPath, '远端冲突版本');
    await sync.reconcile();

    await File(book.filePath).writeAsString('用户手工合并后的内容');
    await sync.enqueueLocalUpdate(book, bookUid: 'merge-book');
    final conflict = (await sync.listConflicts()).single;
    expect(await File(conflict.localSnapshotPath).readAsString(), '用户手工合并后的内容');
    await sync.resolveConflict(conflict.id, MutableTxtConflictChoice.keepLocal);
    await sync.reconcile();

    expect(dav.text(currentPath), '用户手工合并后的内容');
  });

  test('pausing a book preserves its queued local edit', () async {
    final book = await createBook('暂停书', '基线');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'paused-book');
    await sync.reconcile();
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    await sync.setEnabled('paused-book', false);
    await File(book.filePath).writeAsString('暂停期间修改');
    await sync.enqueueLocalUpdate(book, bookUid: 'paused-book');

    await sync.reconcile();
    expect(dav.text(currentPath), '基线');
    expect(
      (await sync.listStates()).single.status,
      MutableTxtSyncStatus.paused,
    );

    await sync.setEnabled('paused-book', true);
    await sync.reconcile();
    expect(dav.text(currentPath), '暂停期间修改');
  });

  test(
    'a server without strong ETags never overwrites local content',
    () async {
      final book = await createBook('弱标签', '本机');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'weak-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      dav.externalWrite(currentPath, '远端');
      dav.weakEtags = true;
      await File(book.filePath).writeAsString('本机新版');
      await sync.enqueueLocalUpdate(book, bookUid: 'weak-book');

      final result = await sync.reconcile();

      expect(result.failed, 1);
      expect(dav.text(currentPath), '远端');
      expect(await File(book.filePath).readAsString(), '本机新版');
    },
  );

  test('pending work is never written after switching WebDAV spaces', () async {
    final book = await createBook('空间隔离', '基线');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'space-book');
    await sync.reconcile();
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    await File(book.filePath).writeAsString('旧空间待上传');
    await sync.enqueueLocalUpdate(book, bookUid: 'space-book');
    config.credentials = const StoredSyncCredentials(
      WebDavSyncConfiguration(
        serverUrl: 'https://other.example.com',
        username: 'reader',
      ),
      'secret',
    );

    final result = await sync.reconcile();

    expect(result.uploaded, 0);
    expect(dav.text(currentPath), '基线');
    expect(await sync.listStates(), isEmpty);

    await sync.join(book, bookUid: 'space-book');
    expect(
      (await sync.listStates()).single.status,
      MutableTxtSyncStatus.pending,
    );
    expect(await database.query('mutable_txt_archived_bindings'), hasLength(1));
    await database.update(
      'mutable_txt_archived_bindings',
      {'job_json': null},
      where: 'book_uid = ?',
      whereArgs: ['space-book'],
    );

    config.credentials = _credentials;
    await sync.join(book, bookUid: 'space-book');
    expect(
      (await sync.listStates()).single.status,
      MutableTxtSyncStatus.pending,
    );
    expect(
      await database.query(
        'mutable_txt_jobs',
        where: 'book_uid = ?',
        whereArgs: ['space-book'],
      ),
      hasLength(1),
    );
    await sync.reconcile();
    expect(dav.text(currentPath), '旧空间待上传');
  });

  test(
    'conflicts from another WebDAV space are hidden and immutable',
    () async {
      final book = await createBook('旧空间冲突', '基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'space-conflict-book');
      await sync.reconcile();
      final currentPath = dav.paths.singleWhere(
        (key) => key.endsWith('/current.txt'),
      );
      await File(book.filePath).writeAsString('本机冲突');
      await sync.enqueueLocalUpdate(book, bookUid: 'space-conflict-book');
      dav.externalWrite(currentPath, '远端冲突');
      await sync.reconcile();
      final oldConflict = (await sync.listConflicts()).single;
      config.credentials = const StoredSyncCredentials(
        WebDavSyncConfiguration(
          serverUrl: 'https://other.example.com',
          username: 'reader',
        ),
        'secret',
      );

      expect(await sync.listConflicts(), isEmpty);
      await expectLater(
        sync.resolveConflict(
          oldConflict.id,
          MutableTxtConflictChoice.keepLocal,
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (failure) => failure.code,
            'code',
            WebDavSyncErrorCode.notFound,
          ),
        ),
      );
    },
  );

  test(
    'space activation rolls back archive and job deletion atomically',
    () async {
      final book = await createBook('空间事务', '基线');
      final sync = service(Directory('${root.path}/state'));
      await sync.join(book, bookUid: 'atomic-space-book');
      await sync.reconcile();
      await File(book.filePath).writeAsString('待上传修改');
      await sync.enqueueLocalUpdate(book, bookUid: 'atomic-space-book');
      final oldSpace = (await database.query(
        'mutable_txt_bindings',
      )).single['space_key'];
      config.credentials = const StoredSyncCredentials(
        WebDavSyncConfiguration(
          serverUrl: 'https://other.example.com',
          username: 'reader',
        ),
        'secret',
      );
      await database.execute('''
      CREATE TRIGGER fail_space_switch
      BEFORE DELETE ON mutable_txt_bindings
      BEGIN
        SELECT RAISE(ABORT, 'injected space switch failure');
      END
    ''');

      await expectLater(
        sync.join(book, bookUid: 'atomic-space-book'),
        throwsA(isA<DatabaseException>()),
      );

      expect(
        (await database.query('mutable_txt_bindings')).single['space_key'],
        oldSpace,
      );
      expect(await database.query('mutable_txt_jobs'), hasLength(1));
      expect(await database.query('mutable_txt_archived_bindings'), isEmpty);
    },
  );

  test('editing a conflict only updates the active WebDAV space', () async {
    final book = await createBook('跨空间冲突', '基线');
    final sync = service(Directory('${root.path}/state'));
    await sync.join(book, bookUid: 'cross-space-conflict');
    await sync.reconcile();
    final currentPath = dav.paths.singleWhere(
      (key) => key.endsWith('/current.txt'),
    );
    await File(book.filePath).writeAsString('旧空间本机冲突');
    await sync.enqueueLocalUpdate(book, bookUid: 'cross-space-conflict');
    dav.externalWrite(currentPath, '旧空间远端冲突');
    await sync.reconcile();
    final oldConflict = (await database.query('mutable_txt_conflicts')).single;
    config.credentials = const StoredSyncCredentials(
      WebDavSyncConfiguration(
        serverUrl: 'https://other.example.com',
        username: 'reader',
      ),
      'secret',
    );
    await sync.join(book, bookUid: 'cross-space-conflict');
    final active = (await database.query('mutable_txt_bindings')).single;
    final newConflictId = await database.insert('mutable_txt_conflicts', {
      'book_uid': 'cross-space-conflict',
      'space_key': active['space_key'],
      'base_hash': active['base_hash'],
      'local_hash': active['local_hash'],
      'remote_hash': oldConflict['remote_hash'],
      'local_snapshot_path': oldConflict['local_snapshot_path'],
      'remote_snapshot_path': oldConflict['remote_snapshot_path'],
      'remote_etag': oldConflict['remote_etag'],
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await database.update(
      'mutable_txt_bindings',
      {'status': MutableTxtSyncStatus.conflict.name},
      where: 'book_uid = ?',
      whereArgs: ['cross-space-conflict'],
    );
    await File(book.filePath).writeAsString('新空间继续编辑');

    await sync.enqueueLocalUpdate(book, bookUid: 'cross-space-conflict');

    final rows = await database.query('mutable_txt_conflicts', orderBy: 'id');
    expect(rows.first['local_hash'], oldConflict['local_hash']);
    expect(rows.last['id'], newConflictId);
    expect(
      rows.last['local_hash'],
      sha256.convert(utf8.encode('新空间继续编辑')).toString(),
    );
  });
}

const _credentials = StoredSyncCredentials(
  WebDavSyncConfiguration(
    serverUrl: 'https://dav.example.com',
    username: 'reader',
  ),
  'secret',
);

String _encodedUid(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

class _TestConfigStore extends SecureSyncConfigStore {
  StoredSyncCredentials credentials = _credentials;

  @override
  Future<StoredSyncCredentials?> readCredentials() async => credentials;

  @override
  Future<WebDavSyncScope> readScope() async =>
      const WebDavSyncScope(bookFiles: true);
}

class _UnreadableConfigStore extends SecureSyncConfigStore {
  @override
  Future<StoredSyncCredentials?> readCredentials() =>
      throw StateError('configuration must stay unread');
}

class _FakeDavStore {
  final Map<String, List<int>> files = {};
  final Map<String, int> versions = {};
  String? mutateBeforeNextCurrentWrite;
  bool weakEtags = false;
  int chunkUploadBytes = 0;
  Completer<void>? blockNextCurrentWrite;
  Completer<void> currentWriteStarted = Completer<void>();

  Iterable<String> get paths => files.keys;
  String text(String key) => utf8.decode(files[key]!);

  String etag(String key) {
    final value = '"${versions[key] ?? 1}"';
    return weakEtags ? 'W/$value' : value;
  }

  void externalWrite(String key, String value) {
    files[key] = utf8.encode(value);
    versions[key] = (versions[key] ?? 0) + 1;
  }
}

class _FakeDavClient extends WebDavClient {
  _FakeDavClient(this.store) : super(dio: Dio(), credentials: _credentials);

  final _FakeDavStore store;

  String _key(Uri uri) => uri.path;

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
    final key = _key(uri);
    final bytes = store.files[key];
    if (bytes == null) return const WebDavResourceState.missing();
    return WebDavResourceState(
      exists: true,
      etag: store.etag(key),
      contentLength: bytes.length,
    );
  }

  @override
  Future<String?> getText(Uri uri, {bool allowNotFound = false}) async {
    final bytes = store.files[_key(uri)];
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
    final key = _key(uri);
    if ((key.endsWith('/current.txt') || key.endsWith('/current.json')) &&
        store.blockNextCurrentWrite != null) {
      if (!store.currentWriteStarted.isCompleted) {
        store.currentWriteStarted.complete();
      }
      final blocker = store.blockNextCurrentWrite!;
      await blocker.future;
      if (identical(store.blockNextCurrentWrite, blocker)) {
        store.blockNextCurrentWrite = null;
      }
    }
    final mutation = store.mutateBeforeNextCurrentWrite;
    if (key.endsWith('/current.txt') && mutation != null) {
      store.mutateBeforeNextCurrentWrite = null;
      store.externalWrite(key, mutation);
    }
    final exists = store.files.containsKey(key);
    if ((ifNoneMatch && exists) ||
        (ifMatch != null && (!exists || ifMatch != store.etag(key)))) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'precondition failed',
        statusCode: 412,
      );
    }
    final bytes = await file.readAsBytes();
    store.files[key] = bytes;
    store.versions[key] = (store.versions[key] ?? 0) + 1;
    if (key.endsWith('.chunk')) store.chunkUploadBytes += bytes.length;
    onProgress?.call(bytes.length, bytes.length);
    return WebDavConditionalWriteResult(
      etag: store.etag(key),
      contentLength: bytes.length,
    );
  }

  @override
  Future<void> downloadFile(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    final bytes = store.files[_key(uri)];
    if (bytes == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'missing',
        statusCode: 404,
      );
    }
    await target.writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}
