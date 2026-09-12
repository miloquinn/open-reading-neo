import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_browser_session.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_http_transport.dart';
import 'package:xxread/book_sources/source_engine/source_interaction_coordinator.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_contract.dart';

void main() {
  test(
    'website login persists cookies and local storage for WebView reuse',
    () async {
      final store = _MemoryLoginSessionStore();
      final browser = _BrowserClient(
        openResult: _browserResult(_signedInSession),
      );
      final harness = _runtime(store: store, browser: browser);
      addTearDown(harness.close);

      await harness.runtime.login(_source, const {});

      final saved = store.values[_source.id];
      expect(saved?.browserSession.active, isTrue);
      expect(saved?.browserSession.cookies, _signedInSession.cookies);
      expect(saved?.browserSession.localStorage, _signedInSession.localStorage);

      await harness.runtime.getBook(
        _source,
        'https://reader.example.test/private/web,{"webView":true}',
      );

      expect(browser.loadedSessions, hasLength(1));
      expect(
        browser.loadedSessions.single.localStorage,
        _signedInSession.localStorage,
      );
    },
  );

  test(
    'a rebuilt runtime restores cookies with domain path and secure rules',
    () async {
      final store = _MemoryLoginSessionStore();
      final loginBrowser = _BrowserClient(
        openResult: _browserResult(_signedInSession),
      );
      final loginHarness = _runtime(store: store, browser: loginBrowser);
      await loginHarness.runtime.login(_source, const {});
      loginHarness.close();

      final restored = _runtime(store: store, browser: _BrowserClient());
      addTearDown(restored.close);

      await restored.runtime.getBook(
        _source,
        'https://reader.example.test/private/book',
      );
      await restored.runtime.getBook(
        _source,
        'https://child.example.test/private/book',
      );
      await restored.runtime.getBook(
        _source,
        'http://reader.example.test/private/book',
      );

      expect(
        _cookie(restored.adapter.requests[0]),
        allOf(contains('parent=p'), contains('scoped=s'), contains('plain=n')),
      );
      expect(_cookie(restored.adapter.requests[0]), isNot(contains('wrong=w')));
      expect(_cookie(restored.adapter.requests[1]), 'parent=p');
      expect(_cookie(restored.adapter.requests[2]), 'plain=n');
    },
  );

  test('cancelling website login preserves the previous session', () async {
    final store = _MemoryLoginSessionStore()
      ..values[_source.id] = const SourceLoginSession(
        browserSession: SourceBrowserSession(
          active: true,
          cookies: [
            {
              'name': 'old',
              'value': 'kept',
              'domain': 'reader.example.test',
              'path': '/',
            },
          ],
          localStorage: {
            'https://reader.example.test': {'token': 'old-token'},
          },
        ),
      );
    final browser = _BrowserClient(cancelOpen: true);
    final harness = _runtime(store: store, browser: browser);
    addTearDown(harness.close);

    await expectLater(
      harness.runtime.login(_source, const {}),
      throwsA(isA<SourceBrowserCancelled>()),
    );

    final saved = store.values[_source.id]!.browserSession;
    expect(saved.cookies.single['value'], 'kept');
    expect(
      saved.localStorage['https://reader.example.test']?['token'],
      'old-token',
    );
  });

  test('clearing login removes persisted and active website state', () async {
    final store = _MemoryLoginSessionStore();
    final browser = _BrowserClient(
      openResult: _browserResult(_signedInSession),
    );
    final harness = _runtime(store: store, browser: browser);
    addTearDown(harness.close);
    await harness.runtime.login(_source, const {});

    await harness.runtime.clearLoginSession(_source);

    expect(store.values, isNot(contains(_source.id)));
    expect(browser.clearedSourceIds, [_source.id]);
    expect(harness.transport.browserSession(_source.id).active, isFalse);
    expect(harness.transport.browserSession(_source.id).cookies, isEmpty);

    await harness.runtime.getBook(
      _source,
      'https://reader.example.test/private/after-clear',
    );
    expect(_cookie(harness.adapter.requests.single), isNull);
  });

  test(
    '401 requests explain re-login and persist server cookie deletion',
    () async {
      final store = _MemoryLoginSessionStore();
      final harness = _runtime(
        store: store,
        browser: _BrowserClient(openResult: _browserResult(_signedInSession)),
      );
      addTearDown(harness.close);
      await harness.runtime.login(_source, const {});
      await expectLater(
        harness.runtime.getBook(_source, 'https://reader.example.test/expired'),
        throwsA(predicate((error) => '$error'.contains('requires login'))),
      );
      expect(
        store.values[_source.id]!.browserSession.cookies.where(
          (cookie) => cookie['name'] == 'parent',
        ),
        isEmpty,
      );
    },
  );

  test(
    'a browser result arriving after clear cannot restore the session',
    () async {
      final store = _MemoryLoginSessionStore();
      final pending = Completer<SourceBrowserResult>();
      final browser = _BrowserClient(openFuture: pending.future);
      final harness = _runtime(store: store, browser: browser);
      addTearDown(harness.close);

      final login = harness.runtime.login(_source, const {});
      await browser.opened.future;
      await harness.runtime.clearLoginSession(_source);
      pending.complete(_browserResult(_signedInSession));

      await expectLater(login, throwsA(isA<SourceBrowserCancelled>()));
      expect(store.values, isNot(contains(_source.id)));
      expect(harness.transport.browserSession(_source.id).active, isFalse);
      expect(harness.transport.browserSession(_source.id).cookies, isEmpty);
    },
  );

  test(
    'browser-await returning after clear cannot recreate the session',
    () async {
      final store = _MemoryLoginSessionStore();
      final coordinator = _DeferredCoordinator();
      final harness = _runtime(
        store: store,
        browser: _BrowserClient(),
        coordinator: coordinator,
      );
      addTearDown(harness.close);

      final search = harness.runtime.search(_interactiveSource, 'query');
      await coordinator.requested.future;
      await harness.runtime.clearLoginSession(_interactiveSource);
      coordinator.complete(
        const SourceScriptInteractionResult(
          finalUrl: 'https://reader.example.test/after-login',
          browserSession: _browserTokenSession,
        ),
      );

      await expectLater(search, throwsA(isA<SourceBrowserCancelled>()));
      expect(store.values, isNot(contains(_interactiveSource.id)));
      expect(
        harness.transport.browserSession(_interactiveSource.id).active,
        isFalse,
      );
    },
  );

  test('script local storage delta preserves a new browser token', () async {
    final store = _MemoryLoginSessionStore();
    final coordinator = _DeferredCoordinator();
    final harness = _runtime(
      store: store,
      browser: _BrowserClient(),
      coordinator: coordinator,
    );
    addTearDown(harness.close);

    final search = harness.runtime.search(_interactiveSource, 'query');
    await coordinator.requested.future;
    coordinator.complete(
      const SourceScriptInteractionResult(
        finalUrl: 'https://reader.example.test/after-login',
        browserSession: _browserTokenSession,
      ),
    );
    await search;

    final storage = store
        .values[_interactiveSource.id]!
        .browserSession
        .localStorage['https://reader.example.test'];
    expect(storage?['access_token'], 'browser-token');
    expect(storage?['preference'], 'new');
    expect(storage?['seen_token'], 'browser-token');
  });
}

