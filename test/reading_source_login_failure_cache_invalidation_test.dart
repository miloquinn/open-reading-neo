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
    'failed login persists a new cache revision and preserves its error',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reading-source-failed-login-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = _source();
      final staleRuntime = _LoginRuntime(identity: 'stale', loginFails: true);
      final staleBackend = _backend(staleRuntime, directory);

      expect(
        (await staleBackend.getChapters(source, 'book')).single.id,
        'stale',
      );
      expect(
        (await staleBackend.getChapterContent(
          source,
          bookId: 'book',
          chapterId: 'chapter',
        )).content,
        'stale content',
      );
      await _waitForCacheFiles(directory, 2);

      await expectLater(
        staleBackend.loginSource(source, const {'account': 'changed'}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'source login rejected',
          ),
        ),
      );

      BookSourceChapterCache.clearMemory();
      final currentRuntime = _LoginRuntime(identity: 'current');
      final currentBackend = _backend(currentRuntime, directory);
      final chapters = await currentBackend.getChapters(source, 'book');
      final content = await currentBackend.getChapterContent(
        source,
        bookId: 'book',
        chapterId: 'chapter',
      );

      expect(chapters.single.id, 'current');
      expect(content.content, 'current content');
      expect(currentRuntime.catalogLoads, 1);
      expect(currentRuntime.contentLoads, 1);
    },
  );
}

ReadingSourceBackend _backend(_LoginRuntime runtime, Directory directory) =>
    ReadingSourceBackend(
      () => runtime,
      chapterCache: BookSourceChapterCache(cacheDirectory: directory),
      additionalProtocolsEnabled: () async => true,
    );

RegisteredBookSource _source() => RegisteredBookSource(
  id: 'failed-login-cache-source',
  name: 'Failed login cache source',
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
    'bookSourceName': 'Failed login cache source',
    'bookSourceUrl': 'https://example.test',
    'ruleToc': {'chapterList': 'body'},
    'ruleContent': {'content': 'article'},
  },
);

class _LoginRuntime extends SourceRuntime {
  _LoginRuntime({required this.identity, this.loginFails = false});

  final String identity;
  final bool loginFails;
  int catalogLoads = 0;
  int contentLoads = 0;

  @override
  Future<void> login(
    RegisteredBookSource registered,
    Map<String, String> values,
  ) async {
    if (loginFails) throw StateError('source login rejected');
  }

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    catalogLoads++;
    return [BookSourceChapter(id: identity, title: identity, order: 0)];
  }

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    contentLoads++;
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: identity,
      content: '$identity content',
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
