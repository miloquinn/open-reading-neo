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

  test('checkAll persists a health result readable back from the registry', () async {
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
  });

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

ReadingSourceConfig _fixtureSource() => ReadingSourceConfig.fromJson({
  'bookSourceName': 'Health service test',
  'bookSourceUrl': 'https://books.test',
  'searchUrl': '/search?q={{key}}&page={{page}}',
  'ruleSearch': {
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