final _source = ReadingSourceConfig.fromJson({
  'bookSourceName': 'Website session source',
  'bookSourceUrl': 'https://reader.example.test',
  'loginUrl': '/login',
  'ruleBookInfo': {'name': 'h1@text'},
}).toRegisteredSource(enabled: true);

final _interactiveSource = ReadingSourceConfig.fromJson({
  'bookSourceName': 'Interactive website session source',
  'bookSourceUrl': 'https://reader.example.test',
  'searchUrl':
      "@js:java.startBrowserAwait('/gate','Sign in',false); "
      "localStorage.setItem('seen_token', localStorage.getItem('access_token')); "
      "localStorage.setItem('preference','new'); '/search?q=' + key",
  'ruleSearch': {'bookList': 'class.book', 'name': 'text', 'bookUrl': 'href'},
}).toRegisteredSource(enabled: true);

const _browserTokenSession = SourceBrowserSession(
  active: true,
  localStorage: {
    'https://reader.example.test': {'access_token': 'browser-token'},
  },
);

const _signedInSession = SourceBrowserSession(
  active: true,
  cookies: [
    {
      'name': 'parent',
      'value': 'p',
      'domain': 'example.test',
      'path': '/',
      'secure': true,
      'hostOnly': false,
    },
    {
      'name': 'scoped',
      'value': 's',
      'domain': 'reader.example.test',
      'path': '/private',
      'secure': true,
      'hostOnly': true,
    },
    {
      'name': 'plain',
      'value': 'n',
      'domain': 'reader.example.test',
      'path': '/private',
      'secure': false,
      'hostOnly': true,
    },
    {
      'name': 'wrong',
      'value': 'w',
      'domain': 'reader.example.test',
      'path': '/other',
      'secure': false,
      'hostOnly': true,
    },
  ],
  localStorage: {
    'https://reader.example.test': {
      'access_token': 'local-token',
      'profile': '{"id":7}',
    },
  },
);

