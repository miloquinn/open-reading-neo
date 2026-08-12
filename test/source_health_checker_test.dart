import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';

void main() {
  group('SourceHealthChecker', () {
    test(
      'reports every capability healthy when the full chain succeeds',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9&page=1':
              '''
          <div class="book">
            <a href="/book/1"><span class="name">剑来</span></a>
            <span class="author">烽火</span>
          </div>
        ''',
          'https://books.test/explore?page=1': '''
          <div class="book">
            <a href="/book/2"><span class="name">另一本书</span></a>
            <span class="author">某人</span>
          </div>
        ''',
          'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
          'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
          'https://books.test/chapter/1':
              '<article id="content"><p>正文</p></article>',
        });
        final source = _fixtureSource().toRegisteredSource(enabled: true);
        final checker = const SourceHealthChecker();

        final result = await checker.check(
          source,
          runtime: SourceRuntime(transport: transport),
        );

        expect(result.healthy, isTrue);
        expect(result.timedOut, isFalse);
        expect(result.failed, isEmpty);
        expect(result.checked, {
          SourceHealthCapability.search,
          SourceHealthCapability.discover,
          SourceHealthCapability.info,
          SourceHealthCapability.catalog,
          SourceHealthCapability.content,
        });
        expect(result.respondTimeMs, isNotNull);
      },
    );

    test(
      'isolates a broken content rule without failing search, info, or catalog',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9&page=1':
              '''
          <div class="book">
            <a href="/book/1"><span class="name">剑来</span></a>
          </div>
        ''',
          'https://books.test/explore?page=1': '<div></div>',
          'https://books.test/book/1': '''
          <h1>剑来</h1>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
          'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
          // Chapter/1 has no #content element, so the content rule matches
          // nothing and the checker should report only 'content' as failed.
          'https://books.test/chapter/1': '<article><p>无匹配</p></article>',
        });
        final source = _fixtureSource().toRegisteredSource(enabled: true);
        final checker = const SourceHealthChecker();

        final result = await checker.check(
          source,
          runtime: SourceRuntime(transport: transport),
        );

        expect(result.healthy, isFalse);
        expect(result.failed, {
          SourceHealthCapability.discover,
          SourceHealthCapability.content,
        });
        expect(result.checked, contains(SourceHealthCapability.info));
        expect(result.checked, contains(SourceHealthCapability.catalog));
      },
    );

    test(
      'never reaches the reading chain when search and discover both fail',
      () async {
        final transport = _FakeTransport(const {});
        final source = _fixtureSource().toRegisteredSource(enabled: true);
        final checker = const SourceHealthChecker();

        final result = await checker.check(
          source,
          runtime: SourceRuntime(transport: transport),
        );

        expect(result.healthy, isFalse);
        expect(result.failed, {
          SourceHealthCapability.search,
          SourceHealthCapability.discover,
        });
        expect(result.checked, {
          SourceHealthCapability.search,
          SourceHealthCapability.discover,
        });
      },
    );

    test('reports a timeout instead of hanging forever', () async {
      final transport = _HangingTransport();
      final source = _fixtureSource().toRegisteredSource(enabled: true);
      final checker = const SourceHealthChecker(
        timeout: Duration(milliseconds: 50),
      );

      final result = await checker.check(
        source,
        runtime: SourceRuntime(transport: transport),
      );

      expect(result.timedOut, isTrue);
      expect(result.healthy, isFalse);
      expect(result.respondTimeMs, isNull);
    });
  });

  group('SourceHealthCheckResult.fullyAvailable', () {
    test('true once search, discover, info, and content all pass', () {
      final result = SourceHealthCheckResult(
        checked: const {
          SourceHealthCapability.search,
          SourceHealthCapability.discover,
          SourceHealthCapability.info,
          SourceHealthCapability.catalog,
          SourceHealthCapability.content,
        },
        failed: const {},
        checkedAt: DateTime.utc(2026, 8, 12),
      );

      expect(result.fullyAvailable, isTrue);
      expect(result.missingForFullAvailability, isEmpty);
    });

    test(
      'false, and reported missing, when a required capability was never attempted',
      () {
        // A source with no declared search rule never adds `search` to
        // `checked`, so `healthy` can be true while `fullyAvailable` is not.
        final result = SourceHealthCheckResult(
          checked: const {
            SourceHealthCapability.discover,
            SourceHealthCapability.info,
            SourceHealthCapability.catalog,
            SourceHealthCapability.content,
          },
          failed: const {},
          checkedAt: DateTime.utc(2026, 8, 12),
        );

        expect(result.healthy, isTrue);
        expect(result.fullyAvailable, isFalse);
        expect(result.missingForFullAvailability, {
          SourceHealthCapability.search,
        });
      },
    );

    test('false, and reported missing, when a required capability failed', () {
      final result = SourceHealthCheckResult(
        checked: const {
          SourceHealthCapability.search,
          SourceHealthCapability.discover,
          SourceHealthCapability.info,
          SourceHealthCapability.catalog,
          SourceHealthCapability.content,
        },
        failed: const {SourceHealthCapability.content},
        checkedAt: DateTime.utc(2026, 8, 12),
      );

      expect(result.fullyAvailable, isFalse);
      expect(result.missingForFullAvailability, {
        SourceHealthCapability.content,
      });
    });

    test('a timed-out check is never fully available', () {
      final result = SourceHealthCheckResult(
        checked: const {},
        failed: const {},
        checkedAt: DateTime.utc(2026, 8, 12),
        timedOut: true,
      );

      expect(result.fullyAvailable, isFalse);
      expect(
        result.missingForFullAvailability,
        SourceHealthCheckResult.fullAvailabilityCapabilities,
      );
    });
  });

  group('withSourceHealthCheckResult / sourceHealthCheckResultOf', () {
    test('round-trips through source config storage', () {
      final source = _fixtureSource().toRegisteredSource(enabled: true);
      final result = SourceHealthCheckResult(
        checked: const {
          SourceHealthCapability.search,
          SourceHealthCapability.content,
        },
        failed: const {SourceHealthCapability.content},
        checkedAt: DateTime.utc(2026, 8, 8, 12),
        respondTimeMs: 842,
      );

      final updated = withSourceHealthCheckResult(source, result);
      final read = sourceHealthCheckResultOf(updated);

      expect(read, isNotNull);
      expect(read!.healthy, isFalse);
      expect(read.checked, result.checked);
      expect(read.failed, result.failed);
      expect(read.respondTimeMs, 842);
      expect(read.checkedAt, DateTime.utc(2026, 8, 8, 12));
    });

    test('returns null for a source that has never been checked', () {
      final source = _fixtureSource().toRegisteredSource(enabled: true);
      expect(sourceHealthCheckResultOf(source), isNull);
    });
  });
}

ReadingSourceConfig _fixtureSource() => ReadingSourceConfig.fromJson({
  'bookSourceName': 'Health test',
  'bookSourceUrl': 'https://books.test',
  'searchUrl': '/search?q={{key}}&page={{page}}',
  'exploreUrl': '发现::/explore?page={{page}}',
  'ruleSearch': {
    'bookList': 'class.book',
    'name': 'class.name@text',
    'author': 'class.author@text',
    'bookUrl': 'tag.a@href',
  },
  'ruleExplore': {
    'bookList': 'class.book',
    'name': 'class.name@text',
    'author': 'class.author@text',
    'bookUrl': 'tag.a@href',
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'author': 'class.author@text',
    'tocUrl': 'class.toc@href',
  },
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

class _HangingTransport implements SourceTransport {
  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) {
    return Completer<SourceResponse>().future;
  }
}
