import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_contract.dart';

void main() {
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

  group('SourceRuleEngine extraction contracts', () {
    const engine = SourceRuleEngine();

    test('top-level parsing preserves nested and quoted delimiters', () {
      final document = SourceRuleDocument.parse(
        '{"id":7}',
        Uri.parse('https://books.test/'),
      );

      expect(
        engine.evaluateString(
          document,
          document.value,
          r'''"first||value"||"fallback"''',
        ),
        'first||value',
      );
      expect(
        engine.evaluateString(
          document,
          document.value,
          r'''$.id@put:{token:{{"a,b:c"}}}''',
        ),
        '7',
      );
      expect(document.ruleState['token'], 'a,b:c');
    });

    test('sync and async selector evaluation retain identical order', () async {
      final document = SourceRuleDocument.parse(
        '<ul><li>one</li><li>two</li></ul>',
        Uri.parse('https://books.test/'),
      );

      expect(
        await engine.evaluateListAsync(document, null, 'li'),
        engine.evaluateList(document, null, 'li'),
      );
      expect(
        await engine.evaluateStringAsync(
          document,
          null,
          'li@text',
          joinSeparator: '\n',
        ),
        'one\ntwo',
      );
    });

    test('sync and async transforms preserve their exact error text', () async {
      final document = SourceRuleDocument.parse(
        'body',
        Uri.parse('https://books.test/'),
      );

      expect(
        () => engine.evaluateString(document, null, '##['),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'reading source rule contains an invalid regular expression.',
          ),
        ),
      );
      await expectLater(
        engine.evaluateStringAsync(document, null, '##['),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'Source rule contains an invalid regular expression.',
          ),
        ),
      );
    });

    test('put and script pipelines retain sync and async sequencing', () async {
      final evaluator = _RecordingEvaluator();
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Rule source',
        'bookSourceUrl': 'https://rules.test',
      });
      final document = SourceRuleDocument.parse(
        '{"id":17}',
        Uri.parse('https://rules.test/'),
        scriptContext: SourceScriptContext(source: source),
      );
      final scriptedEngine = SourceRuleEngine(
        scriptEvaluatorProvider: () => evaluator,
      );

      expect(
        scriptedEngine.evaluateString(
          document,
          document.value,
          r'''$.id@put:{saved:$.id}''',
        ),
        '17',
      );
      expect(document.ruleState['saved'], '17');
      expect(
        scriptedEngine.evaluateString(
          document,
          document.value,
          r'''@get:{saved}<js>sync</js>$.value''',
        ),
        'sync:17',
      );
      expect(
        await scriptedEngine.evaluateStringAsync(
          document,
          document.value,
          r'''@get:{saved}<js>async</js>$.value''',
        ),
        'async:17',
      );
      expect(evaluator.calls, ['sync', 'async']);
    });

    test(
      'put mappings preserve recursive order in sync and async modes',
      () async {
        final syncDocument = SourceRuleDocument.parse(
          '{"id":17}',
          Uri.parse('https://rules.test/'),
        );
        final asyncDocument = SourceRuleDocument.parse(
          '{"id":17}',
          Uri.parse('https://rules.test/'),
        );
        const rule = r'$.id@put:{first:$.id,second:@get:{first}}';

        expect(
          engine.evaluateString(syncDocument, syncDocument.value, rule),
          '17',
        );
        expect(
          await engine.evaluateStringAsync(
            asyncDocument,
            asyncDocument.value,
            rule,
          ),
          '17',
        );
        expect(syncDocument.ruleState, {'first': '17', 'second': '17'});
        expect(asyncDocument.ruleState, syncDocument.ruleState);
      },
    );

    test(
      'script output documents preserve list dispatch and rule state',
      () async {
        final evaluator = _RecordingEvaluator();
        final source = ReadingSourceConfig.fromJson({
          'bookSourceName': 'Rule source',
          'bookSourceUrl': 'https://rules.test',
        });
        final document = SourceRuleDocument.parse(
          '{"id":17}',
          Uri.parse('https://rules.test/'),
          scriptContext: SourceScriptContext(source: source),
          ruleState: {'saved': 'kept'},
        );
        final scriptedEngine = SourceRuleEngine(
          scriptEvaluatorProvider: () => evaluator,
        );

        expect(
          scriptedEngine.evaluateList(
            document,
            document.value,
            '<js>html</js>li@text',
          ),
          ['one', 'two'],
        );
        expect(
          await scriptedEngine.evaluateListAsync(
            document,
            document.value,
            r'<js>map</js>$.items[*]',
          ),
          [1, 2],
        );
        expect(
          scriptedEngine.evaluateString(
            document,
            document.value,
            r'<js>html</js>@get:{saved}',
          ),
          'kept',
        );
        expect(evaluator.calls, ['html', 'map', 'html']);
      },
    );

    test('script pipeline errors retain sync and async wording', () async {
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Rule source',
        'bookSourceUrl': 'https://rules.test',
      });
      final document = SourceRuleDocument.parse(
        'body',
        Uri.parse('https://rules.test/'),
        scriptContext: SourceScriptContext(source: source),
      );

      expect(
        () => engine.evaluateString(document, null, '<js>missing</js>'),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'This reading source needs JavaScript execution.',
          ),
        ),
      );
      await expectLater(
        engine.evaluateStringAsync(document, null, '<js>missing</js>'),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'This reading source needs JavaScript execution.',
          ),
        ),
      );

      final scriptedEngine = SourceRuleEngine(
        scriptEvaluatorProvider: () => _RecordingEvaluator(),
      );
      expect(
        () => scriptedEngine.evaluateString(
          document,
          null,
          '<js>badUrl</js>',
          resolveUrl: true,
        ),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'reading source script produced a non-HTTP URL.',
          ),
        ),
      );
      await expectLater(
        scriptedEngine.evaluateStringAsync(
          document,
          null,
          '<js>badUrl</js>',
          resolveUrl: true,
        ),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'Source script produced a non-HTTP URL.',
          ),
        ),
      );
    });
  });
}

class _RecordingEvaluator implements SourceScriptEvaluator {
  final calls = <String>[];

  @override
  Object? evaluate(String script, SourceScriptContext context) {
    calls.add(script);
    if (script == 'html') return '<ul><li>one</li><li>two</li></ul>';
    if (script == 'map') {
      return {
        'items': [1, 2],
      };
    }
    if (script == 'badUrl') return 'mailto:test@example.com';
    return {'value': '$script:${context.result}'};
  }

  @override
  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async {
    calls.add(script);
    if (script == 'html') return '<ul><li>one</li><li>two</li></ul>';
    if (script == 'map') {
      return {
        'items': [1, 2],
      };
    }
    if (script == 'badUrl') return 'mailto:test@example.com';
    return {'value': '$script:${context.result}'};
  }

  @override
  void dispose() {}
}
