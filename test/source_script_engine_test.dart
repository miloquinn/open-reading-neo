import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_bootstrap.dart';
import 'package:xxread/book_sources/source_engine/source_script_crypto_api.dart';
import 'package:xxread/book_sources/source_engine/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_host_api.dart';
import 'package:xxread/book_sources/source_engine/source_script_state.dart';
import 'package:xxread/book_sources/source_engine/source_script_text_api.dart';

void main() {
  test('QuickJS evaluates source bindings and pure java helpers', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Script source',
      'bookSourceUrl': 'https://books.test#variant',
    });

    final value = evaluator.evaluate(
      "source.getKey() + ':' + (page + 1) + ':' + java.md5Encode('abc')",
      SourceScriptContext(source: source, variables: const {'page': '2'}),
    );

    expect(
      value,
      'https://books.test#variant:3:900150983cd24fb0d6963f7d28e17f72',
    );
    expect(
      evaluator.evaluate(
        "java.md5Encode16('abc')",
        SourceScriptContext(source: source),
      ),
      '3cd24fb0d6963f7d',
    );
    expect(
      evaluator.evaluate(
        "java.getStringList('li@text').join(',')",
        SourceScriptContext(
          source: source,
          result: '<ul><li>甲</li><li>乙</li></ul>',
        ),
      ),
      '甲,乙',
    );
  });

  test('QuickJS keeps source variables and java state per source', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'State source',
      'bookSourceUrl': 'https://state.test',
    });

    evaluator.evaluate(
      "java.put('token', 'ready'); source.setVariable('saved'); book.putVariable('id', 7); chapter.putVariable('next', '/c2');",
      SourceScriptContext(source: source),
    );
    final value = evaluator.evaluate(
      "java.get('token') + ':' + source.getVariable() + ':' + book.getVariable('id') + ':' + chapter.getVariable('next')",
      SourceScriptContext(source: source),
    );

    expect(value, 'ready:saved:7:/c2');
  });

  test('QuickJS exposes source cache helpers with expiry and memory aliases', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Cache source',
      'bookSourceUrl': 'https://cache.test',
    });
    final context = SourceScriptContext(source: source);

    expect(
      evaluator.evaluate(
        "cache.put('persistent','value',60); cache.putMemory('memory',7); "
        "cache.get('persistent')+':' + cache.getFromMemory('memory')",
        context,
      ),
      'value:7',
    );
    evaluator.evaluate(
      "cache.delete('persistent'); cache.deleteMemory('memory')",
      context,
    );
    expect(
      evaluator.evaluate(
        "String(cache.get('persistent'))+':' + String(cache.getFromMemory('memory'))",
        context,
      ),
      'null:null',
    );
  });

  test('QuickJS evaluates inline shared source scripts before rules', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Library source',
      'bookSourceUrl': 'https://library.test',
      'jsLib':
          "const prefix='['; function decorate(value){ return prefix+value+']'; }",
    });

    expect(
      evaluator.evaluate(
        "decorate('ready')",
        SourceScriptContext(source: source),
      ),
      '[ready]',
    );
    expect(
      evaluator.evaluate(
        "decorate('again')",
        SourceScriptContext(source: source),
      ),
      '[again]',
    );
    final other = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Other library source',
      'bookSourceUrl': 'https://other-library.test',
      'jsLib': "function decorate(value){ return '<'+value+'>'; }",
    });
    expect(
      evaluator.evaluate(
        "decorate('isolated')",
        SourceScriptContext(source: other),
      ),
      '<isolated>',
    );
  });

  test('QuickJS exposes persistent source values and source metadata', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Metadata source',
      'bookSourceUrl': 'https://metadata.test',
      'bookSourceType': 0,
    });

    expect(
      evaluator.evaluate(
        "source.put('cursor', 'next-2'); source.bookSourceName + ':' + "
        "source.bookSourceType + ':' + source.get('cursor')",
        SourceScriptContext(source: source),
      ),
      'Metadata source:0:next-2',
    );
    expect(
      evaluator.evaluate(
        "source.get('cursor')",
        SourceScriptContext(source: source),
      ),
      'next-2',
    );
  });

  test('QuickJS exposes rule groups and mutable book chapter contexts', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Context source',
      'bookSourceUrl': 'https://context.test',
      'ruleExplore': {'author': '@js:\'Author\''},
    });
    final book = <String, Object?>{'name': 'Before'};
    final chapter = <String, Object?>{'index': 3};

    final value = evaluator.evaluate(
      "book.name='After'; chapter.title='Chapter'; "
      "source.ruleExplore.author + ':' + java.androidId().length + ':' + "
      "book.name + ':' + chapter.index",
      SourceScriptContext(
        source: source,
        book: book,
        chapter: chapter,
        bookWriter: book.addAll,
        chapterWriter: chapter.addAll,
      ),
    );

    expect(value, "@js:'Author':16:After:3");
    expect(book['name'], 'After');
    expect(chapter['title'], 'Chapter');
  });

  test('QuickJS exposes a bare title global matching chapter.title', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Legado-style source',
      'bookSourceUrl': 'https://legado.test',
    });
    final chapter = <String, Object?>{'title': 'Chapter 12'};

    expect(
      evaluator.evaluate(
        'title',
        SourceScriptContext(source: source, chapter: chapter),
      ),
      'Chapter 12',
    );
  });

  test('setContent changes the default input for later DOM helpers', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Mutable content source',
      'bookSourceUrl': 'https://content.test',
    });

    expect(
      evaluator.evaluate(
        "java.setContent('<div id=\"value\">Changed</div>'); "
        "java.getString('#value@text')",
        SourceScriptContext(source: source, result: '<p>Before</p>'),
      ),
      'Changed',
    );
  });

  test(
    'QuickJS exposes optional source configuration without account access',
    () {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Configured source',
        'bookSourceUrl': 'https://configured.test',
        'bookSourceGroup': 'Public',
        'lastUpdateTime': 123,
        'exploreUrl': '/browse',
        'loginUrl': 'function publicBase(){ return "https://public.test"; }',
        'header': '{"User-Agent":"Configured UA"}',
      });
      final context = SourceScriptContext(source: source);

      expect(
        evaluator.evaluate(
          "eval(String(source.loginUrl)); publicBase() + ':' + "
          "source.bookSourceGroup + ':' + source.lastUpdateTime + ':' + "
          "source.exploreUrl",
          context,
        ),
        'https://public.test:Public:123:/browse',
      );
      expect(
        evaluator.evaluate(
          "JSON.parse(String(source.header))['User-Agent'] + ':' + "
          "java.getWebViewUA() + ':' + java.bytesToStr([104,105])",
          context,
        ),
        'Configured UA:Configured UA:hi',
      );
      expect(
        evaluator.evaluate(
          "var info=source.getLoginInfoMap(); info.put('page','2'); "
          "source.putLoginInfo(info); source.getLoginInfoMap().get('page')",
          context,
        ),
        '2',
      );
      expect(
        evaluator.evaluate("source.getLoginInfo()", context),
        '{"page":"2"}',
      );
    },
  );

  test('QuickJS cookie helpers use the source cookie bridge', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Cookie source',
      'bookSourceUrl': 'https://cookies.test',
    });
    final cookies = <String, String>{
      'https://cookies.test/path': 'sid=abc; theme=dark',
    };
    final context = SourceScriptContext(
      source: source,
      cookieReader: (uri) => cookies[uri.toString()] ?? '',
      cookieWriter: (uri, value) => cookies[uri.toString()] = value,
      cookieRemover: (uri) => cookies.remove(uri.toString()),
    );

    expect(
      evaluator.evaluate(
        "cookie.getKey('https://cookies.test/path', 'sid') + ':' + "
        "cookie.getCookie('https://cookies.test/path')",
        context,
      ),
      'abc:sid=abc; theme=dark',
    );
    evaluator.evaluate(
      "cookie.setCookie('https://cookies.test/new', 'token=xyz')",
      context,
    );
    expect(cookies['https://cookies.test/new'], 'token=xyz');
    expect(
      evaluator.evaluate(
        "java.getCookie('https://cookies.test/new', 'token')",
        context,
      ),
      'xyz',
    );
    evaluator.evaluate(
      "cookie.removeCookie('https://cookies.test/new')",
      context,
    );
    expect(cookies.containsKey('https://cookies.test/new'), isFalse);
  });

  test('QuickJS exposes source headers, dates, bytes, and DOM element helpers', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Helper source',
      'bookSourceUrl': 'https://helpers.test',
      'header': '{"Referer":"https://origin.test/"}',
    });
    final context = SourceScriptContext(
      source: source,
      result: '<ul><li><a href="/one">First</a></li></ul>',
    );

    expect(
      evaluator.evaluate(
        "source.header.Referer + ':' + java.timeFormatUTC(0, 'yyyy-MM-dd HH:mm:ss', 0)",
        context,
      ),
      'https://origin.test/:1970-01-01 00:00:00',
    );
    expect(
      evaluator.evaluate(
        "java.getElements('li')[0].select('a')[0].attr('href')",
        context,
      ),
      '/one',
    );
    expect(
      evaluator.evaluate(
        "var items=java.getElements('li'); "
        "items.select('a').text()+':' + items.select('a').attr('href') + ':' + "
        "items.first().text()+':' + items.last().text()",
        context,
      ),
      'First:/one:First:First',
    );
    expect(
      evaluator.evaluate(
        "var links=java.getElements('a'); links.remove(); links.size()",
        context,
      ),
      0,
    );
    expect(
      evaluator.evaluate(
        "var values=java.getStringList('li@text'); "
        "values.size() + ':' + values.get(0) + ':' + values.isEmpty() + ':' + "
        "values.toArray().join('|')",
        context,
      ),
      '1:First:false:First',
    );
    expect(
      evaluator.evaluate(
        "java.base64DecodeToByteArray('AQID').join(',')",
        context,
      ),
      '1,2,3',
    );
    expect(
      evaluator.evaluate(
        "java.aesBase64DecodeToString('ObBxtb9plyPvM6ZEdBv6MQ==', '1234567890123456', 'AES/CBC/PKCS5Padding', '1234567890123456')",
        context,
      ),
      'hello',
    );
    expect(
      evaluator.evaluate(
        "java.HMacBase64('data', 'HmacSHA256', 'key')",
        context,
      ),
      'UDH+PZicbRU3oBP6bnOdojRj/a7DtwE32Cjjas4iG9A=',
    );
    expect(
      evaluator.evaluate(
        "java.createSymmetricCrypto('AES/CBC/PKCS5Padding', '1234567890123456', '1234567890123456').decryptStr('ObBxtb9plyPvM6ZEdBv6MQ==')",
        context,
      ),
      'hello',
    );
    expect(
      evaluator.evaluate(
        "java.createSymmetricCrypto('AES/CBC/PKCS5Padding', '1234567890123456', '1234567890123456').encryptBase64('hello')",
        context,
      ),
      'ObBxtb9plyPvM6ZEdBv6MQ==',
    );
    expect(
      evaluator.evaluate('''
          var imports = new JavaImporter();
          imports.importPackage(Packages.java.lang, Packages.javax.crypto);
          with (imports) {
            var keySpec = SecretKeySpec(String('1234567890123456').getBytes(), 'AES');
            var ivSpec = IvParameterSpec(String('1234567890123456').getBytes());
            var cipher = Cipher.getInstance('AES/CBC/PKCS5Padding');
            cipher.init(Cipher.DECRYPT_MODE, keySpec, ivSpec);
            var decoded = Base64.decode('ObBxtb9plyPvM6ZEdBv6MQ==', 2);
            var decrypted = cipher.doFinal(decoded);
            result = String(decrypted);
          }
          result;
          ''', context),
      'hello',
    );
  });

  test('QuickJS converts common traditional and simplified source labels', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Conversion source',
      'bookSourceUrl': 'https://conversion.test',
    });

    expect(
      evaluator.evaluate(
        "java.t2s('韓漫與熱門漫畫') + ':' + java.s2t('书源验证') + ':' + traditionalToSimplified('劇情')",
        SourceScriptContext(source: source),
      ),
      '韩漫与热门漫画:書源驗證:剧情',
    );
  });

  test('request templates support page arithmetic used by reading sources', () {
    final request = SourceRequestTemplate.parse(
      '/list/{{page-1}}?next={{page+1}}',
      baseUri: Uri.parse('https://books.test'),
      variables: const {'page': '3'},
    );

    expect(request.url.toString(), 'https://books.test/list/2?next=4');

    final complex = SourceRequestTemplate.parse(
      '/list/{{(page-1)*20+1}}?legacy={{page-1}*20}',
      baseUri: Uri.parse('https://books.test'),
      variables: const {'page': '3'},
    );
    expect(complex.url.toString(), 'https://books.test/list/41?legacy=40');

    final conditional = SourceRequestTemplate.parse(
      '/all/<,page{{page}}/>',
      baseUri: Uri.parse('https://books.test'),
      variables: const {'page': '2'},
    );
    expect(conditional.url.toString(), 'https://books.test/all/page2/');
  });

  test('rule pipelines pass selector results through JavaScript', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Rule source',
      'bookSourceUrl': 'https://rules.test',
    });
    final context = SourceScriptContext(source: source);
    final document = SourceRuleDocument.parse(
      '{"id":17}',
      Uri.parse('https://rules.test/'),
      scriptContext: context,
    );
    final engine = SourceRuleEngine(scriptEvaluatorProvider: () => evaluator);

    expect(
      engine.evaluateString(
        document,
        document.value,
        r"$.id@js:'https://rules.test/book/' + result",
        resolveUrl: true,
      ),
      'https://rules.test/book/17',
    );
    expect(
      engine.evaluateString(
        document,
        document.value,
        '''<js>'<a href="/next">next</a>'</js>a@href''',
        resolveUrl: true,
      ),
      'https://rules.test/next',
    );
  });

  test(
    'source scripts can synchronously consume replayed network responses',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Network script source',
        'bookSourceUrl': 'https://network.test',
      });
      final requests = <SourceScriptNetworkRequest>[];

      final value = await evaluator.evaluateAsync(
        "java.ajax('/token') + ':' + java.post('/lookup', 'id=7', {'X-Test':'yes'})",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async {
            requests.add(request);
            return SourceScriptNetworkResult(
              body: request.method == 'GET' ? 'token-1' : 'book-7',
              finalUrl: request.url == '/redirect'
                  ? 'https://network.test/final'
                  : request.url,
            );
          },
        ),
      );

      expect(value, 'token-1:book-7');
      expect(requests.map((request) => request.method), ['GET', 'POST']);
      expect(requests.last.body, 'id=7');
      expect(requests.last.headers, {'X-Test': 'yes'});

      final metadata = await evaluator.evaluateAsync(
        "var response=java.connect('/metadata'); "
        "response.statusCode()+':' + response.headers('Location') + ':' + "
        "response.cookies().sid + ':' + response.body()",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async => const SourceScriptNetworkResult(
            body: 'metadata-body',
            finalUrl: 'https://network.test/final',
            statusCode: 302,
            headers: {'Location': '/final'},
            cookies: {'sid': 'abc'},
          ),
        ),
      );
      expect(metadata, '302:/final:abc:metadata-body');

      SourceScriptNetworkRequest? headRequest;
      final head = await evaluator.evaluateAsync(
        "var response=java.head('/probe', {'X-Probe':'1'}); "
        "response.statusCode()+':' + response.headers('X-Head')",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async {
            headRequest = request;
            return const SourceScriptNetworkResult(
              body: '',
              finalUrl: 'https://network.test/probe',
              statusCode: 204,
              headers: {'x-head': 'yes'},
            );
          },
        ),
      );
      expect(head, '204:yes');
      expect(headRequest?.method, 'HEAD');

      final redirected = await evaluator.evaluateAsync(
        "java.connect('/redirect').raw().request().url()",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async => SourceScriptNetworkResult(
            body: 'ok',
            finalUrl: 'https://network.test/final',
          ),
        ),
      );
      expect(redirected, 'https://network.test/final');

      SourceScriptNetworkRequest? browserRequest;
      final browserHtml = await evaluator.evaluateAsync(
        "java.webView('<p>seed</p>', '/render', 'document.body.dataset.ready=1')",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async {
            browserRequest = request;
            return const SourceScriptNetworkResult(
              body: '<html>rendered</html>',
              finalUrl: 'https://network.test/render',
            );
          },
        ),
      );
      expect(browserHtml, '<html>rendered</html>');
      expect(browserRequest?.method, 'WEBVIEW');
      expect(browserRequest?.body, '<p>seed</p>');
      expect(browserRequest?.webJs, 'document.body.dataset.ready=1');
    },
  );

  test('concurrent source scripts keep network contexts isolated', () async {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final first = ReadingSourceConfig.fromJson({
      'bookSourceName': 'First',
      'bookSourceUrl': 'https://first.test',
    });
    final second = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Second',
      'bookSourceUrl': 'https://second.test',
    });

    final values = await Future.wait([
      evaluator.evaluateAsync(
        "source.getKey() + ':' + java.ajax('/value')",
        SourceScriptContext(
          source: first,
          networkHandler: (request) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return const SourceScriptNetworkResult(
              body: 'one',
              finalUrl: 'https://first.test/value',
            );
          },
        ),
      ),
      evaluator.evaluateAsync(
        "source.getKey() + ':' + java.ajax('/value')",
        SourceScriptContext(
          source: second,
          networkHandler: (request) async => const SourceScriptNetworkResult(
            body: 'two',
            finalUrl: 'https://second.test/value',
          ),
        ),
      ),
    ]);

    expect(values, ['https://first.test:one', 'https://second.test:two']);
  });

  test(
    'interactive source calls pause once and resume with host results',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Interactive source',
        'bookSourceUrl': 'https://verify.test',
      });
      final requests = <SourceScriptInteractionRequest>[];

      final browserValue = await evaluator.evaluateAsync(
        "var response=java.startBrowserAwait('/gate','Check',false); "
        "response.url()+':' + response.body()+':' + response.cookies().sid",
        SourceScriptContext(
          source: source,
          interactionHandler: (request) async {
            requests.add(request);
            return const SourceScriptInteractionResult(
              body: '<html>ready</html>',
              finalUrl: 'https://verify.test/ready',
              cookieHeader: 'sid=ok',
            );
          },
        ),
      );

      expect(browserValue, 'https://verify.test/ready:<html>ready</html>:ok');
      expect(requests, hasLength(1));
      expect(requests.single.kind, SourceScriptInteractionKind.browserAwait);
      expect(requests.single.url, '/gate');

      final code = await evaluator.evaluateAsync(
        "java.getVerificationCode('/image') + '-accepted'",
        SourceScriptContext(
          source: source,
          interactionHandler: (request) async {
            requests.add(request);
            return const SourceScriptInteractionResult(value: '7391');
          },
        ),
      );
      expect(code, '7391-accepted');
      expect(requests.last.kind, SourceScriptInteractionKind.verificationCode);
    },
  );

  test(
    'cancelled interactive source calls unblock with a clear error',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Cancelled source',
        'bookSourceUrl': 'https://cancel.test',
      });

      await expectLater(
        evaluator.evaluateAsync(
          "java.startBrowserAwait('/gate','Check')",
          SourceScriptContext(
            source: source,
            interactionHandler: (_) async =>
                const SourceScriptInteractionResult(cancelled: true),
          ),
        ),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
    },
  );

  test(
    'failed asynchronous scripts do not poison the serialized queue',
    () async {
      final evaluator = QuickJsSourceScriptEvaluator();
      addTearDown(evaluator.dispose);
      final source = ReadingSourceConfig.fromJson({
        'bookSourceName': 'Queue source',
        'bookSourceUrl': 'https://queue.test',
      });

      await expectLater(
        evaluator.evaluateAsync(
          'throw new Error("broken")',
          SourceScriptContext(source: source),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
      await expectLater(
        evaluator.evaluateAsync('40 + 2', SourceScriptContext(source: source)),
        completion(42),
      );
    },
  );

  test('network replay limit keeps its exact error contract', () async {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Limited source',
      'bookSourceUrl': 'https://limit.test',
    });

    await expectLater(
      evaluator.evaluateAsync(
        "for (var i=0;i<13;i++) java.ajax('/' + i); 'done'",
        SourceScriptContext(
          source: source,
          networkHandler: (request) async => SourceScriptNetworkResult(
            body: request.url,
            finalUrl: request.url,
          ),
        ),
      ),
      throwsA(
        isA<BookSourceProtocolException>().having(
          (error) => error.message,
          'message',
          'Source script exceeded the network request limit.',
        ),
      ),
    );
  });

  test('bootstrap safely embeds scripts containing quotes and delimiters', () {
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Escaping source',
      'bookSourceUrl': 'https://escaping.test',
    });
    final payload = SourceScriptBootstrap.payload(
      "'quote: \\' and </script> and \\n newline'",
      SourceScriptContext(source: source),
      SourceScriptState(),
    );
    final bootstrap = SourceScriptBootstrap.build(payload);

    expect(bootstrap, contains(r'\\n'));
    expect(bootstrap, isNot(contains(r'<\/script>')));
    expect(bootstrap, contains(jsonEncode(payload)));
  });

  test('host router rejects malformed and unknown messages', () {
    final host = SourceScriptHostApi();

    expect(host.handle(null), isNull);
    expect(host.handle('invalid'), isNull);
    expect(host.handle(const {'op': 'unknown', 'args': []}), isNull);
  });

  test('script cache state expires values and preserves unexpired values', () {
    final state = SourceScriptState();
    final now = DateTime(2026, 1, 1);
    state.cache['expired'] = SourceScriptCacheEntry(
      value: 'old',
      expiresAt: now.subtract(const Duration(seconds: 1)),
    );
    state.cache['fresh'] = SourceScriptCacheEntry(
      value: {'nested': 7},
      expiresAt: now.add(const Duration(seconds: 1)),
    );

    expect(state.readCache('expired', now), isNull);
    expect(state.cache, isNot(contains('expired')));
    expect(state.readCache('fresh', now), {'nested': 7});
  });

  test('pure crypto and text host APIs retain known vectors', () {
    const crypto = SourceScriptCryptoApi();
    const text = SourceScriptTextApi();

    expect(
      crypto.handle('digestHex', ['abc', 'sha256']),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      crypto.handle('hmacHex', ['data', 'HmacSHA256', 'key']),
      '5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0',
    );
    expect(text.handle('toNumChapter', ['第十二章']), '第12章');
    expect(text.handle('traditionalToSimplified', ['韓漫與熱門漫畫']), '韩漫与热门漫画');
  });
}
