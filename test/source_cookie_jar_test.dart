import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_cookie_jar.dart';

void main() {
  group('SourceCookieJar', () {
    test('matches domain, secure, and longest paths', () {
      final jar = SourceCookieJar();
      final headers = Headers.fromMap({
        HttpHeaders.setCookieHeader: [
          'root=1; Domain=.books.test; Path=/',
          'section=2; Domain=.books.test; Path=/books/',
          'secure=3; Domain=.books.test; Path=/; Secure',
          'foreign=4; Domain=other.test; Path=/',
        ],
      });

      jar.store('source', Uri.parse('https://books.test/books/start'), headers);

      expect(
        jar.scriptCookieHeader(
          'source',
          Uri.parse('https://cdn.books.test/books/chapter'),
        ),
        'section=2; root=1; secure=3',
      );
      expect(
        jar.scriptCookieHeader(
          'source',
          Uri.parse('http://cdn.books.test/books/chapter'),
        ),
        'section=2; root=1',
      );
    });

    test('expires max-age cookies using the injected clock', () {
      var now = DateTime.utc(2026, 1, 1);
      final jar = SourceCookieJar(clock: () => now);
      jar.store(
        'source',
        Uri.parse('https://books.test/path'),
        Headers.fromMap({
          HttpHeaders.setCookieHeader: ['session=ready; Max-Age=10; Path=/'],
        }),
      );

      expect(
        jar.scriptCookieHeader('source', Uri.parse('https://books.test/')),
        'session=ready',
      );
      now = now.add(const Duration(seconds: 11));
      expect(
        jar.scriptCookieHeader('source', Uri.parse('https://books.test/')),
        isEmpty,
      );
    });

    test('merges stored cookies over configured values by name', () {
      expect(
        SourceCookieJar.mergeHeaders('sid=configured; theme=light', 'sid=jar'),
        'sid=jar; theme=light',
      );
    });
  });
}
