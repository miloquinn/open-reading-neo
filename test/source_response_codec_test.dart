import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:xxread/book_sources/source_engine/source_response_codec.dart';

void main() {
  group('SourceResponseCodec', () {
    test('encodes configured request charsets', () {
      expect(
        SourceResponseCodec.encode('剑来', 'gb2312'),
        gbk_bytes.encode('剑来'),
      );
      expect(SourceResponseCodec.encode('剑来', 'utf-8'), utf8.encode('剑来'));
    });

    test('uses a supported response charset over the configured charset', () {
      final headers = Headers.fromMap({
        HttpHeaders.contentTypeHeader: ['text/plain; charset=gb18030'],
      });

      expect(
        SourceResponseCodec.decode(gbk_bytes.encode('结果'), 'utf-8', headers),
        '结果',
      );
    });

    test('decodes malformed UTF-8 without throwing', () {
      expect(
        SourceResponseCodec.decode(
          const [0x61, 0xE2, 0x82],
          'utf-8',
          Headers(),
        ),
        'a\uFFFD',
      );
    });

    test('normalizes response headers and response cookies', () {
      final headers = Headers.fromMap({
        'X-Source': ['one', 'two'],
        HttpHeaders.setCookieHeader: ['sid=abc; Path=/'],
      });

      expect(
        SourceResponseCodec.responseHeaders(headers)['x-source'],
        'one, two',
      );
      expect(SourceResponseCodec.responseCookies(headers), {'sid': 'abc'});
      expect(SourceResponseCodec.cookieMapFromHeader('sid=abc; theme=dark'), {
        'sid': 'abc',
        'theme': 'dark',
      });
    });

    test('preserves malformed Set-Cookie failures', () {
      final headers = Headers.fromMap({
        HttpHeaders.setCookieHeader: ['malformed'],
      });

      expect(
        () => SourceResponseCodec.responseCookies(headers),
        throwsA(isA<HttpException>()),
      );
    });
  });
}
