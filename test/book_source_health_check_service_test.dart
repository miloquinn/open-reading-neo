import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_health_check_service.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'checkAll persists a health result readable back from the registry',
    () async {
      final transport = _FakeTransport({
        'https://books.test/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9&page=1':
            '''
        <div class="book"><a href="/book/1"><span class="name">剑来</span></a></div>
      ''',
        'https://books.test/book/1': '''
        <h1>剑来</h1><a class="toc" href="/book/1/toc">目录</a>
      ''',
        'https://books.test/book/1/toc': '''
        <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
      ''',
        'https://books.test/chapter/1':
            '<article id="content"><p>正文</p></article>',
      });
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      final added = (await registry.upsert(
        _fixtureSource().toRegisteredSource(enabled: true),
      )).single;
      final service = BookSourceHealthCheckService(
        checker: SourceHealthChecker(transport: transport),
        registry: registry,
      );

      var lastCompleted = 0;
      final updated = await service.checkAll([
        added,
      ], onProgress: (completed, total) => lastCompleted = completed);

      expect(updated, hasLength(1));
      expect(sourceHealthCheckResultOf(updated.single)?.healthy, isTrue);
      expect(lastCompleted, 1);

      final reloaded = (await registry.load()).single;
      expect(sourceHealthCheckResultOf(reloaded)?.healthy, isTrue);
      // The health check must not touch fields it isn't responsible for.
      expect(reloaded.enabled, isTrue);
      expect(reloaded.id, added.id);
    },
  );

  test(
    'checkAllForCleanup skips a recently fully-available source and rechecks a stale one',
    () async {
      final transport = _FakeTransport({
        'https://books.test/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9&page=1':
            '''
          <div class="book"><a href="/book/1"><span class="name">剑来</span></a></div>
        ''',
        'https://books.test/explore?page=1': '''
          <div class="book"><a href="/book/1"><span class="name">剑来</span></a></div>
        ''',
        'https://books.test/book/1': '''
          <h1>剑来</h1><a class="toc" href="/book/1/toc">目录</a>
        ''',
        'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
        'https://books.test/chapter/1':
            '<article id="content"><p>正文</p></article>',
      });
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      final config = _fixtureSource(includeExplore: true);
      final stale = config.toRegisteredSource(
        id: 'stale-source',
        enabled: true,
      );
      final freshResult = SourceHealthCheckResult(
        checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
        failed: const {},
        checkedAt: DateTime.now().toUtc(),
      );
      final fresh = withSourceHealthCheckResult(
        config.toRegisteredSource(id: 'fresh-source', enabled: true),
        freshResult,
      );
      final service = BookSourceHealthCheckService(
        checker: SourceHealthChecker(transport: transport),
        registry: registry,
      );

      final progressCalls = <List<int>>[];
      final updated = await service.checkAllForCleanup(
        [fresh, stale],
        onProgress: (completed, total) => progressCalls.add([completed, total]),
      );

      // The fresh source keeps its exact stored result untouched — proof it
      // was never re-checked, not merely re-checked into the same verdict.
      final freshAfter = updated.firstWhere((source) => source.id == fresh.id);
      expect(
        sourceHealthCheckResultOf(freshAfter)?.checkedAt,
        freshResult.checkedAt,
      );
      final staleAfter = updated.firstWhere((source) => source.id == stale.id);
      expect(sourceHealthCheckResultOf(staleAfter)?.fullyAvailable, isTrue);
      // Progress starts already counting the skipped source as done.
      expect(progressCalls.first, [1, 2]);
      expect(progressCalls.last, [2, 2]);

      // Only the actually re-checked source is written back to storage.
      final reloaded = await registry.load();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.id, stale.id);
    },
  );

  test(
    'checkAllForCleanup honors isCancelled by never starting queued checks',
    () async {
      // No fake responses configured: if the cancelled source were checked
      // anyway, its requests would throw "missing fake response" and the
      // source would come back with a (failing) health result instead of
      // vanishing from the output entirely.
      final transport = _FakeTransport(const {});
      final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
      final stale = _fixtureSource().toRegisteredSource(
        id: 'stale-source',
        enabled: true,
      );
      final service = BookSourceHealthCheckService(
        checker: SourceHealthChecker(transport: transport),
        registry: registry,
      );

      final updated = await service.checkAllForCleanup([
        stale,
      ], isCancelled: () => true);

      expect(updated, isEmpty);
      expect(await registry.load(), isEmpty);
    },
  );

  test('checkOne persists just that source', () async {
    final transport = _FakeTransport(const {});
    final registry = BookSourceRegistry(storage: _MemoryRegistryStorage());
    final added = (await registry.upsert(
      _fixtureSource().toRegisteredSource(enabled: true),
    )).single;
    final service = BookSourceHealthCheckService(
      checker: SourceHealthChecker(transport: transport),
      registry: registry,
    );

    final updated = await service.checkOne(added);

    expect(sourceHealthCheckResultOf(updated)?.healthy, isFalse);
    final reloaded = (await registry.load()).single;
    expect(sourceHealthCheckResultOf(reloaded)?.healthy, isFalse);
  });
}

ReadingSourceConfig _fixtureSource({bool includeExplore = false}) =>
    ReadingSourceConfig.fromJson({
      'bookSourceName': 'Health service test',
      'bookSourceUrl': 'https://books.test',
      'searchUrl': '/search?q={{key}}&page={{page}}',
      if (includeExplore) 'exploreUrl': '发现::/explore?page={{page}}',
      'ruleSearch': {
        'bookList': 'class.book',
        'name': 'class.name@text',
        'bookUrl': 'tag.a@href',
      },
      if (includeExplore)
        'ruleExplore': {
          'bookList': 'class.book',
          'name': 'class.name@text',
          'bookUrl': 'tag.a@href',
        },
      'ruleBookInfo': {'name': 'h1@text', 'tocUrl': 'class.toc@href'},
      'ruleToc': {
        'chapterList': '#chapters@li',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      },
      'ruleContent': {'content': '#content@html'},
    });

class _FakeTransport implements SourceTransport {
  _FakeTransport(this.responses);

  final Map<String, String> responses;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    final body = responses[request.url.toString()];
    if (body == null) {
      throw StateError('Missing fake response for ${request.url}');
    }
    return SourceResponse(body: body, finalUri: request.url);
  }
}

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}
