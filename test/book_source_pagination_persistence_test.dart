import 'dart:typed_data';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reader/book_source/book_source_reader_page.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';
import 'package:xxread/data/migration/pagination_cache_schema_migration.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database database;
  setUpAll(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'online-pagination-sqlite-',
    );
    database = await databaseFactoryFfi.openDatabase(
      '${directory.path}/cache.db',
    );
    await database.execute('CREATE TABLE books(id INTEGER PRIMARY KEY)');
    await PaginationCacheSchemaMigration.migrate(database);
  });
  tearDownAll(() async {
    if (database.isOpen) await database.close();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'online reopen reuses boundaries and rejects changed content, layout, source and corrupt payloads',
    (tester) async {
      final rules = ReplaceRuleService();
      final client = _Client();
      var misses = 0;
      final source = RegisteredBookSource(
        id: 'source',
        name: 'Source',
        description: '',
        manifestUrl: Uri.parse('https://example.org/source'),
        apiBaseUrl: Uri.parse('https://example.org/api/'),
        protocolVersion: '1.0',
        languages: const ['en'],
        capabilities: const {'catalog', 'content'},
        enabled: true,
        addedAt: DateTime.utc(2026),
      );
      Future<void> open({
        String bookId = 'book',
        RegisteredBookSource? sourceOverride,
      }) async {
        SharedPreferences.setMockInitialValues({
          ReaderSettingsStore.pageModeKey:
              BookSourcePageMode.horizontalSlide.name,
        });
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BookSourceReaderPage(
              source: sourceOverride ?? source,
              book: BookSourceBook(
                id: bookId,
                title: 'Book',
                author: '',
                description: '',
                categories: const [],
              ),
              replaceRuleService: rules,
              client: client,
              paginationCacheDao: PaginationCacheDao(
                databaseProvider: () async => database,
              ),
              onPaginationCacheMiss: (_) => misses++,
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var i = 0; i < 80; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
            if (find.byType(ReaderPaperPageLeaf).evaluate().isNotEmpty) break;
          }
        });
        expect(find.byType(ReaderPaperPageLeaf), findsWidgets);
        expect(tester.takeException(), isNull);
      }

      Future<void> close() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() async {
          await database.rawQuery(
            'SELECT COUNT(*) FROM ${PaginationCacheSchemaMigration.tableName}',
          );
        });
      }

      await open();
      expect(misses, greaterThan(0));
      await tester.runAsync(() async {
        final dao = PaginationCacheDao(databaseProvider: () async => database);
        for (var i = 0; i < 80; i++) {
          if (await dao.payloadSizeBytes() > 0) return;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        fail('the reader must persist actual SQLite boundaries');
      });
      await close();
      await tester.runAsync(() async {
        await database.close();
        database = await databaseFactoryFfi.openDatabase(
          '${directory.path}/cache.db',
        );
      });
      misses = 0;
      await open();
      expect(
        misses,
        0,
        reason:
            'fresh reader and DAO restore persisted boundaries before layout',
      );
      await close();
      client.body = client.body.replaceAll('Alpha', 'Bravo');
      await open();
      expect(
        misses,
        greaterThan(0),
        reason: 'same-length content must invalidate',
      );
      await close();
      misses = 0;
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(1000, 700);
      await open();
      expect(misses, greaterThan(0), reason: 'viewport change must invalidate');
      await close();
      misses = 0;
      await open(bookId: 'other-book');
      expect(
        misses,
        greaterThan(0),
        reason: 'source book identity must isolate',
      );
      await close();
      misses = 0;
      await open(
        sourceOverride: source.copyWith(sourceConfig: {'rule': 'changed'}),
      );
      expect(
        misses,
        greaterThan(0),
        reason: 'source configuration revision must isolate',
      );
      await close();
      await tester.runAsync(
        () => database.update(PaginationCacheSchemaMigration.tableName, {
          'payload': Uint8List.fromList([1, 2]),
        }),
      );
      misses = 0;
      await open();
      expect(misses, greaterThan(0), reason: 'corrupt bytes recompute');
      await close();
      tester.view.resetPhysicalSize();
      await tester.runAsync(rules.close);
      client.close();
    },
  );
}

class _Client extends BookSourceClient {
  String body = List.filled(
    15,
    'Alpha chapter text for persisted page boundaries.',
  ).join('\n');
  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async => const [
    BookSourceChapter(id: 'chapter', title: 'Chapter', order: 0),
  ];
  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async => BookSourceChapterContent(
    bookId: bookId,
    chapterId: chapterId,
    title: 'Chapter',
    content: body,
    contentType: 'text/plain',
  );
}
