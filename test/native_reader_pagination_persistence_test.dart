import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/data/migration/pagination_cache_schema_migration.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late Directory fixtureDirectory;
  late Database database;
  late PaginationCacheDao cacheDao;
  late File bookFile;
  late Book book;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    supportDirectory = await Directory.systemTemp.createTemp(
      'open-reading-pagination-support-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => supportDirectory.path,
        );
  });

  setUp(() async {
    fixtureDirectory = Directory.systemTemp.createTempSync(
      'open-reading-pagination-fixture-',
    );
    bookFile = File('${fixtureDirectory.path}/cached.txt')
      ..writeAsStringSync(
        '第1章 缓存验证\n${List<String>.filled(3, '分页缓存必须保持文字边界和阅读位置完全一致。').join('\n')}',
      );
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('PRAGMA foreign_keys = ON');
    await database.execute(
      'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT)',
    );
    await database.insert('books', {'id': 1});
    await PaginationCacheSchemaMigration.migrate(database);
    cacheDao = PaginationCacheDao(databaseProvider: () async => database);
    book = Book(
      id: 1,
      title: '分页缓存验证',
      author: '测试',
      filePath: bookFile.path,
      format: 'txt',
      contentHash: 'pagination-persistence-fixture',
      fileModifiedTime: bookFile.lastModifiedSync().millisecondsSinceEpoch,
    );
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.instantPage.name,
      ReaderSettingsStore.txtChapterTitlePageKey: false,
      ReaderSettingsStore.fontSizeKey: 19.0,
    });
  });

  tearDown(() async {
    await database.close();
    fixtureDirectory.deleteSync(recursive: true);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await supportDirectory.delete(recursive: true);
  });

  testWidgets(
    'reopens from persisted boundaries and safely replaces corrupt payloads',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final firstMisses = <int>[];
      await _openReader(
        tester,
        book: book,
        cacheDao: cacheDao,
        misses: firstMisses,
      );
      expect(firstMisses, isNotEmpty);
      await _waitForStoredRows(tester, database, minimum: 1);
      await _closeReader(tester);

      final secondMisses = <int>[];
      await _openReader(
        tester,
        book: book,
        cacheDao: cacheDao,
        misses: secondMisses,
      );
      expect(secondMisses, isEmpty);
      await _closeReader(tester);

      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.instantPage.name,
        ReaderSettingsStore.txtChapterTitlePageKey: false,
        ReaderSettingsStore.fontSizeKey: 23.0,
      });
      final changedLayoutMisses = <int>[];
      await _openReader(
        tester,
        book: book,
        cacheDao: cacheDao,
        misses: changedLayoutMisses,
      );
      expect(changedLayoutMisses, isNotEmpty);
      await _waitForStoredRows(tester, database, minimum: 2);
      await _closeReader(tester);

      await tester.runAsync(
        () => database.update(PaginationCacheSchemaMigration.tableName, {
          'payload': Uint8List.fromList([1, 2, 3]),
        }),
      );
      final corruptPayloadMisses = <int>[];
      await _openReader(
        tester,
        book: book,
        cacheDao: cacheDao,
        misses: corruptPayloadMisses,
      );
      expect(corruptPayloadMisses, isNotEmpty);
      await _waitForValidPayloads(tester, database);
      await _closeReader(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('restores EPUB rich text and image boundaries from disk', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(480, 800));
    final epub = File('${fixtureDirectory.path}/cached.epub')
      ..writeAsBytesSync(_epubFixture());
    final epubBook = Book(
      id: 1,
      title: 'EPUB 分页缓存验证',
      author: '测试',
      filePath: epub.path,
      format: 'epub',
      contentHash: 'epub-pagination-persistence-fixture',
      fileModifiedTime: epub.lastModifiedSync().millisecondsSinceEpoch,
    );

    final firstMisses = <int>[];
    await _openReader(
      tester,
      book: epubBook,
      cacheDao: cacheDao,
      misses: firstMisses,
    );
    expect(firstMisses, isNotEmpty);
    await _waitForStoredRows(tester, database, minimum: 1);
    await _closeReader(tester);

    final secondMisses = <int>[];
    await _openReader(
      tester,
      book: epubBook,
      cacheDao: cacheDao,
      misses: secondMisses,
    );
    expect(secondMisses, isEmpty);
    await _closeReader(tester);
    await tester.binding.setSurfaceSize(null);
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _openReader(
  WidgetTester tester, {
  required Book book,
  required PaginationCacheDao cacheDao,
  required List<int> misses,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NativeReaderPage(
        book: book,
        paginationCacheDao: cacheDao,
        usePaginationMemoryCache: false,
        onPaginationCacheMiss: misses.add,
      ),
    ),
  );
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 80; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
      if (find.byType(ReaderPaperPageLeaf).evaluate().isNotEmpty) return;
    }
  });
  expect(find.byType(ReaderPaperPageLeaf), findsOneWidget);
  await tester.pump();
}

Future<void> _closeReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _waitForStoredRows(
  WidgetTester tester,
  Database database, {
  required int minimum,
}) async {
  final count = await tester.runAsync(() async {
    for (var attempt = 0; attempt < 80; attempt++) {
      final rows = await database.rawQuery(
        'SELECT COUNT(*) AS count FROM ${PaginationCacheSchemaMigration.tableName}',
      );
      final count = rows.first['count'] as int?;
      if ((count ?? 0) >= minimum) return count;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return 0;
  });
  expect(count, greaterThanOrEqualTo(minimum));
}

Future<void> _waitForValidPayloads(
  WidgetTester tester,
  Database database,
) async {
  final valid = await tester.runAsync(() async {
    for (var attempt = 0; attempt < 80; attempt++) {
      final rows = await database.query(
        PaginationCacheSchemaMigration.tableName,
        columns: const ['payload'],
      );
      if (rows.any((row) => (row['payload']! as Uint8List).length > 3)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  });
  expect(valid, isTrue);
}

List<int> _epubFixture() {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  void addBytes(String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">cache-fixture</dc:identifier>
    <dc:title>Cache fixture</dc:title><dc:language>zh</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="pixel" href="pixel.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''');
  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="cache-fixture"/></head>
  <docTitle><text>Cache fixture</text></docTitle>
  <navMap><navPoint id="nav1" playOrder="1"><navLabel><text>第一章</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap>
</ncx>''');
  addBytes(
    'OEBPS/pixel.png',
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );
  add('OEBPS/chapter.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head><body>
  <h1>第一章</h1>
  <p><strong>粗体开头</strong>后面接普通文字，用来验证富文本边界。</p>
  <img src="pixel.png" alt=""/>
  <p>图片后的正文必须从持久化缓存恢复，同时保持 canonical offset 连续。</p>
</body></html>''');
  return ZipEncoder().encode(archive)!;
}