SourceBrowserResult _browserResult(SourceBrowserSession session) =>
    SourceBrowserResult(
      body: '<html><h1>Signed in</h1></html>',
      finalUri: Uri.parse('https://reader.example.test/account'),
      session: session,
    );

({
  SourceRuntime runtime,
  SourceHttpTransport transport,
  _RecordingAdapter adapter,
  void Function() close,
})
_runtime({
  required _MemoryLoginSessionStore store,
  required _BrowserClient browser,
  SourceInteractionCoordinatorPort? coordinator,
}) {
  final adapter = _RecordingAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final transport = SourceHttpTransport(
    dio: dio,
    browserClient: browser,
    networkPolicy: BookSourceNetworkPolicy(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    ),
  );
  final runtime = SourceRuntime(
    transport: transport,
    loginSessionStore: store,
    browserClient: browser,
    interactionCoordinator: coordinator,
  );
  return (
    runtime: runtime,
    transport: transport,
    adapter: adapter,
    close: runtime.close,
  );
}

String? _cookie(RequestOptions request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == HttpHeaders.cookieHeader) {
      return '${entry.value}';
    }
  }
  return null;
}

class _BrowserClient extends SourceBrowserSessionClient {
  _BrowserClient({this.openResult, this.openFuture, this.cancelOpen = false});

  final SourceBrowserResult? openResult;
  final Future<SourceBrowserResult>? openFuture;
  final bool cancelOpen;
  final Completer<void> opened = Completer<void>();
  final List<String> clearedSourceIds = [];
  final List<SourceBrowserSession> loadedSessions = [];

  @override
  Future<SourceBrowserResult> open({
    required String sourceId,
    required Uri url,
    required Map<String, String> headers,
    required SourceBrowserSession session,
    String? title,
    String? html,
  }) async {
    if (!opened.isCompleted) opened.complete();
    if (cancelOpen) throw const SourceBrowserCancelled();
    final pending = openFuture;
    if (pending != null) return pending;
    return openResult ?? _browserResult(session.copyWith(active: true));
  }

  @override
  Future<SourceBrowserResult> load({
    required String sourceId,
    required Uri url,
    required Map<String, String> headers,
    required SourceBrowserSession session,
    required String method,
    String? body,
    String? webJs,
    String? html,
    BookDownloadCancellation? cancellation,
  }) async {
    loadedSessions.add(session);
    return SourceBrowserResult(
      body: '<html><h1>Background page</h1></html>',
      finalUri: url,
      session: session,
    );
  }

  @override
  Future<void> clear(String sourceId) async {
    clearedSourceIds.add(sourceId);
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

class _DeferredCoordinator implements SourceInteractionCoordinatorPort {
  final Completer<void> requested = Completer<void>();
  final Completer<SourceScriptInteractionResult> _result = Completer();

  void complete(SourceScriptInteractionResult result) {
    _result.complete(result);
  }

  @override
  Future<SourceScriptInteractionResult> request({
    required String sourceId,
    required String sourceName,
    required SourceScriptInteractionRequest interaction,
    Duration timeout = const Duration(minutes: 5),
    BookDownloadCancellation? cancellation,
  }) {
    if (!requested.isCompleted) requested.complete();
    return _result.future;
  }
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.path == '/expired') {
      return ResponseBody.fromString(
        'Login required',
        401,
        headers: {
          HttpHeaders.setCookieHeader: [
            'parent=; Domain=.example.test; Path=/; Max-Age=0',
          ],
        },
      );
    }
    final body = options.uri.path == '/search'
        ? '<html><a class="book" href="/book/1">Found</a></html>'
        : '<html><h1>Book title</h1></html>';
    return ResponseBody.fromString(
      body,
      HttpStatus.ok,
      headers: {
        HttpHeaders.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
