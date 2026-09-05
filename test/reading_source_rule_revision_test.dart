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

  test(
    'rule revision bypasses revision 1 catalog and content on disk',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reading-source-rule-revision-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = BookSourceChapterCache(cacheDirectory: directory);
      final source = _source();
      // Frozen backend revision for this source before the OnlyOne and
      // JS-followed-by-## rule fixes, with empty variables and auth revision 0.
      const revision1 =
          'e45dffe131e8e1ec4eacc95917440a2fd0c7610ac871c53a630802ff8771d2cb';

      await cache.getChapterCatalogOrLoad(
        sourceId: source.id,
        sourceRevision: revision1,
        bookId: 'book',
        loader: () async => const [
          BookSourceChapter(id: 'stale', title: 'Stale catalog', order: 0),
        ],
      );
      await cache.getOrLoad(
        sourceId: source.id,
        sourceRevision: revision1,
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async => const BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter',
          title: 'Stale chapter',
          content: 'stale content',
          contentType: 'text/plain',
        ),
      );
      await _waitForCacheFiles(directory, 2);
      BookSourceChapterCache.clearMemory();

      final runtime = _RevisionRuntime();
      final backend = _backend(runtime, directory);
      final catalog = await backend.getChapters(source, 'book');
      final content = await backend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
      );

      expect(catalog.single.id, 'current');
      expect(content.content, 'current content');
      expect(runtime.catalogLoads, 1);
      expect(runtime.contentLoads, 1);

      await backend.getChapters(source, 'book');
      await backend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
      );
      expect(runtime.catalogLoads, 1);
      expect(runtime.contentLoads, 1);
      await _waitForCacheFiles(directory, 4);

      BookSourceChapterCache.clearMemory();
      final reopenedRuntime = _RevisionRuntime();
      final reopenedBackend = _backend(reopenedRuntime, directory);
      final reopenedCatalog = await reopenedBackend.getChapters(source, 'book');
      final reopenedContent = await reopenedBackend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
      );

      expect(reopenedCatalog.single.id, 'current');
      expect(reopenedContent.content, 'current content');
      expect(reopenedRuntime.catalogLoads, 0);
      expect(reopenedRuntime.contentLoads, 0);
    },
  );
}

ReadingSourceBackend _backend(_RevisionRuntime runtime, Directory directory) =>
    ReadingSourceBackend(
      () => runtime,
      chapterCache: BookSourceChapterCache(cacheDirectory: directory),
      additionalProtocolsEnabled: () async => true,
    );

RegisteredBookSource _source() => RegisteredBookSource(
  id: 'rule-revision-source',
  name: 'Rule revision source',
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

class _RevisionRuntime extends SourceRuntime {
  int catalogLoads = 0;
  int contentLoads = 0;

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    catalogLoads++;
    return const [
      BookSourceChapter(id: 'current', title: 'Current catalog', order: 0),
    ];
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
      title: 'Current chapter',
      content: 'current content',
      contentType: 'text/plain',
    );
  }
}

Future<void> _waitForCacheFiles(Directory directory, int count) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .length;
    if (files >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $count cache files.');
}
