import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/book_sources/caching/book_source_chapter_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/protocol/reading_source/reading_source_backend.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookSourceChapterCache.clearMemory();
  });

  for (final reopen in [false, true]) {
    test(
      'reloads pre-fix XPath catalog from ${reopen ? 'disk' : 'memory'}',
      () async {
        final directory = await Directory.systemTemp.createTemp('xpath-cache-');
        addTearDown(() => directory.delete(recursive: true));
        final cache = BookSourceChapterCache(cacheDirectory: directory);
        final source = _source();
        // Frozen revision produced by the backend before rule-engine semantics
        // were versioned, for this source, empty variables and auth revision 0.
        const legacyRevision =
            '6084d6052e4cc616675e373a4b4a6eee4020fd3669a90359e863821ce523fb81';
        await cache.getChapterCatalogOrLoad(
          sourceId: source.id,
          sourceRevision: legacyRevision,
          bookId: 'book',
          loader: () async => const [
            BookSourceChapter(id: 'latest', title: 'Latest only', order: 0),
          ],
        );
        await _waitForCacheFiles(directory, 1);
        if (reopen) BookSourceChapterCache.clearMemory();

        final runtime = _CatalogRuntime();
        final backend = _backend(runtime, directory);
        final chapters = await backend.getChapters(source, 'book');
        expect(chapters.map((chapter) => chapter.id), ['first', 'second']);
        expect(runtime.loads, 1);

        await backend.getChapters(source, 'book');
        expect(
          runtime.loads,
          1,
          reason: 'The repaired catalog remains cacheable.',
        );
        await _waitForCacheFiles(directory, 2);
        BookSourceChapterCache.clearMemory();
        final reopenedRuntime = _CatalogRuntime();
        final reopened = await _backend(
          reopenedRuntime,
          directory,
        ).getChapters(source, 'book');
        expect(reopened.map((chapter) => chapter.id), ['first', 'second']);
        expect(reopenedRuntime.loads, 0);
      },
    );
  }

  test(
    'versioned catalogs still isolate sources and source variables',
    () async {
      final directory = await Directory.systemTemp.createTemp('xpath-cache-');
      addTearDown(() => directory.delete(recursive: true));
      final runtime = _CatalogRuntime();
      final backend = _backend(runtime, directory);
      await backend.getChapters(
        _source(),
        'book',
        sourceVariables: const {'token': 'one', 'page': '1'},
      );
      await backend.getChapters(
        _source(),
        'book',
        sourceVariables: const {'page': '1', 'token': 'one'},
      );
      expect(runtime.loads, 1);
      await backend.getChapters(
        _source(),
        'book',
        sourceVariables: const {'page': '1', 'token': 'two'},
      );
      expect(runtime.loads, 2);
      await backend.getChapters(
        _source(id: 'other-source'),
        'book',
        sourceVariables: const {'page': '1', 'token': 'two'},
      );
      expect(runtime.loads, 3);
      await _waitForCacheFiles(directory, 3);
    },
  );
}

ReadingSourceBackend _backend(_CatalogRuntime runtime, Directory directory) =>
    ReadingSourceBackend(
      () => runtime,
      chapterCache: BookSourceChapterCache(cacheDirectory: directory),
      additionalProtocolsEnabled: () async => true,
    );

RegisteredBookSource _source({String id = 'xpath-cache-source'}) =>
    RegisteredBookSource(
      id: id,
      name: 'XPath source',
      description: '',
      manifestUrl: Uri.parse('https://example.test/source.json'),
      apiBaseUrl: Uri.parse('https://example.test/api/'),
      protocolVersion: '1.0',
      languages: const [],
      capabilities: const {'toc'},
      enabled: true,
      addedAt: DateTime.utc(2026),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: const {
        'bookSourceUrl': 'https://example.test',
        'ruleToc': {'chapterList': '//div[@class="catalog"][2]/a'},
      },
    );

class _CatalogRuntime extends SourceRuntime {
  int loads = 0;

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    loads++;
    return const [
      BookSourceChapter(id: 'first', title: 'First', order: 0),
      BookSourceChapter(id: 'second', title: 'Second', order: 1),
    ];
  }
}

Future<void> _waitForCacheFiles(Directory directory, int count) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final files = await directory
        .list(recursive: true)
        .where((file) => file is File && file.path.endsWith('.json'))
        .length;
    if (files >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $count cache files.');
}
