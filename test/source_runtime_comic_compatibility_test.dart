import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_script_contract.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('resolves relative comic images from the final response URL', () async {
    final transport = _ComicTransport({
      'https://books.test/chapter/1': SourceResponse(
        body: '<main><img src="../images/1.jpg"></main>',
        finalUri: Uri.parse('https://cdn.test/redirected/chapter/index.html'),
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _comicSource(content: 'main@html'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(
      content.images.single.url,
      Uri.parse('https://cdn.test/redirected/images/1.jpg'),
    );
  });

  test('keeps each page base URL and merges duplicate image options', () async {
    final transport = _ComicTransport({
      'https://books.test/chapter/1': SourceResponse(
        body: '''
          <main><img src='/shared.jpg,{"headers":{"X-First":"1"}}'></main>
          <a class="next" href="https://books.test/chapter/2">Next</a>
        ''',
        finalUri: Uri.parse('https://cdn-one.test/volume/1/index.html'),
      ),
      'https://books.test/chapter/2': SourceResponse(
        body: '''
          <main>
            <img src='https://cdn-one.test/shared.jpg,{"headers":{"X-Second":"2"}}'>
            <img src="../images/2.jpg">
          </main>
        ''',
        finalUri: Uri.parse('https://cdn-two.test/volume/2/index.html'),
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _comicSource(
        content: 'main@html',
        nextContentUrl: 'a.next@href',
        headers: const {'Referer': 'https://books.test/'},
      ),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.images.map((image) => image.url), [
      Uri.parse('https://cdn-one.test/shared.jpg'),
      Uri.parse('https://cdn-two.test/volume/images/2.jpg'),
    ]);
    expect(content.images.first.headers, {
      'Referer': 'https://books.test/',
      'X-First': '1',
      'X-Second': '2',
    });
  });

  test('preserves srcset semantics in bounded raw-page recovery', () async {
    final runtime = SourceRuntime(
      transport: _ComicTransport({
        'https://books.test/chapter/1': SourceResponse(
          body:
              '<div class="comic-content">'
              '<img srcset="../images/one.jpg 1x, ../images/two.jpg 2x">'
              '</div>',
          finalUri: Uri.parse('https://cdn.test/volume/chapter/1'),
        ),
      }),
    );
    addTearDown(runtime.close);
    final content = await runtime.getChapterContent(
      _comicSource(content: '.missing@html'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );
    expect(
      content.images.single.url,
      Uri.parse('https://cdn.test/volume/images/one.jpg'),
    );
  });

  test('evaluates a scripted comic content rule once', () async {
    final evaluator = _ComicEvaluator();
    final runtime = SourceRuntime(
      transport: _ComicTransport({
        'https://books.test/chapter/1': SourceResponse(
          body: '<main>unused</main>',
          finalUri: Uri.parse('https://books.test/chapter/1'),
        ),
      }),
      scriptEvaluator: evaluator,
      loginSessionStore: _MemoryLoginSessionStore(),
    );
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _comicSource(content: '@js:comicImages'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(evaluator.calls, ['comicImages']);
    expect(content.images.map((image) => image.url), [
      Uri.parse('https://books.test/images/1.jpg'),
      Uri.parse('https://books.test/images/2.jpg'),
      Uri.parse('https://books.test/images/3.jpg'),
    ]);
    expect(content.images.last.headers['Cookie'], 'a=1; b=2');
    expect(content.images.first.headers['Referer'], 'https://updated.test/');
  });

  test('does not revive images removed by replaceRegex', () async {
    final runtime = SourceRuntime(
      transport: _ComicTransport({
        'https://books.test/chapter/1': SourceResponse(
          body: '''
            <div class="comic-content">
              <img class="blocked" src="/images/blocked.jpg">
              <p>该页图片已屏蔽</p>
            </div>
          ''',
          finalUri: Uri.parse('https://books.test/chapter/1'),
        ),
      }),
    );
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _comicSource(
        content: 'class.comic-content@html',
        replaceRegex: r'<img[^>]+>',
      ),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.images, isEmpty);
    expect(content.content, isNot(contains('blocked.jpg')));
  });

  test(
    'does not replace a filtered image selection with raw page images',
    () async {
      final runtime = SourceRuntime(
        transport: _ComicTransport({
          'https://books.test/chapter/1': SourceResponse(
            body: '''
            <div class="comic-content">
              <img class="wanted" src="/images/wanted.jpg">
              <img class="blocked" src="/images/blocked.jpg">
            </div>
          ''',
            finalUri: Uri.parse('https://books.test/chapter/1'),
          ),
        }),
      );
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _comicSource(content: 'img.wanted@src'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.images.map((image) => image.url), [
        Uri.parse('https://books.test/images/wanted.jpg'),
      ]);
    },
  );

  test(
    'keeps commas in ordinary image URLs and selects real srcset candidates',
    () async {
      final runtime = SourceRuntime(
        transport: _ComicTransport({
          'https://books.test/chapter/1': SourceResponse(
            body: '''
            <main>
              <img src="/images/a,b.jpg">
              <img srcset="/images/one.jpg 1x, /images/two.jpg 2x">
              <img srcset="/images/plain-one.jpg, /images/plain-two.jpg">
              <img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
                   data-src="/images/lazy.jpg">
            </main>
          ''',
            finalUri: Uri.parse('https://books.test/chapter/1'),
          ),
        }),
      );
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _comicSource(content: 'main@html'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.images.map((image) => image.url), [
        Uri.parse('https://books.test/images/a,b.jpg'),
        Uri.parse('https://books.test/images/one.jpg'),
        Uri.parse('https://books.test/images/plain-one.jpg'),
        Uri.parse('https://books.test/images/lazy.jpg'),
      ]);
    },
  );
}

RegisteredBookSource _comicSource({
  required String content,
  String? nextContentUrl,
  String? replaceRegex,
  Map<String, String>? headers,
}) => ReadingSourceConfig.fromJson({
  'bookSourceName': 'Comic compatibility test',
  'bookSourceUrl': 'https://books.test',
  'bookSourceType': 2,
  'header': ?headers,
  'ruleContent': {
    'content': content,
    'nextContentUrl': ?nextContentUrl,
    'replaceRegex': ?replaceRegex,
    'imageStyle': 'FULL',
  },
}).toRegisteredSource(enabled: true);

class _ComicTransport implements SourceTransport {
  _ComicTransport(this.responses);

  final Map<String, SourceResponse> responses;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async =>
      responses[request.url.toString()] ??
      (throw StateError('Missing fake response for ${request.url}'));
}

class _ComicEvaluator implements SourceScriptEvaluator {
  final calls = <String>[];

  @override
  Object? evaluate(String script, SourceScriptContext context) {
    calls.add(script);
    context.loginHeaderWriter?.call({'Referer': 'https://updated.test/'});
    return '/images/1.jpg\n/images/2.jpg\n'
        '/images/3.jpg, {"headers":{"Cookie":"a=1; b=2"}}';
  }

  @override
  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  @override
  void dispose() {}
}

class _MemoryLoginSessionStore implements SourceLoginSessionStore {
  SourceLoginSession value = const SourceLoginSession();

  @override
  Future<void> clear(String sourceId) async {
    value = const SourceLoginSession();
  }

  @override
  Future<SourceLoginSession> read(String sourceId) async => value;

  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    value = session;
  }
}
