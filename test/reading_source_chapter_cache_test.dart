import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/protocol/reading_source/reading_source_backend.dart';
import 'package:xxread/book_sources/caching/book_source_chapter_cache.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookSourceChapterCache.clearMemory();
  });

  test(
    'reading source reuses catalog and chapter from disk after reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reading-source-chapter-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = _readingSource();
      final firstRuntime = _CachingRuntime();
      final firstBackend = ReadingSourceBackend(
        () => firstRuntime,
        chapterCache: BookSourceChapterCache(cacheDirectory: directory),
        additionalProtocolsEnabled: () async => true,
      );

      final catalog = await firstBackend.getChapters(
        source,
        'book',
        sourceVariables: const {'token': 'one', 'page': '1'},
      );
      final chapter = await firstBackend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
        sourceVariables: const {'page': '1', 'token': 'one'},
      );
      // Map insertion order must not split an otherwise identical cache key.
      await firstBackend.getChapters(
        source,
        'book',
        sourceVariables: const {'page': '1', 'token': 'one'},
      );
      await firstBackend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
        sourceVariables: const {'token': 'one', 'page': '1'},
      );

      expect(catalog.single.id, 'chapter');
      expect(chapter.content, 'cached body');
      expect(firstRuntime.catalogLoads, 1);
      expect(firstRuntime.contentLoads, 1);
      await _waitForJsonFiles(directory, 2);

      BookSourceChapterCache.clearMemory();
      final reopenedRuntime = _CachingRuntime();
      final reopenedBackend = ReadingSourceBackend(
        () => reopenedRuntime,
        chapterCache: BookSourceChapterCache(cacheDirectory: directory),
        additionalProtocolsEnabled: () async => true,
      );

      final reopenedCatalog = await reopenedBackend.getChapters(
        source,
        'book',
        sourceVariables: const {'token': 'one', 'page': '1'},
      );
      final reopenedChapter = await reopenedBackend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
        sourceVariables: const {'token': 'one', 'page': '1'},
      );

      expect(reopenedCatalog.single.id, 'chapter');
      expect(reopenedChapter.content, 'cached body');
      expect(reopenedRuntime.catalogLoads, 0);
      expect(reopenedRuntime.contentLoads, 0);
    },
  );

  test('reading source login invalidates cached chapter content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reading-source-auth-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final runtime = _CachingRuntime();
    final backend = ReadingSourceBackend(
      () => runtime,
      chapterCache: BookSourceChapterCache(cacheDirectory: directory),
      additionalProtocolsEnabled: () async => true,
    );
    final source = _readingSource();

    await backend.getChapterContent(
      source,
      bookId: 'book',
      chapterId: 'chapter',
    );
    await backend.getChapterContent(
      source,
      bookId: 'book',
      chapterId: 'chapter',
    );
    expect(runtime.contentLoads, 1);

    await backend.loginSource(source, const {'account': 'new-user'});
    await backend.getChapterContent(
      source,
      bookId: 'book',
      chapterId: 'chapter',
    );

    expect(runtime.loginCalls, 1);
    expect(runtime.contentLoads, 2);
  });

  test('reading source download reuses fresh chapter content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reading-source-download-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final runtime = _CachingRuntime();
    final backend = ReadingSourceBackend(
      () => runtime,
      chapterCache: BookSourceChapterCache(cacheDirectory: directory),
      additionalProtocolsEnabled: () async => true,
    );
    final source = _readingSource();

    await backend.getChapters(source, 'book');
    final downloadedCatalog = await backend.getChaptersForDownload(
      source,
      'book',
    );
    await backend.getChapterContent(
      source,
      bookId: 'book',
      chapterId: 'chapter',
    );
    final downloaded = await backend.getChapterContentForDownload(
      source,
      bookId: 'book',
      chapterId: 'chapter',
    );

    expect(downloadedCatalog.single.id, 'chapter');
    expect(runtime.catalogLoads, 1);
    expect(downloaded.content, 'cached body');
    expect(runtime.contentLoads, 1);
  });
}

RegisteredBookSource _readingSource() => RegisteredBookSource(
  id: 'reading-cache-source',
  name: 'Reading Cache Source',
  description: '',
  manifestUrl: Uri.parse('https://example.test/source.json'),
  apiBaseUrl: Uri.parse('https://example.test/api/'),
  protocolVersion: '1.0',
  languages: const [],
  capabilities: const {'toc', 'content'},
  enabled: true,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: const {
    'bookSourceUrl': 'https://example.test',
    'ruleToc': {'chapterList': 'body'},
    'ruleContent': {'content': 'article'},
  },
);

class _CachingRuntime extends SourceRuntime {
  int catalogLoads = 0;
  int contentLoads = 0;
  int loginCalls = 0;

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    catalogLoads++;
    return const [BookSourceChapter(id: 'chapter', title: 'Chapter', order: 1)];
  }

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    contentLoads++;
    return const BookSourceChapterContent(
      bookId: 'book',
      chapterId: 'chapter',
      title: 'Chapter',
      content: 'cached body',
      contentType: 'text/plain',
    );
  }

  @override
  Future<void> login(
    RegisteredBookSource registered,
    Map<String, String> values,
  ) async {
    loginCalls++;
  }
}

Future<void> _waitForJsonFiles(Directory directory, int expected) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .toList();
    if (files.length >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $expected cache files.');
}
