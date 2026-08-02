import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';
import 'package:xxread/book_sources/source_engine/source_script_engine.dart';

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
}
