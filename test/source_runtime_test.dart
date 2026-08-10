import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SourceRequestTemplate', () {
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

    test(
      'shared login helpers can call sibling helpers through this',
      () async {
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['loginUi'] = jsonEncode([
            {'name': 'account', 'type': 'text'},
          ])
          ..['jsLib'] = '''
          const html = `function toggleLogs() {}`;
          function getVariable(name) {
            return source.getLoginInfoMap().get(name);
          }
          function getToken() {
            return this.getVariable('account');
          }
        '''
          ..['loginUrl'] = '''
          function login() {
            var info = source.getLoginInfoMap();
            info.put('token', getToken());
            source.putLoginInfo(info);
          }
        ''';
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final store = _MemoryLoginSessionStore();
        final runtime = SourceRuntime(loginSessionStore: store);
        addTearDown(runtime.close);

        await runtime.login(source, const {'account': 'reader'});

        expect((await store.read(source.id)).loginInfo['token'], 'reader');
      },
    );
  });

  group('SourceRuntime', () {
    test('normalizes the complete text reading chain to protocol DTOs', () async {
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
      expect(
        transport.requests
            .where((r) => r.url.toString() == 'https://books.test/book/1')
            .length,
        1,
        reason:
            'getBook() and getChapters() should share one fetch of the info page',
      );
    });

    test(
      'getChapters reuses the info page fetch when the source has no separate toc page',
      () async {
        final transport = _FakeTransport({
          'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['ruleBookInfo'] = {
            'name': 'h1@text',
            'author': 'class.author@text',
            // No tocUrl rule: the chapter list lives on the info page itself.
          };
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);

        final book = await runtime.getBook(source, 'https://books.test/book/1');
        final chapters = await runtime.getChapters(source, book.id);

        expect(chapters.single.title, '第一章');
        expect(
          transport.requests
              .where((r) => r.url.toString() == 'https://books.test/book/1')
              .length,
          1,
        );
      },
    );

    test('chapter URLs can depend on the parsed chapter title', () async {
      final transport = _FakeTransport({
        'https://books.test/book/1': '''
          <h1>上下文书名</h1><a class="toc" href="/book/1/toc">目录</a>
        ''',
        'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a data-id="7">第七章</a></li></ul>
        ''',
        'https://books.test/chapter/7?title=%E7%AC%AC%E4%B8%83%E7%AB%A0':
            '<article id="content"><p>依赖章节上下文的正文</p></article>',
      });
      final raw = Map<String, dynamic>.from(_htmlSource().raw)
        ..['ruleToc'] = {
          'chapterList': '#chapters@li',
          'chapterName': 'a@text',
          'chapterUrl':
              r'a@data-id<js>`/chapter/${result}?title=${encodeURIComponent(chapter.title)}`</js>',
        };
      final source = ReadingSourceConfig.fromJson(
        raw,
      ).toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(transport: transport);
      addTearDown(runtime.close);

      final book = await runtime.getBook(source, 'https://books.test/book/1');
      final chapters = await runtime.getChapters(source, book.id);
      final content = await runtime.getChapterContent(
        source,
        bookId: book.id,
        chapterId: chapters.single.id,
        sourceVariables: {
          ...book.sourceVariables,
          'chapterIndex': '0',
          'chapterTitle': chapters.single.title,
          'bookName': book.title,
          'bookAuthor': book.author,
          'bookType': '${book.type}',
        },
      );

      expect(
        chapters.single.id,
        'https://books.test/chapter/7?title=%E7%AC%AC%E4%B8%83%E7%AB%A0',
      );
      expect(content.content, contains('依赖章节上下文的正文'));
    });

    test(
      'a leading "latest chapters" widget does not shadow the full catalog',
      () async {
        final transport = _FakeTransport({
          'https://books.test/book/1': '''
            <h1>剑来</h1><p class="author">烽火</p>
            <a class="toc" href="/book/1/toc">目录</a>
          ''',
          'https://books.test/book/1/toc': '''
            <div id="latest">
              <li><a href="/chapter/5">第五章</a></li>
              <li><a href="/chapter/4">第四章</a></li>
              <li><a href="/chapter/3">第三章</a></li>
            </div>
            <ul id="chapters">
              <li><a href="/chapter/1">第一章</a></li>
              <li><a href="/chapter/2">第二章</a></li>
              <li><a href="/chapter/3">第三章</a></li>
              <li><a href="/chapter/4">第四章</a></li>
              <li><a href="/chapter/5">第五章</a></li>
            </ul>
          ''',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['ruleToc'] = {
            // Matches every <li> on the page, including the "latest
            // chapters" widget rendered above the full catalog — a common
            // pattern on real sites and a common way for imported sources
            // to be scoped too loosely.
            'chapterList': 'tag.li',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          };
        final source = ReadingSourceConfig.fromJson(
          raw,
        ).toRegisteredSource(enabled: true);
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);

        final book = await runtime.getBook(source, 'https://books.test/book/1');
        final chapters = await runtime.getChapters(source, book.id);

        expect(
          chapters.map((chapter) => chapter.title).toList(),
          ['第一章', '第二章', '第三章', '第四章', '第五章'],
          reason:
              'the widget\'s duplicate entries must not push later chapters '
              'to the front of the catalog',
        );
        expect(chapters.map((chapter) => chapter.order).toList(), [
          0,
          1,
          2,
          3,
          4,
        ]);
      },
    );

    test(
      'rejects short login and verification shells as chapter content',
      () async {
        final transport = _FakeTransport({
          'https://books.test/chapter/login':
              '<html><body><form>请先登录后阅读</form></body></html>',
        });
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);

        await expectLater(
          runtime.getChapterContent(
            _htmlSource().toRegisteredSource(enabled: true),
            bookId: 'https://books.test/book/1',
            chapterId: 'https://books.test/chapter/login',
          ),
          throwsA(isA<BookSourceProtocolException>()),
        );
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

    test(
      'accepts image-only Legado chapters, lazy attributes, srcset, and page joins',
      () async {
        final transport = _FakeTransport({
          'https://books.test/chapter/image-1': '''
            <div class="pages">
              <img data-lazy="/images/1.webp">
              <img data-original="/images/2.webp">
            </div>
          ''',
          'https://books.test/chapter/image-2':
              '<img srcset="/images/3.webp 1x, /images/3@2x.webp 2x">',
        });
        final raw = Map<String, dynamic>.from(_htmlSource().raw)
          ..['enabledCookieJar'] = true
          ..['header'] = {'Referer': 'https://books.test/'}
          ..['ruleContent'] = {
            'content': 'class.pages@html',
            'nextContentUrl': 'a.next@href',
          };
        final source = ReadingSourceConfig.fromJson(raw).toRegisteredSource();
        final runtime = SourceRuntime(
          transport: transport,
          loginSessionStore: _MemoryLoginSessionStore(),
        );
        addTearDown(runtime.close);

        final content = await runtime.getChapterContent(
          source,
          bookId: 'https://books.test/book/1',
          chapterId: 'https://books.test/chapter/image-1',
        );

        expect(content.content, contains('data-lazy'));
        expect(content.images.map((image) => image.url), [
          Uri.parse('https://books.test/images/1.webp'),
          Uri.parse('https://books.test/images/2.webp'),
        ]);
        expect(content.images.first.headers['Referer'], 'https://books.test/');
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
