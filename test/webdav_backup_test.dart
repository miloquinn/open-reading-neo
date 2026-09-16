import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/book_sources/services/book_source_registry_storage.dart';
import 'package:xxread/services/backup/backup_archive.dart';
import 'package:xxread/services/backup/backup_selection.dart';
import 'package:xxread/services/backup/webdav_backup_controller.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'support/local_webdav_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = previousOverrides);
  late Directory documents;
  late Database db;
  late BackupArchive archive;
  late SharedPreferences prefs;
  late _Sources sources;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('PRAGMA foreign_keys = ON');
    await db.setVersion(25);
    await db.execute(
      'CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT NOT NULL, filePath TEXT NOT NULL, currentPage INTEGER, reading_progress REAL, last_canonical_locator TEXT, cover_image_path TEXT, storage_type TEXT)',
    );
    await db.execute(
      'CREATE TABLE book_notes(id INTEGER PRIMARY KEY, book_id INTEGER REFERENCES books(id), content TEXT, payload_json TEXT)',
    );
    await db.execute(
      'CREATE TABLE bookmarks(id INTEGER PRIMARY KEY, bookId INTEGER REFERENCES books(id), pageNumber INTEGER)',
    );
    await db.execute(
      'CREATE TABLE reading_stats(id INTEGER PRIMARY KEY, durationInSeconds INTEGER)',
    );
    await db.execute(
      'CREATE TABLE reading_sessions(id INTEGER PRIMARY KEY, bookId INTEGER, durationInSeconds INTEGER)',
    );
    documents = await Directory.systemTemp.createTemp('backup-test-');
    await Directory('${documents.path}/books').create();
    await File('${documents.path}/books/book.txt').writeAsString('原始正文\n第二章');
    await File(
      '${documents.path}/books/book.txt.openreading-source.json',
    ).writeAsString('{"chapters":[]}');
    await db.insert('books', {
      'id': 1,
      'title': '书',
      'filePath': 'books/book.txt',
      'currentPage': 4,
      'reading_progress': 0.4,
      'last_canonical_locator': 'chapter-4',
    });
    await db.insert('book_notes', {
      'id': 1,
      'book_id': 1,
      'content': '笔记',
      'payload_json': '{"strokes":[1,2]}',
    });
    await db.insert('bookmarks', {'id': 1, 'bookId': 1, 'pageNumber': 4});
    await db.insert('reading_stats', {'id': 1, 'durationInSeconds': 123});
    await db.insert('reading_sessions', {
      'id': 1,
      'bookId': 1,
      'durationInSeconds': 123,
    });
    await db.execute(
      'CREATE TABLE sync_local_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.insert('sync_local_state', {
      'key': 'frozen_book_uid:1',
      'value': 'original-stable-identity',
    });
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 22.0,
      'reader_replace_rules_v1': '[]',
      'account_token': 'local-only',
      'webdav_sync_configuration_v1': 'local-only',
      'reader_aloud_cloud_profiles_v1': 'local-only',
    });
    prefs = await SharedPreferences.getInstance();
    sources = _Sources();
    archive = BackupArchive(
      database: db,
      documents: documents,
      preferences: prefs,
      sources: sources,
    );
  });
  tearDown(() async {
    await db.close();
    await documents.delete(recursive: true);
  });

  Future<File> snapshot() async {
    final file = File('${documents.path}/snapshot.zip');
    await archive.create(file);
    return file;
  }

  test('fast packing streams progress and omits database caches', () async {
    await db.execute('ALTER TABLE books ADD COLUMN cached_content TEXT');
    await db.update('books', {'cached_content': 'x' * (1024 * 1024)});
    await File(
      '${documents.path}/books/book.txt',
    ).writeAsString('a' * (8 * 1024 * 1024));
    final zip = File('${documents.path}/fast.zip');
    final updates = <int>[];
    final watch = Stopwatch()..start();
    await archive.create(
      zip,
      selection: const BackupSelection(bookIds: {1}),
      onProgress: (done, total) => updates.add(done),
    );
    watch.stop();
    // Intermediate updates occur before the complete book has been packed.
    expect(updates.any((v) => v > 0 && v < updates.last), isTrue);
    final checked = await archive.validate(zip);
    expect(
      (checked.data['tables']['books'] as List).single['cached_content'],
      isNull,
    );
    expect(
      await File('${checked.directory.path}/books/1.txt').length(),
      8 * 1024 * 1024,
    );
    // Diagnostic only: never turn host speed into a flaky correctness assertion.
    debugPrint('8 MiB fast ZIP: ${watch.elapsedMilliseconds} ms');
    await checked.directory.delete(recursive: true);
  });

  test(
    'restore choices preserve existing data unless overwrite is enabled',
    () async {
      final zip = File('${documents.path}/restore-options.zip');
      await archive.create(zip, selection: const BackupSelection(bookIds: {1}));
      await db.update('books', {'currentPage': 88});
      await prefs.setDouble('reader_font_size', 44);
      await db.update('book_notes', {'content': 'keep current'});
      final first = await archive.validate(zip);
      await archive.restore(first, selection: const RestoreSelection());
      expect((await db.query('books')).single['currentPage'], 88);
      expect((await db.query('book_notes')).single['content'], 'keep current');
      expect(prefs.getDouble('reader_font_size'), 44);
      await first.directory.delete(recursive: true);
      final second = await archive.validate(zip);
      await archive.restore(
        second,
        selection: const RestoreSelection(
          reading: false,
          statistics: false,
          sources: false,
          settings: true,
          overwrite: true,
        ),
      );
      expect(prefs.getDouble('reader_font_size'), 22);
      expect((await db.query('books')).single['currentPage'], 88);
      await second.directory.delete(recursive: true);
      final third = await archive.validate(zip);
      await archive.restore(
        third,
        selection: const RestoreSelection(
          files: false,
          statistics: false,
          sources: false,
          settings: false,
          overwrite: true,
        ),
      );
      expect((await db.query('books')).single['currentPage'], 4);
      expect((await db.query('books')).single['filePath'], 'books/book.txt');
      await third.directory.delete(recursive: true);
    },
  );

  test(
    'selection excludes large unselected files and preserves omitted categories',
    () async {
      final huge = File('${documents.path}/books/huge.bin');
      final handle = await huge.open(mode: FileMode.write);
      await handle.truncate(3 * 1024 * 1024 * 1024);
      await handle.close();
      await db.insert('books', {
        'id': 2,
        'title': 'Large',
        'filePath': 'books/huge.bin',
        'currentPage': 7,
      });
      final inventory = await archive.inventory();
      expect(
        inventory.singleWhere((b) => b.id == 2).bytes,
        3 * 1024 * 1024 * 1024,
      );
      final zip = File('${documents.path}/selected.zip');
      final packed = <int>[];
      await archive.create(
        zip,
        selection: const BackupSelection(
          bookIds: {1},
          sources: false,
          settings: false,
          statistics: false,
        ),
        onProgress: (done, total) {
          packed.add(done);
        },
      );
      expect(await zip.length(), lessThan(100000));
      expect(packed, isNotEmpty);
      final checked = await archive.validate(zip);
      expect((checked.data['files'] as Map).keys, contains('books/1.txt'));
      expect(
        (checked.data['files'] as Map).keys.any(
          (k) => k.toString().contains('2.bin'),
        ),
        isFalse,
      );
      await db.update('books', {'currentPage': 99}, where: 'id = 1');
      await db.insert('books', {
        'id': 3,
        'title': 'Unrelated',
        'filePath': 'books/other.txt',
      });
      await prefs.setDouble('reader_font_size', 33);
      sources.raw = '{"version":2,"sources":[],"groups":["keep"]}';
      await db.update('reading_stats', {'durationInSeconds': 999});
      await archive.restore(checked);
      expect(
        (await db.query('books', where: 'id = 1')).single['currentPage'],
        4,
      );
      expect(
        (await db.query('books', where: 'id = 2')).single['filePath'],
        'books/huge.bin',
      );
      expect(
        (await db.query('books', where: 'id = 3')).single['title'],
        'Unrelated',
      );
      expect(prefs.getDouble('reader_font_size'), 33);
      expect(sources.raw, contains('keep'));
      expect(
        (await db.query('reading_stats')).single['durationInSeconds'],
        999,
      );
      await checked.directory.delete(recursive: true);
    },
  );

  test(
    'metadata-only default excludes files and tolerates unavailable originals',
    () async {
      await File('${documents.path}/books/book.txt').delete();
      final zip = File('${documents.path}/metadata.zip');
      await archive.create(zip, selection: const BackupSelection());
      final checked = await archive.validate(zip);
      expect(checked.data['files'], isEmpty);
      await db.update('books', {'currentPage': 88});
      await archive.restore(checked);
      expect((await db.query('books')).single['currentPage'], 4);
      expect((await db.query('books')).single['filePath'], 'books/book.txt');
      await checked.directory.delete(recursive: true);
    },
  );

  test(
    'selected restore remaps colliding book and note IDs on another library',
    () async {
      final zip = File('${documents.path}/portable.zip');
      await archive.create(
        zip,
        selection: const BackupSelection(bookIds: {1}, statistics: false),
      );
      final checked = await archive.validate(zip);
      await db.delete('book_notes');
      await db.delete('bookmarks');
      await db.delete('books');
      await db.delete('sync_local_state');
      await db.insert('books', {
        'id': 1,
        'title': 'Other',
        'filePath': 'books/other.txt',
      });
      await db.insert('book_notes', {'id': 1, 'book_id': 1, 'content': 'Keep'});
      await archive.restore(checked);
      final restored = (await db.query('books', where: 'id != 1')).single;
      expect(
        (await db.query('books', where: 'id = 1')).single['title'],
        'Other',
      );
      expect(
        (await db.query('book_notes', where: 'book_id = 1')).single['content'],
        'Keep',
      );
      expect(
        (await db.query(
          'book_notes',
          where: 'book_id = ?',
          whereArgs: [restored['id']],
        )).single['payload_json'],
        '{"strokes":[1,2]}',
      );
      // Repeating the same snapshot updates the same book rather than duplicating it.
      final again = await archive.validate(zip);
      await archive.restore(again);
      expect(await db.query('books'), hasLength(2));
      await checked.directory.delete(recursive: true);
      await again.directory.delete(recursive: true);
    },
  );

  test(
    'settings-only restore leaves the entire library and sources unchanged',
    () async {
      final zip = File('${documents.path}/settings.zip');
      await archive.create(
        zip,
        selection: const BackupSelection(
          reading: false,
          statistics: false,
          sources: false,
        ),
      );
      final checked = await archive.validate(zip);
      expect((checked.data['tables'] as Map)['books'], isEmpty);
      await db.update('books', {'currentPage': 77});
      await prefs.setDouble('reader_font_size', 44);
      await archive.restore(checked);
      expect((await db.query('books')).single['currentPage'], 77);
      expect(prefs.getDouble('reader_font_size'), 22);
      expect(await db.query('book_notes'), hasLength(1));
      await checked.directory.delete(recursive: true);
    },
  );

  test(
    'ZIP restores books, progress, notes, sources and settings with portable paths',
    () async {
      final zip = await snapshot();
      await db.update('books', {'currentPage': 9});
      await db.delete('book_notes');
      await prefs.setDouble('reader_font_size', 12);
      await prefs.setString('reader_new_setting', 'remove-me');
      sources.raw = '{"version":2,"sources":[],"groups":["changed"]}';
      final checked = await archive.validate(zip);
      try {
        await archive.restore(checked);
      } finally {
        await checked.directory.delete(recursive: true);
      }
      final book = (await db.query('books')).single;
      expect(book['currentPage'], 4);
      expect(
        (await db.query('sync_local_state')).single['value'],
        'original-stable-identity',
      );
      expect(book['last_canonical_locator'], 'chapter-4');
      expect(book['filePath'], startsWith('books/restored-'));
      expect(
        await File('${documents.path}/${book['filePath']}').readAsString(),
        '原始正文\n第二章',
      );
      expect(
        await File(
          '${documents.path}/${book['filePath']}.openreading-source.json',
        ).exists(),
        isTrue,
      );
      expect(
        (await db.query('book_notes')).single['payload_json'],
        '{"strokes":[1,2]}',
      );
      expect((await db.query('bookmarks')).single['pageNumber'], 4);
      expect(
        (await db.query('reading_stats')).single['durationInSeconds'],
        123,
      );
      expect(prefs.getDouble('reader_font_size'), 22);
      expect(prefs.containsKey('reader_new_setting'), isFalse);
      expect(prefs.getString('account_token'), 'local-only');
      expect(sources.raw, contains('收藏'));
      expect(await File('${documents.path}/books/book.txt').exists(), isTrue);
    },
  );
  test(
    'online bookshelf and online progress restore without local files',
    () async {
      await db.insert('books', {
        'id': 2,
        'title': '在线书',
        'filePath': '',
        'storage_type': 'online',
        'currentPage': 12,
      });
      await prefs.setString('source_reading_progress_book', '{"chapter":12}');
      final zip = await snapshot();
      await db.delete('books', where: 'id = 2');
      final checked = await archive.validate(zip);
      await archive.restore(checked);
      expect(
        (await db.query('books', where: 'id = 2')).single['currentPage'],
        12,
      );
      expect((await db.query('books', where: 'id = 2')).single['filePath'], '');
      await checked.directory.delete(recursive: true);
    },
  );
  for (final committed in [false, true]) {
    test(
      'interrupted restore repairs settings according to SQLite commit $committed',
      () async {
        await db.execute(
          'CREATE TABLE backup_restore_commit(id TEXT PRIMARY KEY)',
        );
        if (committed) {
          await db.insert('backup_restore_commit', {'id': 'operation'});
        }
        final journal = File('${documents.path}/backups/restore-pending.json');
        await journal.parent.create();
        await journal.writeAsString(
          jsonEncode({
            'id': 'operation',
            'before': {
              'preferences': {'reader_font_size': 12.0},
              'sources': sources.raw,
            },
            'after': {
              'preferences': {'reader_font_size': 22.0},
              'sources': sources.raw,
            },
          }),
        );
        await archive.recoverInterruptedRestore();
        expect(prefs.getDouble('reader_font_size'), committed ? 22.0 : 12.0);
        expect(await journal.exists(), isFalse);
      },
    );
  }
  test('restore works in a different documents directory', () async {
    final zip = await snapshot();
    final second = await Directory.systemTemp.createTemp('backup-second-');
    addTearDown(() => second.delete(recursive: true));
    final target = BackupArchive(
      database: db,
      documents: second,
      preferences: prefs,
      sources: sources,
    );
    final checked = await target.validate(zip);
    await target.restore(checked);
    await checked.directory.delete(recursive: true);
    final row = (await db.query('books')).single;
    expect(await File('${second.path}/${row['filePath']}').exists(), isTrue);
  });
  test(
    'corrupt and traversal archives are rejected without changing local data',
    () async {
      final zip = await snapshot();
      for (final name in [
        '../escape.txt',
        'books/../../escape.txt',
        'books/evil',
      ]) {
        final contents = ZipDecoder().decodeBytes(await zip.readAsBytes());
        contents.addFile(ArchiveFile(name, 3, [1, 2, 3]));
        final corrupt = File('${documents.path}/corrupt.zip');
        await corrupt.writeAsBytes(ZipEncoder().encode(contents)!);
        await expectLater(
          archive.validate(corrupt),
          throwsA(isA<FormatException>()),
        );
        expect((await db.query('books')).single['currentPage'], 4);
      }
    },
  );
  test(
    'foreign-key failure rolls back all database rows and leaves settings intact',
    () async {
      final zip = await snapshot();
      final checked = await archive.validate(zip);
      (checked.data['tables']['book_notes'] as List).first['book_id'] = 999;
      await db.update('books', {'currentPage': 8});
      await expectLater(archive.restore(checked), throwsA(anything));
      expect((await db.query('books')).single['currentPage'], 8);
      expect((await db.query('book_notes')).single['content'], '笔记');
      expect(prefs.getDouble('reader_font_size'), 22);
      await checked.directory.delete(recursive: true);
    },
  );
  test(
    'missing books fail backup instead of silently producing an incomplete ZIP',
    () async {
      await File('${documents.path}/books/book.txt').delete();
      await expectLater(snapshot(), throwsA(isA<FileSystemException>()));
    },
  );
  test(
    'secrets and connection settings are absent from the ZIP manifest',
    () async {
      final zip = await snapshot();
      final decoded = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final manifest = utf8.decode(
        decoded.findFile('backup.json')!.content as List<int>,
      );
      expect(manifest, isNot(contains('local-only')));
    },
  );
  test(
    'real DAV without ETags or OPTIONS keeps snapshots and restores an earlier one',
    () async {
      final server = await LocalWebDavServer.start();
      addTearDown(server.close);
      server.rejectHead = true;
      server.rejectOptions = true;
      final controller = WebDavBackupController(
        configStore: SecureSyncConfigStore(
          secretStorage: _Secrets(),
          preferences: _Preferences(),
        ),
        archiveFactory: () async => archive,
      );
      addTearDown(controller.dispose);
      final draft = WebDavSyncConfigDraft(
        serverUrl: server.url,
        username: 'reader',
        password: 'secret',
        allowInsecurePrivateHttp: true,
      );
      expect((await controller.testConnection(draft)).success, isTrue);
      await controller.configure(draft);
      expect(
        server.puts,
        1,
      ); // Connection probe only: configuration never backs up.
      final stages = <String>{};
      var sawUploadBytes = false;
      controller.addListener(() {
        stages.add(controller.stage);
        if (controller.stage == 'uploading' && controller.completedBytes > 0) {
          sawUploadBytes = true;
        }
      });
      await controller.backup();
      expect(
        stages,
        containsAll(['packing', 'verifying', 'uploading', 'finishing']),
      );
      expect(sawUploadBytes, isTrue);
      expect(controller.bytesPerSecond, 0);
      expect(controller.stage, isEmpty);
      await db.update('books', {'currentPage': 8});
      await controller.backup();
      await controller.refresh();
      expect(controller.backups, hasLength(2));
      controller.restoreSelection = const RestoreSelection(overwrite: true);
      await controller.restore(controller.backups.last);
      expect((await db.query('books')).single['currentPage'], 4);
      expect(await File(controller.recoveryPath!).exists(), isTrue);
      expect(
        server.requests.any(
          (r) =>
              r.startsWith('OPTIONS') ||
              r.startsWith('MOVE') ||
              r.startsWith('HEAD'),
        ),
        isFalse,
      );
      final incomplete = File(
        '${server.root.path}/OpenReading/backups/open-reading-123-abcdef.zip',
      );
      await incomplete.writeAsString('partial');
      await controller.refresh();
      expect(controller.backups, hasLength(2));
      server.failNextPut = true;
      await expectLater(controller.backup(), throwsA(isA<WebDavSyncFailure>()));
      expect(controller.busy, isFalse);
      await controller.refresh();
      expect(controller.backups, hasLength(2));
    },
  );
}

class _Sources implements BookSourceRegistryStorage {
  String raw =
      '{"version":2,"sources":[{"id":"source1","name":"书源","manifestUrl":"https://example.test/manifest","apiBaseUrl":"https://example.test/api","protocolVersion":"1.0"}],"groups":["收藏"]}';
  @override
  Future<String?> read() async => raw;
  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}

class _Secrets implements SyncSecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

class _Preferences implements SyncPreferences {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}
