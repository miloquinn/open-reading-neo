import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_network_policy.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SourceRequestTemplate', () {
    test('parses variables and limited POST options', () {
      final request = SourceRequestTemplate.parse(
        '/search,{"method":"POST","body":"q={{key}}&p={{page}}",'
        '"charset":"GBK","headers":{"Referer":"https://books.test/"}}',
        baseUri: Uri.parse('https://books.test/root/'),
        variables: const {'key': '剑 来', 'page': '2'},
      );

      expect(request.url, Uri.parse('https://books.test/search'));
      expect(request.method, SourceRequestMethod.post);
      expect(request.body, 'q=%E5%89%91+%E6%9D%A5&p=2');
      expect(request.charset, 'gbk');
      expect(request.headers['User-Agent'], sourceDefaultUserAgent);
      expect(request.headers['Referer'], 'https://books.test/');
      expect(
        request.headers['Content-Type'],
        'application/x-www-form-urlencoded; charset=gbk',
      );
    });

    test('expands native source header variables before requests', () async {
      final transport = _FakeTransport({
        'https://books.test/search?q=test&page=1': '''
          <div class="book">
            <a href="/book/1"><span class="name">书名</span></a>
          </div>
        ''',
      });
      final raw = Map<String, dynamic>.from(_htmlSource().raw)
        ..['header'] = '{"Referer":"{{source.getKey()}}"}';
      final runtime = SourceRuntime(transport: transport);

      await runtime.search(
        ReadingSourceConfig.fromJson(raw).toRegisteredSource(enabled: true),
        'test',
      );

      expect(
        transport.requests.single.headers['Referer'],
        'https://books.test',
      );
    });

    test(
      'replays synchronous script network calls through source transport',
      () async {
        final transport = _FakeTransport({
          'https://books.test/token': 'abc',
          'https://books.test/search?q=test&token=abc': '''
          <div class="book">
            <a href="/book/1"><span class="name">Network Book</span></a>
          </div>
        ''',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['searchUrl'] =
              "@js:'/search?q=' + key + '&token=' + java.ajax('/token')";
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);

        final page = await runtime.search(
          ReadingSourceConfig.fromJson(raw).toRegisteredSource(enabled: true),
          'test',
        );

        expect(page.items.single.title, 'Network Book');
        expect(transport.requests.map((request) => request.url.toString()), [
          'https://books.test/token',
          'https://books.test/search?q=test&token=abc',
        ]);
      },
    );

    test('injects stored login headers into source requests', () async {
      final transport = _FakeTransport({
        'https://books.test/search?q=test&page=1': '''
          <div class="book"><a href="/book/1"><span class="name">书名</span></a></div>
        ''',
      });
      final source = _htmlSource().toRegisteredSource(enabled: true);
      final store = _MemoryLoginSessionStore();
      await store.write(
        source.id,
        const SourceLoginSession(
          loginHeaders: {'Authorization': 'Bearer token'},
        ),
      );
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: store,
      );

      await runtime.search(source, 'test');

      expect(
        transport.requests.single.headers['Authorization'],
        'Bearer token',
      );
    });

    test(
      'login check can update response and persist source login info',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=test&page=1': '<p>login required</p>',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['loginCheckJs'] = '''
          var info = source.getLoginInfoMap();
          info.put('checked', 'yes');
          source.putLoginInfo(info);
          ({
            body: '<div class="book"><a href="/book/1"><span class="name">已登录</span></a></div>',
            finalUrl: result.url(),
            statusCode: 200,
            headers: result.headers(),
            cookies: result.cookies()
          });
        ''';
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final store = _MemoryLoginSessionStore();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: store,
        );

        final page = await runtime.search(source, 'test');

        expect(page.items.single.title, '已登录');
        expect((await store.read(source.id)).loginInfo['checked'], 'yes');
      },
    );

    test(
      'parses login fields and executes the source login function',
      () async {
        final transport = _FakeTransport({
          'https://books.test/session': 'token-ready',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['enabledCookieJar'] = true
          ..['loginUi'] = jsonEncode([
            {
              'name': 'account',
              'type': 'text',
              'viewName': '账号',
              'default': 'guest',
            },
            {'name': 'password', 'type': 'password', 'viewName': '密码'},
          ])
          ..['loginUrl'] = '''
          function login() {
            var info = source.getLoginInfoMap();
            var token = java.ajax('/session') + ':' + info.get('account');
            source.putLoginHeader(JSON.stringify({
              'Authorization': 'Bearer ' + token,
              'Cookie': 'sid=' + token
            }));
          }
        ''';
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final store = _MemoryLoginSessionStore();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: store,
        );

        final fields = await runtime.loadLoginFields(source);
        expect(fields.map((field) => field.name), ['account', 'password']);
        expect(fields.first.defaultValue, 'guest');

        await runtime.login(source, const {
          'account': 'reader',
          'password': 'secret',
        });

        final session = await store.read(source.id);
        expect(session.loginInfo, {'account': 'reader', 'password': 'secret'});
        expect(
          session.loginHeaders['Authorization'],
          'Bearer token-ready:reader',
        );
      },
    );

    test('accepts non-executable single-quoted legacy options', () {
      final request = SourceRequestTemplate.parse(
        "/search,{'method':'POST','body':'q={{key}}','charset':'gbk'}",
        baseUri: Uri.parse('https://books.test/'),
        variables: const {'key': '剑来'},
      );

      expect(request.method, SourceRequestMethod.post);
      expect(request.charset, 'gbk');
      expect(request.body, 'q=%E5%89%91%E6%9D%A5');
    });

    test('accepts a bare User-Agent in legacy request options', () {
      final request = SourceRequestTemplate.parse(
        '/search,{"method":"POST","body":"q={{key}}",'
        '"headers":"ExampleBrowser/1.0"}',
        baseUri: Uri.parse('https://books.test/'),
        variables: const {'key': 'test'},
      );

      expect(request.headers['User-Agent'], 'ExampleBrowser/1.0');
    });

    test('preserves background-browser request options', () {
      final request = SourceRequestTemplate.parse(
        "/search,{'webView':true,'webJs':'document.body.dataset.ready=1'}",
        baseUri: Uri.parse('https://books.test/'),
      );

      expect(request.useWebView, isTrue);
      expect(request.webJs, 'document.body.dataset.ready=1');
    });

    test('rejects unsupported methods and sensitive headers', () {
      expect(
        () => SourceRequestTemplate.parse(
          '/,{"method":"PUT"}',
          baseUri: Uri.parse('https://books.test'),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(
        SourceRequestTemplate.parse(
          '/search?offset={{(page-1)*20}}',
          baseUri: Uri.parse('https://books.test'),
          variables: const {'page': '2'},
        ).url,
        Uri.parse('https://books.test/search?offset=20'),
      );
      expect(
        () => SourceRequestTemplate.parse(
          '/,{"headers":{"Content-Length":"123"}}',
          baseUri: Uri.parse('https://books.test'),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
      final withCookie = SourceRequestTemplate.parse(
        '/',
        baseUri: Uri.parse('https://books.test'),
        sourceHeaders: const {'Cookie': 'session=source'},
      );
      expect(withCookie.headers['Cookie'], 'session=source');
      final virtualHost = SourceRequestTemplate.parse(
        '/',
        baseUri: Uri.parse('https://203.0.113.8'),
        sourceHeaders: const {'Host': 'books.test'},
      );
      expect(virtualHost.headers['Host'], 'books.test');
      expect(
        () => SourceRequestTemplate.parse(
          '/',
          baseUri: Uri.parse('https://203.0.113.8'),
          sourceHeaders: const {'Host': 'books.test\r\nX-Test: injected'},
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
    });

    test('accepts HEAD without a body', () {
      final request = SourceRequestTemplate.parse(
        '/probe,{"method":"HEAD"}',
        baseUri: Uri.parse('https://books.test'),
      );

      expect(request.method, SourceRequestMethod.head);
      expect(request.body, isNull);
    });
  });

  group('SourceRuleEngine', () {
    const engine = SourceRuleEngine();

    test(
      'supports legacy DOM rules, CSS, fallback, concatenate and replace',
      () {
        final document = SourceRuleDocument.parse(
          '<ul class="books">'
          '<li><a href="/1"><b>第一本</b></a><span>甲</span></li>'
          '<li><a href="/2"><b>第二本</b></a><span>乙</span></li>'
          '</ul>',
          Uri.parse('https://books.test/search'),
        );
        final items = engine.evaluateList(
          document,
          document.value,
          'class.books@li!0',
        );

        expect(items, hasLength(1));
        expect(
          engine.evaluateString(
            document,
            items.single,
            '.missing@text||a@b@text',
          ),
          '第二本',
        );
        expect(
          engine.evaluateString(
            document,
            items.single,
            'a@text&&span@text##第二##第 2###',
          ),
          '第 2本乙',
        );
        expect(
          engine.evaluateString(
            document,
            items.single,
            'a@href',
            resolveUrl: true,
          ),
          'https://books.test/2',
        );
      },
    );

    test('supports whitespace-separated legacy class names', () {
      final document = SourceRuleDocument.parse(
        '<div class="alpha beta">Matched</div>',
        Uri.parse('https://books.test/'),
      );

      expect(
        engine.evaluateString(
          document,
          document.value,
          'class. alpha beta@text',
        ),
        'Matched',
      );
    });

    test('supports reading-source interleaving and bracket indexes', () {
      final document = SourceRuleDocument.parse(
        '<ul class="left"><li>L1</li><li>L2</li><li>L3</li></ul>'
        '<ul class="right"><li>R1</li><li>R2</li><li>R3</li></ul>',
        Uri.parse('https://books.test/'),
      );

      expect(
        engine.evaluateString(
          document,
          document.value,
          'class.left@li[0:1]@text%%class.right@li[1:2]@text',
        ),
        'L1R2L2R3',
      );
      expect(
        engine.evaluateString(
          document,
          document.value,
          'class.left@li[!1]@text',
        ),
        'L1L3',
      );
      expect(
        engine.evaluateString(
          document,
          document.value,
          'class.left@li[-1:0]@text',
        ),
        'L3L2L1',
      );
    });

    test('supports reading-source all and direct text node terminals', () {
      final document = SourceRuleDocument.parse(
        '<section><p>first <b>bold</b> tail</p><p>second</p></section>',
        Uri.parse('https://books.test/'),
      );

      expect(
        engine.evaluateString(
          document,
          document.value,
          'section@p.0@textNodes',
        ),
        'first\ntail',
      );
      expect(
        engine.evaluateString(document, document.value, 'section@p@all'),
        '<p>first <b>bold</b> tail</p><p>second</p>',
      );
    });

    test('supports basic JSON properties, indexes, wildcard and templates', () {
      final document = SourceRuleDocument.parse(
        '{"books":[{"id":7,"title":"山海"}]}',
        Uri.parse('https://api.test/'),
      );
      final books = engine.evaluateList(
        document,
        document.value,
        r'$.books[*]',
      );

      expect(books, hasLength(1));
      expect(engine.evaluateString(document, books.single, r'$.title'), '山海');
      expect(
        engine.evaluateString(
          document,
          document.value,
          r'@json:$.books[0].title',
        ),
        '山海',
      );
      expect(
        engine.evaluateString(
          document,
          books.single,
          r'/books/{{$.id}}',
          resolveUrl: true,
        ),
        'https://api.test/books/7',
      );
    });

    test('supports recursive and filtered reading source JSONPath rules', () {
      final document = SourceRuleDocument.parse(
        '{"data":{"books":['
        '{"title":"旧书","score":5},'
        '{"title":"好书","score":9}'
        ']}}',
        Uri.parse('https://api.test/'),
      );

      expect(
        engine
            .evaluateList(
              document,
              document.value,
              r'$..books[?(@.score >= 8)]',
            )
            .map((book) => engine.evaluateString(document, book, r'$.title')),
        ['好书'],
      );
      expect(
        engine.evaluateString(document, document.value, r'$..title'),
        '旧书好书',
      );
    });

    test(
      'supports CSS attributes, text lookup and regex capture replacement',
      () {
        final document = SourceRuleDocument.parse(
          '<meta property="og:novel:author" content="甲">'
          '<meta property="og:novel:category" content="玄幻">'
          '<meta property="og:novel:status" content="连载中">'
          '<meta property="og:novel:update_time" content="今天">'
          '<meta property="og:novel:title" content="书名">'
          '<p data-author="作者：乙<">正文</p><a href="/next">下一页</a>',
          Uri.parse('https://books.test/chapter'),
        );

        expect(
          engine.evaluateString(
            document,
            document.value,
            '[property="og:novel:author"]@content',
          ),
          '甲',
        );
        expect(
          engine.evaluateList(
            document,
            document.value,
            r'[property~=category|status|time]@content',
          ),
          ['玄幻', '连载中', '今天'],
        );
        expect(
          engine.evaluateString(
            document,
            document.value,
            'text.下一页@href',
            resolveUrl: true,
          ),
          'https://books.test/next',
        );
        final paragraph = engine
            .evaluateList(document, document.value, 'p')
            .single;
        expect(
          engine.evaluateString(
            document,
            paragraph,
            r'data-author##作者：([^<]+)<##$1###',
          ),
          '乙',
        );
      },
    );

    test('supports common XPath attributes, predicates, and sibling axes', () {
      final document = SourceRuleDocument.parse('''
        <html><head>
          <meta property="og:title" content="XPath Book">
        </head><body>
          <a class="start" href="/start">Start Reading</a>
          <ul><li><span>one</span><a href="/c1">One</a></li></ul>
          <div id="list"><dt>volume</dt><dt>chapters</dt>
            <dd><a href="/c2">Two</a></dd><dd><a href="/c3">Three</a></dd>
          </div>
        </body></html>
        ''', Uri.parse('https://books.test/book/1'));

      expect(
        engine.evaluateString(
          document,
          null,
          '//meta[@property="og:title"]/@content',
        ),
        'XPath Book',
      );
      expect(
        engine.evaluateString(
          document,
          null,
          '//a[text()="Start Reading"]/@href',
          resolveUrl: true,
        ),
        'https://books.test/start',
      );
      final siblingLinks = engine.evaluateList(
        document,
        null,
        '//*[@id="list"]//dt[2]/following-sibling::dd/a',
      );
      expect(
        siblingLinks.map(
          (item) => engine.evaluateString(document, item, 'text'),
        ),
        ['Two', 'Three'],
      );
      expect(engine.evaluateList(document, null, '//li[span]/a'), hasLength(1));
    });

    test('accepts explicit and additive CSS prefixes', () {
      final document = SourceRuleDocument.parse(
        '<ul class="librarylist"><li><a class="name">Book</a></li></ul>',
        Uri.parse('https://books.test'),
      );

      expect(
        engine.evaluateList(document, null, '+@css:.librarylist li'),
        hasLength(1),
      );
      expect(engine.evaluateString(document, null, '@css:.name@text'), 'Book');
    });

    test('joins content nodes by line before applying cleanup rules', () async {
      final document = SourceRuleDocument.parse(
        '<section id="Context"><article>'
        '<p>Chapter One</p><p>Readable body</p>'
        '</article></section>',
        Uri.parse('https://books.test/chapter/1'),
      );

      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          'id.Context@article@p@html##Chapter.*',
          joinSeparator: '\n',
          regexDotAll: false,
        ),
        'Readable body',
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          r'id.Context@article@p@html##Chapter[\s\S]*',
          joinSeparator: '\n',
          regexDotAll: false,
        ),
        isEmpty,
      );
    });

    test('supports staged regex lists and numbered capture fields', () {
      final document = SourceRuleDocument.parse(
        '<h2>章节目录</h2><ul>'
        '<li><a href="/1">第一章</a></li>'
        '<li><a href="/2">第二章</a></li></ul>',
        Uri.parse('https://books.test/book'),
      );
      final chapters = engine.evaluateList(
        document,
        null,
        r':章节目录</h2>[\s\S]*?/ul&&href="([^"]*)"[^>]*>([^<]*)',
      );

      expect(chapters, hasLength(2));
      expect(engine.evaluateString(document, chapters.first, r'$2'), '第一章');
      expect(
        engine.evaluateString(
          document,
          chapters.first,
          r'$1',
          resolveUrl: true,
        ),
        'https://books.test/1',
      );
    });

    test('stores and reads source rule state with put/get syntax', () {
      final document = SourceRuleDocument.parse(
        '{"id":7,"author":"Alice"}',
        Uri.parse('https://books.test/'),
      );

      expect(
        engine.evaluateString(
          document,
          document.value,
          r'$.author@put:{gid:$.id}',
        ),
        'Alice',
      );
      expect(
        engine.evaluateString(
          document,
          document.value,
          '/book/@get:{gid}',
          resolveUrl: true,
        ),
        'https://books.test/book/7',
      );
    });
  });

  group('SourceRuntime', () {
    test(
      'normalizes the complete text reading chain to protocol DTOs',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=%E5%89%91%E6%9D%A5&page=1': '''
          <div class="book">
            <a href="/book/1"><span class="name">剑来</span></a>
            <span class="author">烽火</span>
            <span class="kind">玄幻|连载</span>
            <img src="/cover/1.jpg">
          </div>
        ''',
          'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <p class="intro">少年远游。</p><a class="toc" href="/book/1/toc">目录</a>
        ''',
          'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
          'https://books.test/chapter/1': '''
          <article id="content"><p>正文</p><div class="ad">广告</div></article>
        ''',
        });
        final source = _htmlSource().toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);

        final search = await runtime.search(source, '剑来');
        expect(search.items.single.id, 'https://books.test/book/1');
        expect(search.items.single.title, '剑来');
        expect(search.items.single.author, '烽火');
        expect(search.items.single.categories, ['玄幻', '连载']);
        expect(
          search.items.single.coverUrl,
          Uri.parse('https://books.test/cover/1.jpg'),
        );

        final book = await runtime.getBook(source, search.items.single.id);
        expect(book.description, '少年远游。');
        final chapters = await runtime.getChapters(source, book.id);
        expect(chapters.single.title, '第一章');
        expect(chapters.single.id, 'https://books.test/chapter/1');
        final content = await runtime.getChapterContent(
          source,
          bookId: book.id,
          chapterId: chapters.single.id,
        );
        expect(content.content, '<p>正文</p>');
        expect(content.contentType, 'text/html');
      },
    );

    test(
      'preserves remote image request headers and chapter image pages',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=art&page=1': '''
          <div class="book">
            <a href="/book/1"><span class="name">Art Book</span></a>
            <img src="//cdn.test/cover.jpg,{headers:{referer:'https://books.test/'}}">
          </div>
        ''',
          'https://books.test/chapter/1': '''
          <article>
            <img src="//cdn.test/1.jpg,{headers:{Referer:'https://books.test/'}}">
            <img data-src="/images/2.jpg">
          </article>
        ''',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['ruleContent'] = {'content': 'article@html'};
        final source = ReadingSourceConfig.fromJson(raw).toRegisteredSource();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: _MemoryLoginSessionStore(),
        );
        addTearDown(runtime.close);

        final search = await runtime.search(source, 'art');
        final content = await runtime.getChapterContent(
          source,
          bookId: search.items.single.id,
          chapterId: 'https://books.test/chapter/1',
        );

        expect(
          search.items.single.coverUrl,
          Uri.parse('https://cdn.test/cover.jpg'),
        );
        expect(search.items.single.coverHeaders, {
          'referer': 'https://books.test/',
        });
        expect(content.images.map((image) => image.url), [
          Uri.parse('https://cdn.test/1.jpg'),
          Uri.parse('https://books.test/images/2.jpg'),
        ]);
        expect(content.images.first.headers, {
          'Referer': 'https://books.test/',
        });
      },
    );

    test('supports a basic JSON source end to end', () async {
      final transport = _FakeTransport({
        'https://api.test/search?q=%E5%B1%B1%E6%B5%B7':
            '{"books":[{"id":7,"title":"山海","author":"甲"}]}',
        'https://api.test/books/7':
            '{"id":7,"title":"山海","author":"甲","toc":"/toc/7"}',
        'https://api.test/toc/7': '{"chapters":[{"id":9,"title":"开篇"}]}',
        'https://api.test/content/9': '{"body":"第一段\\n第二段"}',
      });
      final source = _jsonSource().toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(transport: transport);

      final result = await runtime.search(source, '山海');
      final book = await runtime.getBook(source, result.items.single.id);
      final chapters = await runtime.getChapters(source, book.id);
      final content = await runtime.getChapterContent(
        source,
        bookId: book.id,
        chapterId: chapters.single.id,
      );
      expect(book.title, '山海');
      expect(chapters.single.title, '开篇');
      expect(content.content, '第一段\n第二段');
    });

    test(
      'carries book variables into catalog URLs and preserves request options',
      () async {
        final transport = _FakeTransport({
          'https://api.test/search?q=variable':
              '{"books":[{"id":7,"title":"Variable Book"}]}',
          'https://api.test/books/7':
              '{"data":[{"id":7,"title":"Variable Book"}]}',
          'https://api.test/books/7/chapters':
              '{"chapters":[{"id":9,"title":"Chapter One"}]}',
          'https://reader.test/chapter/7/9.html':
              '<section id="Context"><article>'
              '<p>Chapter One</p><p>Readable body</p>'
              '</article></section>',
        });
        final source = ReadingSourceConfig.fromJson({
          'bookSourceName': 'Variable source',
          'bookSourceUrl': 'https://api.test',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {
            'bookList': r'$.books[*]',
            'name': r'$.title@put:{book:$.id}',
            'bookUrl': r'/books/{{$.id}}',
          },
          'ruleBookInfo': {
            'init': r'$.data[0]',
            'name': r'$.title',
            'tocUrl': '/books/@get:{book}/chapters',
          },
          'ruleToc': {
            'chapterList': r'$.chapters[*]',
            'chapterName': r'$.title',
            'chapterUrl':
                "https://reader.test/chapter/@get:{book}/{{\$.id}}.html,{'webView': true}",
          },
          'ruleContent': {'content': 'id.Context@article@p@html##Chapter.*'},
        }).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);

        final summary = (await runtime.search(source, 'variable')).items.single;
        final book = await runtime.getBook(
          source,
          summary.id,
          sourceVariables: summary.sourceVariables,
        );
        final chapters = await runtime.getChapters(
          source,
          book.id,
          sourceVariables: book.sourceVariables,
        );
        final content = await runtime.getChapterContent(
          source,
          bookId: book.id,
          chapterId: chapters.single.id,
          sourceVariables: book.sourceVariables,
        );

        expect(summary.sourceVariables, {'book': '7'});
        expect(book.sourceVariables, {'book': '7'});
        expect(
          chapters.single.id,
          "https://reader.test/chapter/7/9.html,{'webView': true}",
        );
        expect(
          transport.requests.last.url.toString(),
          'https://reader.test/chapter/7/9.html',
        );
        expect(transport.requests.last.useWebView, isTrue);
        expect(content.content, 'Readable body');

        final reopenedTransport = _FakeTransport({
          'https://api.test/books/7':
              '{"data":[{"id":7,"title":"Variable Book"}]}',
          'https://api.test/books/7/chapters':
              '{"chapters":[{"id":9,"title":"Chapter One"}]}',
          'https://reader.test/chapter/7/9.html':
              '<section id="Context"><article>'
              '<p>Chapter One</p><p>Readable after reopen</p>'
              '</article></section>',
        });
        final reopenedRuntime = SourceRuntime(transport: reopenedTransport);
        final reopenedChapters = await reopenedRuntime.getChapters(
          source,
          book.id,
        );
        final reopenedContent = await reopenedRuntime.getChapterContent(
          source,
          bookId: book.id,
          chapterId: reopenedChapters.single.id,
        );

        expect(reopenedChapters.single.id, chapters.single.id);
        expect(reopenedTransport.requests.last.useWebView, isTrue);
        expect(reopenedContent.content, 'Readable after reopen');
      },
    );

    test('decodes data-wrapped book and chapter targets', () async {
      final transport = _FakeTransport({
        'https://books.test/book/7': '<h1>Wrapped Book</h1>',
        'https://books.test/toc/7':
            '<ul><li><a href="data:;base64,aHR0cHM6Ly9ib29rcy50ZXN0L2NoYXB0ZXIvMQ==">One</a></li></ul>',
        'https://books.test/chapter/1': '<article>Readable body</article>',
      });
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: _MemoryLoginSessionStore(),
      );
      addTearDown(runtime.close);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Wrapped source',
        'bookSourceUrl': 'https://books.test',
        'ruleBookInfo': {
          'name': 'h1@text',
          'tocUrl': "@js:'data:;base64,aHR0cHM6Ly9ib29rcy50ZXN0L3RvYy83'",
        },
        'ruleToc': {
          'chapterList': 'li',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
        'ruleContent': {'content': 'article@text'},
      }).toRegisteredSource();
      const bookId = 'data:;base64,aHR0cHM6Ly9ib29rcy50ZXN0L2Jvb2svNw==';

      final book = await runtime.getBook(source, bookId);
      final chapters = await runtime.getChapters(source, book.id);
      final content = await runtime.getChapterContent(
        source,
        bookId: book.id,
        chapterId: chapters.single.id,
      );

      expect(book.id, bookId);
      expect(chapters.single.title, 'One');
      expect(content.content, 'Readable body');
      expect(
        transport.requests.map((request) => request.url.toString()),
        containsAll([
          'https://books.test/book/7',
          'https://books.test/toc/7',
          'https://books.test/chapter/1',
        ]),
      );
    });

    test('loads declarative discovery channels and paged books', () async {
      final transport = _FakeTransport({
        'https://books.test/rank?page=2': '''
          <div class="explore-book">
            <a href="/book/2"><span class="title">第二页书籍</span></a>
            <span class="writer">作者乙</span>
          </div>
        ''',
      });
      final raw = Map<String, dynamic>.from(_htmlSource().raw)
        ..addAll({
          'exploreUrl': '排行榜::/rank?page={{page}}',
          'ruleExplore': {
            'bookList': 'class.explore-book',
            'name': 'class.title@text',
            'author': 'class.writer@text',
            'bookUrl': 'tag.a@href',
          },
        });
      final source = ReadingSourceConfig.fromJson(
        raw,
      ).toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(transport: transport);

      final categories = await runtime.getExploreCategories(source);
      expect(categories.single.name, '排行榜');
      final page = await runtime.browse(
        source,
        category: categories.single.id,
        page: 2,
      );

      expect(page.page, 2);
      expect(page.items.single.title, '第二页书籍');
      expect(page.items.single.author, '作者乙');
      expect(page.items.single.id, 'https://books.test/book/2');
      expect(page.hasMore, isTrue);
    });

    test('builds discovery channels returned by a source script', () async {
      final transport = _FakeTransport({
        'https://books.test/script-rank?page=1': '''
          <div class="explore-book">
            <a href="/book/8"><span class="title">Script Book</span></a>
          </div>
        ''',
      });
      final raw = Map<String, dynamic>.from(_htmlSource().raw)
        ..addAll({
          'exploreUrl':
              "@js:'Script Rank::/script-rank?page={{page}}&&Latest::/latest?page={{page}}'",
          'ruleExplore': {
            'bookList': 'class.explore-book',
            'name': 'class.title@text',
            'bookUrl': 'tag.a@href',
          },
        });
      final source = ReadingSourceConfig.fromJson(
        raw,
      ).toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final categories = await runtime.getExploreCategories(source);
      expect(categories.map((category) => category.name), [
        'Script Rank',
        'Latest',
      ]);
      final page = await runtime.browse(source, category: categories.first.id);

      expect(page.items.single.title, 'Script Book');
      expect(page.items.single.id, 'https://books.test/book/8');
    });

    test(
      'parses indexed CSS rules used by aggregate discovery sources',
      () async {
        final transport = _FakeTransport({
          'https://www.123bqg.cc/0/1.html': '''
          <div class="lst-item">
            <img _src="/cover/1.jpg">
            <h2>频道书籍</h2>
            <a href="/ignored">忽略</a>
            <a href="/book/1">简介</a>
            <span>作者甲</span><span>玄幻</span>
          </div>
        ''',
        });
        final source = ReadingSourceConfig.fromJson({
          'bookSourceName': 'Indexed CSS source',
          'bookSourceUrl': 'https://www.123bqg.cc',
          'exploreUrl': '全部分类::https://www.123bqg.cc/0/{{page}}.html',
          'ruleExplore': {
            'author': 'span.0@text',
            'bookList': '.lst-item',
            'bookUrl': 'a.1@href',
            'coverUrl': 'img@_src',
            'intro': 'a.1@text',
            'kind': 'span.1@text',
            'name': 'h2@text',
          },
        }).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);

        final page = await runtime.browse(
          source,
          category: 'https://www.123bqg.cc/0/{{page}}.html',
        );

        expect(page.items.single.title, '频道书籍');
        expect(page.items.single.author, '作者甲');
        expect(page.items.single.id, 'https://www.123bqg.cc/book/1');
        expect(
          page.items.single.coverUrl,
          Uri.parse('https://www.123bqg.cc/cover/1.jpg'),
        );
      },
    );

    test(
      'discovery falls back to search rules when ruleExplore is empty',
      () async {
        final transport = _FakeTransport({
          'https://books.test/latest?page=1': '''
          <div class="book">
            <a href="/book/3"><span class="name">沿用搜索规则</span></a>
          </div>
        ''',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['exploreUrl'] = '最新::/latest?page={{page}}';
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);
        final category = (await runtime.getExploreCategories(source)).single;

        final page = await runtime.browse(source, category: category.id);

        expect(page.items.single.title, '沿用搜索规则');
      },
    );

    test('rejects discovery URLs not declared by the source', () async {
      final transport = _FakeTransport(const {});
      final raw = Map<String, dynamic>.from(_htmlSource().raw)
        ..['exploreUrl'] = '排行::/rank?page={{page}}';
      final source = ReadingSourceConfig.fromJson(
        raw,
      ).toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(transport: transport);

      await expectLater(
        runtime.browse(source, category: 'https://attacker.example/books'),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test(
      'scripted content does not block search and executes when requested',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=test&page=1': '''
            <div class="book">
              <a href="/book/1"><span class="name">可搜索</span></a>
              <span class="author">作者</span>
            </div>
          ''',
          'https://books.test/chapter/1': '<article>脚本正文</article>',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw);
        raw['ruleContent'] = {'content': '@js:result'};
        final runtime = SourceRuntime(transport: transport);
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);

        final page = await runtime.search(source, 'test');
        expect(page.items.single.title, '可搜索');

        final content = await runtime.getChapterContent(
          source,
          bookId: 'https://books.test/book/1',
          chapterId: 'https://books.test/chapter/1',
        );
        expect(content.content, contains('脚本正文'));
        expect(transport.requests, hasLength(2));
      },
    );
  });

  test('unified client blocks compatible requests while the toggle is off', () {
    final client = BookSourceClient();
    addTearDown(client.close);

    expect(
      () => client.search(_htmlSource().toRegisteredSource(enabled: true), 'x'),
      throwsA(
        isA<BookSourceProtocolException>().having(
          (error) => error.message,
          'message',
          contains('disabled'),
        ),
      ),
    );
  });

  group('SourceHttpTransport', () {
    HttpServer? server;

    tearDown(() async {
      await server?.close(force: true);
    });

    test('exposes the isolated cookie jar to source scripts', () {
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final uri = Uri.parse('https://cookies.test/path');

      transport.setScriptCookies('source-1', uri, 'sid=abc; theme=dark');
      expect(
        transport.scriptCookieHeader('source-1', uri),
        'sid=abc; theme=dark',
      );
      expect(transport.scriptCookieHeader('source-2', uri), isEmpty);

      transport.removeScriptCookies('source-1', uri);
      expect(transport.scriptCookieHeader('source-1', uri), isEmpty);
    });

    test(
      'retries safe HTTP 400 responses through the system network',
      () async {
        final pinned = Dio()..httpClientAdapter = _SequenceAdapter([400]);
        final system = Dio()
          ..httpClientAdapter = _SequenceAdapter([200], body: 'books');
        final transport = SourceHttpTransport(
          dio: pinned,
          systemDio: system,
          networkPolicy: BookSourceNetworkPolicy(
            lookup: (_) async => [InternetAddress('93.184.216.34')],
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'https://books.test/channel',
            baseUri: Uri.parse('https://books.test'),
          ),
        );

        expect(response.body, 'books');
        expect((pinned.httpClientAdapter as _SequenceAdapter).requests, 1);
        expect((system.httpClientAdapter as _SequenceAdapter).requests, 1);
      },
    );

    test('does not replay POST after HTTP 400', () async {
      final pinned = Dio()..httpClientAdapter = _SequenceAdapter([400]);
      final system = Dio()
        ..httpClientAdapter = _SequenceAdapter([200], body: 'unexpected');
      final transport = SourceHttpTransport(
        dio: pinned,
        systemDio: system,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      addTearDown(transport.close);

      await expectLater(
        transport.send(
          SourceRequestTemplate.parse(
            'https://books.test/submit,{"method":"POST","body":"q=1"}',
            baseUri: Uri.parse('https://books.test'),
          ),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect((pinned.httpClientAdapter as _SequenceAdapter).requests, 1);
      expect((system.httpClientAdapter as _SequenceAdapter).requests, 0);
    });

    test(
      'returns response status headers and cookies to source scripts',
      () async {
        final boundServer = server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        boundServer.listen((request) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('X-Source-Test', 'ready');
          request.response.cookies.add(Cookie('sid', 'abc')..path = '/');
          request.response.write('body');
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${boundServer.address.address}:${boundServer.port}/metadata',
            baseUri: Uri.parse('https://unused.test'),
            cookieJarKey: 'source-1',
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['x-source-test'], 'ready');
        expect(response.cookies['sid'], 'abc');
      },
    );

    test('sends HEAD and returns metadata without a response body', () async {
      final boundServer = server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final method = Completer<String>();
      boundServer.listen((request) async {
        method.complete(request.method);
        request.response.statusCode = HttpStatus.noContent;
        request.response.headers.set('X-Head', 'ready');
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${boundServer.address.address}:${boundServer.port}/probe,'
          '{"method":"HEAD"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(await method.future, 'HEAD');
      expect(response.body, isEmpty);
      expect(response.statusCode, HttpStatus.noContent);
      expect(response.headers['x-head'], 'ready');
    });

    test('sends and decodes bounded GBK POST responses', () async {
      final boundServer = server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final received = Completer<List<int>>();
      boundServer.listen((request) async {
        received.complete(
          await request.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
        request.response.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'gbk',
        );
        request.response.add(gbk_bytes.encode('结果'));
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${boundServer.address.address}:${boundServer.port}/search,'
          '{"method":"POST","body":"关键词=剑来","charset":"gbk"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(response.body, '结果');
      expect(await received.future, gbk_bytes.encode('关键词=剑来'));
    });

    test('keeps source cookies across same-URL redirects', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server!.listen((request) async {
        requests++;
        final hasSession = request.cookies.any(
          (cookie) => cookie.name == 'session' && cookie.value == 'ready',
        );
        if (!hasSession) {
          request.response.cookies.add(Cookie('session', 'ready')..path = '/');
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/channel');
        } else {
          request.response.write('books');
        }
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/channel',
          baseUri: Uri.parse('https://unused.test'),
          cookieJarKey: 'source-1',
        ),
      );

      expect(response.body, 'books');
      expect(requests, 2);
    });

    test(
      'keeps redirect cookies within a request when persistence is disabled',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final receivedCookies = <String, String?>{};
        server!.listen((request) async {
          final session = request.cookies
              .where((cookie) => cookie.name == 'session')
              .firstOrNull;
          receivedCookies[request.uri.path] = session?.value;
          if (request.uri.path == '/start') {
            request.response.cookies.add(
              Cookie('session', 'redirect-only')..path = '/',
            );
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '/channel',
            );
          } else {
            request.response.write(
              request.uri.path == '/channel' ? 'books' : 'clean',
            );
          }
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final baseUri = Uri.parse('https://unused.test');
        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/start',
            baseUri: baseUri,
          ),
        );
        final nextResponse = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/probe',
            baseUri: baseUri,
          ),
        );

        expect(response.body, 'books');
        expect(receivedCookies['/start'], isNull);
        expect(receivedCookies['/channel'], 'redirect-only');
        expect(nextResponse.body, 'clean');
        expect(receivedCookies['/probe'], isNull);
      },
    );

    test('matches browser method semantics for POST redirects', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      server!.listen((request) async {
        methods.add(request.method);
        if (request.uri.path == '/submit') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/result');
        } else {
          request.response.write('ok');
        }
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/submit,'
          '{"method":"POST","body":"q=test"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(response.body, 'ok');
      expect(methods, ['POST', 'GET']);
    });

    test(
      'decodes malformed GBK responses without initializing codec decoder',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'plain',
            charset: 'gbk',
          );
          request.response.add(<int>[0xBD, 0xE1, 0xB9]);
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/',
            baseUri: Uri.parse('https://unused.test'),
          ),
        );

        expect(response.body, startsWith('结'));
        expect(response.body, hasLength(2));
      },
    );

    test('rejects responses over the configured bound', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((request) async {
        request.response.add(utf8.encode('12345'));
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
        maxResponseBytes: 4,
      );
      addTearDown(transport.close);

      expect(
        () => transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/',
            baseUri: Uri.parse('https://unused.test'),
          ),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
    });

    test('cancels an in-flight HTTP request', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      final release = Completer<void>();
      server!.listen((request) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        try {
          request.response.write('late response');
          await request.response.close();
        } catch (_) {
          // The client is expected to close the request before this response.
        }
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final cancellation = BookDownloadCancellation();
      final request = transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/slow',
          baseUri: Uri.parse('https://unused.test'),
        ),
        cancellation: cancellation,
      );
      await started.future;

      cancellation.cancel();
      await expectLater(
        request,
        throwsA(isA<BookDownloadCancelledException>()),
      );
      release.complete();
    });
  });
}

ReadingSourceConfig _htmlSource() => ReadingSourceConfig.fromJson({
  'bookSourceName': 'HTML test',
  'bookSourceUrl': 'https://books.test',
  'searchUrl': '/search?q={{key}}&page={{page}}',
  'ruleSearch': {
    'bookList': 'class.book',
    'name': 'class.name@text',
    'author': 'class.author@text',
    'kind': 'class.kind@text',
    'bookUrl': 'tag.a@href',
    'coverUrl': 'tag.img@src',
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'author': 'class.author@text',
    'intro': 'class.intro@text',
    'tocUrl': 'class.toc@href',
  },
  'ruleToc': {
    'chapterList': '#chapters@li',
    'chapterName': 'a@text',
    'chapterUrl': 'a@href',
  },
  'ruleContent': {
    'content': '#content@html',
    'replaceRegex': '<div class="ad">.*</div>',
  },
});

ReadingSourceConfig _jsonSource() => ReadingSourceConfig.fromJson({
  'bookSourceName': 'JSON test',
  'bookSourceUrl': 'https://api.test',
  'searchUrl': '/search?q={{key}}',
  'ruleSearch': {
    'bookList': r'$.books[*]',
    'name': r'$.title',
    'author': r'$.author',
    'bookUrl': r'/books/{{$.id}}',
  },
  'ruleBookInfo': {
    'name': r'$.title',
    'author': r'$.author',
    'tocUrl': r'$.toc',
  },
  'ruleToc': {
    'chapterList': r'$.chapters[*]',
    'chapterName': r'$.title',
    'chapterUrl': r'/content/{{$.id}}',
  },
  'ruleContent': {'content': r'$.body'},
});

class _FakeTransport implements SourceTransport {
  _FakeTransport(this.responses);

  final Map<String, String> responses;
  final List<SourceRequestTemplate> requests = [];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    final body = responses[request.url.toString()];
    if (body == null) {
      throw StateError('Missing fake response for ${request.url}');
    }
    return SourceResponse(body: body, finalUri: request.url);
  }
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.statuses, {this.body = ''});

  final List<int> statuses;
  final String body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests++;
    final status = statuses[index.clamp(0, statuses.length - 1)];
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        HttpHeaders.contentTypeHeader: ['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryLoginSessionStore implements SourceLoginSessionStore {
  final Map<String, SourceLoginSession> values = {};

  @override
  Future<void> clear(String sourceId) async {
    values.remove(sourceId);
  }

  @override
  Future<SourceLoginSession> read(String sourceId) async =>
      values[sourceId] ?? const SourceLoginSession();

  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    values[sourceId] = session;
  }
}
