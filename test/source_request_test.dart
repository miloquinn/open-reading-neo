import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
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

    for (final (index, body) in <Object>[
      {'query': '剑来', 'page': 2},
      [
        {'id': 1},
        {'id': 2},
      ],
      '{"query":"剑来"}',
      '[1,2]',
    ].indexed) {
      test('serializes JSON POST body case $index', () {
        final request = SourceRequestTemplate.parse(
          '/search,${jsonEncode({'method': 'POST', 'body': body})}',
          baseUri: Uri.parse('https://books.test/'),
        );
        expect(request.body, body is String ? body : jsonEncode(body));
        expect(
          request.headers['Content-Type'],
          'application/json; charset=utf-8',
        );
      });
    }

    test('keeps nested option delimiters when resolving a relative target', () {
      final options = jsonEncode({
        'method': 'POST',
        'body': [
          {'nested': 'value,{'},
          {'second': true},
        ],
      });
      final target = resolveSourceRequestUrl(
        Uri.parse('https://books.test/catalog/'),
        '../search,$options',
      );
      expect(target, 'https://books.test/search,$options');
      expect(
        SourceRequestTemplate.parse(
          target,
          baseUri: Uri.parse('https://other.test/'),
        ).url,
        Uri.parse('https://books.test/search'),
      );
    });

    test('preserves explicit content type and malformed JSON as form text', () {
      final explicit = SourceRequestTemplate.parse(
        '/search,${jsonEncode({
          'method': 'POST',
          'body': {'query': 'book'},
          'headers': {'content-type': 'application/custom'},
        })}',
        baseUri: Uri.parse('https://books.test/'),
      );
      expect(explicit.headers['content-type'], 'application/custom');
      expect(explicit.headers.containsKey('Content-Type'), isFalse);
      final form = SourceRequestTemplate.parse(
        '/search,${jsonEncode({'method': 'POST', 'body': '{query=book'})}',
        baseUri: Uri.parse('https://books.test/'),
      );
      expect(form.body, '{query=book');
      expect(
        form.headers['Content-Type'],
        'application/x-www-form-urlencoded; charset=utf-8',
      );
    });

    test('ignores structured bodies for GET and HEAD like AnalyzeUrl', () {
      for (final method in ['GET', 'HEAD']) {
        final request = SourceRequestTemplate.parse(
          '/search,${jsonEncode({
            'method': method,
            'body': {'unused': true},
          })}',
          baseUri: Uri.parse('https://books.test/'),
        );
        expect(request.body, isNull);
        expect(request.headers.containsKey('Content-Type'), isFalse);
      }
    });

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

    test('expands page alternatives, arithmetic, and encoded query values', () {
      final request = SourceRequestTemplate.parse(
        '/<first,next,last>?offset={{(page-1)*20}}&q={{key}}',
        baseUri: Uri.parse('https://books.test'),
        variables: const {'page': '4', 'key': '剑 来'},
      );

      expect(
        request.url,
        Uri.parse('https://books.test/last?offset=60&q=%E5%89%91+%E6%9D%A5'),
      );
    });

    test('preserves exact unsupported-expression error', () {
      expect(
        () => SourceRequestTemplate.parse(
          '/search?q={{unknown}}',
          baseUri: Uri.parse('https://books.test'),
        ),
        throwsA(
          isA<BookSourceProtocolException>().having(
            (error) => error.message,
            'message',
            'reading source request contains an unsupported template expression.',
          ),
        ),
      );
    });
  });
}
