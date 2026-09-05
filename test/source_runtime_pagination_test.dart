import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'collects a fixed next-page list in order without expanding child pages',
    () async {
      final transport = _PageTransport({
        'https://books.test/chapter/1': _response('''
        <main>first</main>
        <a class="page" href="mailto:invalid@example.com">invalid</a>
        <a class="page" href="http://[">malformed</a>
        <a class="page" href="/page/2,{&quot;headers&quot;:{&quot;X-Page&quot;:&quot;two&quot;}}">2</a>
        <a class="page" href="/page/2">duplicate</a>
        <a class="page" href="/page/3">3</a>
      ''', 'https://books.test/chapter/1'),
        'https://books.test/page/2': _response('''
        <main>second</main><a class="page" href="/ignored">ignored</a>
      ''', 'https://cdn.test/final/2'),
        'https://books.test/page/3': _response(
          '<main>third</main>',
          'https://cdn.test/final/2',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(nextContentUrl: 'a.page@href'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.content, contains('first'));
      expect(content.content, contains('second'));
      expect(content.content, isNot(contains('third')));
      expect(transport.requests.map((request) => request.url.toString()), [
        'https://books.test/chapter/1',
        'https://books.test/page/2',
        'https://books.test/page/3',
      ]);
      expect(transport.requests[1].headers['X-Page'], 'two');
      expect(
        transport.requests,
        isNot(
          contains(
            predicate<SourceRequestTemplate>(
              (request) => request.url.path == '/ignored',
            ),
          ),
        ),
      );
    },
  );

  test(
    'follows a single pagination chain and stops before the next chapter',
    () async {
      final transport = _PageTransport({
        'https://books.test/book/1': _response('''
        <h1>Book</h1><ul id="chapters">
          <li><a href="/chapter/1">One</a></li>
          <li><a href="/chapter/2,{&quot;headers&quot;:{&quot;X-Chapter&quot;:&quot;catalog&quot;}}">Two</a></li>
        </ul>
      ''', 'https://books.test/book/1'),
        'https://books.test/chapter/1': _response(
          '<main>first</main><a class="next" href="/page/2">next</a>',
          'https://books.test/chapter/1',
        ),
        'https://books.test/page/2': _response(
          '<main>second</main><a class="next" href="/chapter/2,{&quot;headers&quot;:{&quot;X-Chapter&quot;:&quot;content&quot;}}">next chapter</a>',
          'https://books.test/page/2',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);
      final source = _source(nextContentUrl: 'a.next@href', withCatalog: true);
      final chapters = await runtime.getChapters(
        source,
        'https://books.test/book/1',
      );

      final content = await runtime.getChapterContent(
        source,
        bookId: 'https://books.test/book/1',
        chapterId: chapters.first.id,
      );

      expect(content.content, contains('first'));
      expect(content.content, contains('second'));
      expect(
        transport.requests.where(
          (request) => request.url.toString() == 'https://books.test/chapter/2',
        ),
        isEmpty,
      );
    },
  );

  test('does not refetch a page when only its request options change', () async {
    final transport = _PageTransport({
      'https://books.test/chapter/1': _response(
        '<main>first</main>'
            '<a class="next" href="/chapter/1,{&quot;headers&quot;:{&quot;X-Loop&quot;:&quot;changed&quot;}}">self</a>',
        'https://books.test/chapter/1',
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(nextContentUrl: 'a.next@href'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.content, contains('first'));
    expect(transport.requests, hasLength(1));
  });

  test('caps a chained chapter at twenty fetched pages', () async {
    final responses = <String, SourceResponse>{};
    for (var page = 1; page <= 25; page++) {
      responses['https://books.test/page/$page'] = _response(
        '<main>page $page</main>'
            '<a class="next" href="/page/${page + 1}">next</a>',
        'https://books.test/page/$page',
      );
    }
    final transport = _PageTransport(responses);
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(nextContentUrl: 'a.next@href'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/page/1',
    );

    expect(transport.requests, hasLength(20));
    expect(content.content, contains('page 20'));
    expect(content.content, isNot(contains('page 21')));
  });

  test('fetches fixed pages four at a time and preserves rule order', () async {
    final responses = <String, SourceResponse>{
      'https://books.test/chapter/1': _response(
        '<main>first</main>${List.generate(8, (i) => '<a class="page" href="/fixed/${i + 1}">${i + 1}</a>').join()}',
        'https://books.test/chapter/1',
      ),
      for (var page = 1; page <= 8; page++)
        'https://books.test/fixed/$page': _response(
          '<main>fixed $page</main>',
          'https://books.test/fixed/$page',
        ),
    };
    final transport = _PageTransport(
      responses,
      delayFor: (url) =>
          Duration(milliseconds: (9 - int.parse(url.pathSegments.last)) * 3),
    );
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(nextContentUrl: 'a.page@href'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(transport.maxConcurrent, 4);
    var previous = -1;
    for (var page = 1; page <= 8; page++) {
      final index = content.content.indexOf('fixed $page');
      expect(index, greaterThan(previous));
      previous = index;
    }
  });

  test(
    'captures an early prefetched failure and rethrows it in page order',
    () async {
      final transport = _PageTransport(
        {
          'https://books.test/chapter/1': _response(
            '<main>first</main>${List.generate(5, (i) => '<a class="page" href="/fail/${i + 1}">${i + 1}</a>').join()}',
            'https://books.test/chapter/1',
          ),
          for (final page in const [1, 3, 5])
            'https://books.test/fail/$page': _response(
              '<main>page $page</main>',
              'https://books.test/fail/$page',
            ),
        },
        delayFor: (url) => url.path.endsWith('/1')
            ? const Duration(milliseconds: 30)
            : Duration.zero,
      );
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      await expectLater(
        runtime.getChapterContent(
          _source(nextContentUrl: 'a.page@href'),
          bookId: 'https://books.test/book/1',
          chapterId: 'https://books.test/chapter/1',
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'applies text replaceRegex after pages and subContent are joined',
    () async {
      final transport = _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main>start REMOVE</main><aside>bad note</aside><a class="next" href="/page/2">next</a>',
          'https://books.test/chapter/1',
        ),
        'https://books.test/page/2': _response(
          '<main>ME end</main>',
          'https://books.test/page/2',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(
          nextContentUrl: 'a.next@href',
          subContent: 'aside@text',
          replaceRegex: r'REMOVE[\s\S]*ME|bad',
        ),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.content, isNot(contains('REMOVE')));
      expect(content.content, isNot(contains('ME')));
      expect(content.content, isNot(contains('bad')));
      expect(content.content, contains('note'));
    },
  );

  test(
    'rebuilds text images after replacement with each page response base',
    () async {
      final transport = _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main><img src="keep-1.jpg"><img class="blocked" src="gone.jpg"></main>'
              '<a class="next" href="/page/2">next</a>',
          'https://cdn-one.test/a/index.html',
        ),
        'https://cdn-one.test/page/2': _response(
          '<main><img src="keep-2.jpg"></main>',
          'https://cdn-two.test/b/index.html',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(
          nextContentUrl: 'a.next@href',
          replaceRegex: r'<img class="blocked"[^>]*>',
        ),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.images.map((image) => image.url), [
        Uri.parse('https://cdn-one.test/a/keep-1.jpg'),
        Uri.parse('https://cdn-two.test/b/keep-2.jpg'),
      ]);
    },
  );

  test('removes an image deleted by a cross-page replacement', () async {
    final transport = _PageTransport({
      'https://books.test/chapter/1': _response(
        '<main>REMOVE<img src="gone.jpg"></main>'
            '<a class="next" href="/page/2">next</a>',
        'https://cdn-one.test/a/index.html',
      ),
      'https://cdn-one.test/page/2': _response(
        '<main>ME<img src="keep.jpg"></main>',
        'https://cdn-two.test/b/index.html',
      ),
    });
    final runtime = SourceRuntime(transport: transport);
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(nextContentUrl: 'a.next@href', replaceRegex: r'REMOVE[\s\S]*ME'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.images.map((image) => image.url), [
      Uri.parse('https://cdn-two.test/b/keep.jpg'),
    ]);
  });

  test(
    'keeps the correct base when identical relative images are removed',
    () async {
      final transport = _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main>REMOVE<img src="page.jpg">END</main>'
              '<a class="next" href="/page/2">next</a>',
          'https://cdn-one.test/a/index.html',
        ),
        'https://cdn-one.test/page/2': _response(
          '<main><img src="page.jpg"></main>',
          'https://cdn-two.test/b/index.html',
        ),
      });
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(
          nextContentUrl: 'a.next@href',
          replaceRegex: r'REMOVE[\s\S]*?END',
        ),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(content.images.map((image) => image.url), [
        Uri.parse('https://cdn-two.test/b/page.jpg'),
      ]);
    },
  );

  test('resolves an image URL rewritten by replaceRegex', () async {
    final runtime = SourceRuntime(
      transport: _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main><img src="old.jpg"></main>',
          'https://cdn.test/chapter/index.html',
        ),
      }),
    );
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(replaceRegex: r'old\.jpg##new.jpg'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
    );

    expect(content.images.map((image) => image.url), [
      Uri.parse('https://cdn.test/chapter/new.jpg'),
    ]);
  });

  test(
    'appends first-page subContent and remote subContent for text sources',
    () async {
      final localTransport = _PageTransport({
        'https://books.test/chapter/1': _response('''
        <main>body</main><aside>first note</aside>
        <a class="next" href="/page/2">next</a>
      ''', 'https://books.test/chapter/1'),
        'https://books.test/page/2': _response(
          '<main>page two</main><aside>child note</aside>',
          'https://books.test/page/2',
        ),
      });
      final localRuntime = SourceRuntime(transport: localTransport);
      addTearDown(localRuntime.close);

      final local = await localRuntime.getChapterContent(
        _source(nextContentUrl: 'a.next@href', subContent: 'aside@text'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(local.content, contains('first note'));
      expect(local.content, isNot(contains('child note')));

      final remoteTransport = _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main>body</main><a class="sub" href="https://books.test/notes/1">note</a>',
          'https://books.test/chapter/1',
        ),
        'https://books.test/notes/1': _response(
          'remote note',
          'https://books.test/notes/1',
        ),
      });
      final remoteRuntime = SourceRuntime(transport: remoteTransport);
      addTearDown(remoteRuntime.close);
      final remote = await remoteRuntime.getChapterContent(
        _source(subContent: 'a.sub@href'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
      );

      expect(remote.content, contains('remote note'));
    },
  );

  test(
    'uses ruleContent title from the first page after reading content',
    () async {
      final runtime = SourceRuntime(
        transport: _PageTransport({
          'https://books.test/chapter/1': _response(
            '<h1>Updated titlehttps://images.test/review.png</h1><main>body</main>',
            'https://books.test/chapter/1',
          ),
        }),
      );
      addTearDown(runtime.close);

      final content = await runtime.getChapterContent(
        _source(title: 'h1@text'),
        bookId: 'https://books.test/book/1',
        chapterId: 'https://books.test/chapter/1',
        sourceVariables: const {'chapterTitle': 'Old title'},
      );

      expect(content.title, 'Updated title');
    },
  );

  test('keeps chapter content when optional title evaluation fails', () async {
    final runtime = SourceRuntime(
      transport: _PageTransport({
        'https://books.test/chapter/1': _response(
          '<main>body survives</main>',
          'https://books.test/chapter/1',
        ),
      }),
    );
    addTearDown(runtime.close);

    final content = await runtime.getChapterContent(
      _source(title: '@js:throw new Error("broken title")'),
      bookId: 'https://books.test/book/1',
      chapterId: 'https://books.test/chapter/1',
      sourceVariables: const {'chapterTitle': 'Original title'},
    );

    expect(content.content, contains('body survives'));
    expect(content.title, 'Original title');
  });
}

RegisteredBookSource _source({
  String? nextContentUrl,
  String? subContent,
  String? title,
  String? replaceRegex,
  bool withCatalog = false,
}) => ReadingSourceConfig.fromJson({
  'bookSourceName': 'Pagination test',
  'bookSourceUrl': 'https://books.test',
  if (withCatalog) 'ruleBookInfo': {'name': 'h1@text'},
  if (withCatalog)
    'ruleToc': {
      'chapterList': '#chapters@li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
  'ruleContent': {
    'content': 'main@html',
    'nextContentUrl': ?nextContentUrl,
    'subContent': ?subContent,
    'title': ?title,
    'replaceRegex': ?replaceRegex,
  },
}).toRegisteredSource(enabled: true);

SourceResponse _response(String body, String finalUrl) =>
    SourceResponse(body: body, finalUri: Uri.parse(finalUrl));

class _PageTransport implements SourceTransport {
  _PageTransport(this.responses, {this.delayFor});

  final Map<String, SourceResponse> responses;
  final Duration Function(Uri url)? delayFor;
  final List<SourceRequestTemplate> requests = [];
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      final delay = delayFor?.call(request.url);
      if (delay != null) await Future<void>.delayed(delay);
      return responses[request.url.toString()] ??
          (throw StateError('Missing fake response for ${request.url}'));
    } finally {
      concurrent--;
    }
  }
}
