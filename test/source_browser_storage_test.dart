import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_browser_session.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_cookie_jar.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_script_engine.dart';

void main() {
  test('cookie request headers retain same-name cookies in path order', () {
    final jar = SourceCookieJar();
    jar.store(
      'source',
      Uri.parse('https://books.test/account/login'),
      Headers.fromMap({
        HttpHeaders.setCookieHeader: [
          'sid=root; Path=/',
          'sid=account; Path=/account',
        ],
      }),
    );
    expect(
      SourceCookieJar.mergeHeaders(
        'sid=configured; theme=dark',
        jar.header('source', Uri.parse('https://books.test/account/read')),
      ),
      'sid=account; sid=root; theme=dark',
    );
  });
  test('invalid cookie expiry degrades to a usable session cookie', () {
    final jar = SourceCookieJar();
    final uri = Uri.parse('https://books.test/login');
    jar.store(
      'source',
      uri,
      Headers.fromMap({
        HttpHeaders.setCookieHeader: [
          'qttoken=secret; Path=/; Expires=Tue, 09 Sep 2036 13:49:33 UTC; HttpOnly',
        ],
      }),
    );

    expect(jar.header('source', uri), 'qttoken=secret');
    expect(
      jar.exportCookies('source').single['expiresAt'],
      DateTime.utc(2036, 9, 9, 13, 49, 33).millisecondsSinceEpoch,
    );
  });
  test('website URL detection rejects scripts and unsafe schemes', () {
    final config = {'bookSourceUrl': 'https://books.test'};
    for (final value in [
      'function login(){}',
      '@js:login()',
      'javascript:login()',
      'https://user:pass@books.test',
    ]) {
      expect(sourceBrowserLoginUri({...config, 'loginUrl': value}), isNull);
    }
    expect(
      sourceBrowserLoginUri({...config, 'loginUrl': '/login'})?.toString(),
      'https://books.test/login',
    );
    expect(
      sourceBrowserLoginUri({
        ...config,
        'loginUrl': 'https://account.test/login',
      })?.host,
      'account.test',
    );
  });

  test('secure session round trip keeps origins and cookie attributes', () {
    final jar = SourceCookieJar(clock: () => DateTime.utc(2026));
    jar.store(
      'one',
      Uri.parse('https://books.test/account/login'),
      Headers.fromMap({
        HttpHeaders.setCookieHeader: [
          'sid=secret; Domain=.books.test; Path=/account; Secure; HttpOnly; Max-Age=60; SameSite=Lax',
        ],
      }),
    );
    final saved = SourceLoginSession(
      browserSession: SourceBrowserSession(
        active: true,
        cookies: jar.exportCookies('one'),
        localStorage: const {
          'https://books.test': {'token': 'one'},
          'https://accounts.test': {'token': 'two'},
        },
      ),
    );
    final restored = SourceLoginSession.fromJson(
      jsonDecode(jsonEncode(saved.toJson())),
    );
    final cookie = restored.browserSession.cookies.single;
    expect(cookie['httpOnly'], isTrue);
    expect(cookie['secure'], isTrue);
    expect(cookie['hostOnly'], isFalse);
    expect(cookie['sameSite'], 'Lax');
    expect(
      cookie['expiresAt'],
      DateTime.utc(
        2026,
      ).add(const Duration(seconds: 60)).millisecondsSinceEpoch,
    );
    expect(
      restored.browserSession.localStorage,
      saved.browserSession.localStorage,
    );
    final next = SourceCookieJar(clock: () => DateTime.utc(2026));
    next.restoreCookies('one', restored.browserSession.cookies);
    expect(
      next.header('one', Uri.parse('https://child.books.test/account/a')),
      'sid=secret',
    );
    expect(
      next.header('one', Uri.parse('https://books.test/accounts')),
      isNull,
    );
    expect(next.header('two', Uri.parse('https://books.test/account')), isNull);
    expect(next.header('one', Uri.parse('http://books.test/account')), isNull);
  });

  test('expired cookies and invalid origins are not restored', () {
    final snapshot = SourceBrowserSession.fromJson({
      'localStorage': {
        'file:///etc': {'token': 'bad'},
        'https://books.test/path': {'a': 'ok'},
      },
      'cookies': [
        {'name': 'old', 'value': '1', 'domain': 'books.test', 'expiresAt': 1},
      ],
    });
    final jar = SourceCookieJar()..restoreCookies('one', snapshot.cookies);
    expect(jar.exportCookies('one'), isEmpty);
    expect(snapshot.localStorage.keys, ['https://books.test']);
    expect(
      SourceLoginSession.fromJson({
        'loginInfo': {'user': 'old'},
      }).browserSession.active,
      isFalse,
    );
  });

  test('source scripts read and update origin-scoped local storage', () {
    final evaluator = QuickJsSourceScriptEvaluator();
    addTearDown(evaluator.dispose);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': 'Session',
      'bookSourceUrl': 'https://books.test',
    });
    Map<String, Map<String, String>>? written;
    final context = SourceScriptContext(
      source: source,
      browserLocalStorage: const {
        'https://books.test': {'token': 'reader'},
        'https://login.test': {'token': 'account'},
      },
      localStorageWriter: (value, _) => written = value,
    );
    expect(
      evaluator.evaluate(
        "localStorage.getItem('token') + ':' + source.getLocalStorage('https://login.test').get('token')",
        context,
      ),
      'reader:account',
    );
    expect(
      written,
      isNull,
      reason: 'Reading must not overwrite a newly refreshed browser session.',
    );
    evaluator.evaluate(
      "localStorage.setItem('token', 'refreshed'); localStorage.setItem('__proto__', 'literal');",
      context,
    );
    expect(written?['https://books.test']?['token'], 'refreshed');
    expect(written?['https://books.test']?['__proto__'], 'literal');
    expect(written?['https://login.test']?['token'], 'account');
    evaluator.evaluate('localStorage.clear()', context);
    expect(written?['https://books.test'], isEmpty);
    expect(written?['https://login.test']?['token'], 'account');
  });
}
