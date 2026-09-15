import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_http_transport.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  test(
    'source feedback is returned instead of claiming login succeeded',
    () async {
      final runtime = _runtime(_Store(), _Adapter());
      addTearDown(runtime.close);
      final source = ReadingSourceConfig.fromJson({
        ..._source.sourceConfig!,
        'loginUrl':
            'function login() { java.toast("Signing in"); java.longToast("Credentials rejected"); }',
      }).toRegisteredSource();
      expect(await runtime.login(source, const {}), 'Credentials rejected');
    },
  );
  test(
    'opaque login token survives restart, settings, and dynamic headers',
    () async {
      final source = ReadingSourceConfig.fromJson({
        ..._source.sourceConfig!,
        'loginUrl':
            'function login() { source.putLoginHeader("opaque-test-token"); }',
        'header':
            '@js: JSON.stringify({"X-Api-Key": java.base64Encode(source.getLoginHeader())})',
      }).toRegisteredSource();
      final store = _Store();
      final adapter = _Adapter();
      var runtime = _runtime(store, adapter);
      addTearDown(() => runtime.close());
      await runtime.login(source, const {});
      expect(store.value.rawLoginHeader, 'opaque-test-token');
      expect(store.value.loginHeaders, isEmpty);
      runtime.close();
      runtime = _runtime(store, adapter);
      await runtime.login(source, const {}, action: 'true;');
      expect(store.value.rawLoginHeader, 'opaque-test-token');
      await runtime.search(source, 'test');
      expect(
        adapter.requests.last.headers['X-Api-Key'],
        base64Encode(utf8.encode('opaque-test-token')),
      );
      expect(
        adapter.requests.last.headers.containsKey('opaque-test-token'),
        isFalse,
      );
      await runtime.clearLoginSession(source);
      expect(store.value.rawLoginHeader, isNull);
      await runtime.search(source, 'after clear');
      expect(adapter.requests.last.headers['X-Api-Key'], '');
    },
  );

  test(
    'explicit script cookies survive login and restart with automatic jar disabled',
    () async {
      final store = _Store();
      final adapter = _Adapter();
      var runtime = _runtime(store, adapter);
      addTearDown(() => runtime.close());
      await runtime.login(_source, {
        'email': 'reader@example.test',
        'password': 'test-only',
      });
      expect(store.value.browserSession.cookies, hasLength(2));
      expect(store.value.browserSession.active, isFalse);

      runtime.close();
      runtime = _runtime(store, adapter);
      final found = await runtime.search(_source, 'book');
      expect(found.items.single.title, 'A book');
      expect(
        adapter.requests.last.headers['Cookie'],
        'qttoken=test-token; deviceId=test-device',
      );
      await runtime.getBook(_source, 'https://books.test/plain');
      expect(
        adapter.requests.last.headers['Cookie'],
        isNull,
        reason:
            'Explicit script cookies must not enable automatic HTTP cookies.',
      );

      await runtime.clearLoginSession(_source);
      await runtime.search(_source, 'book');
      expect(adapter.requests.last.headers['Cookie'] ?? '', isEmpty);
      expect(store.value.browserSession.cookies, isEmpty);
    },
  );

  test(
    'a rejected API login surfaces the error without a saved token',
    () async {
      final store = _Store();
      final runtime = _runtime(store, _Adapter(rejectLogin: true));
      addTearDown(runtime.close);
      await expectLater(
        runtime.login(_source, {
          'email': 'reader@example.test',
          'password': 'wrong',
        }),
        throwsA(
          predicate((error) => '$error'.contains('Credentials rejected')),
        ),
      );
      expect(store.value.browserSession.cookies, isEmpty);
    },
  );

  test(
    'loading a login form restores saved values over source defaults',
    () async {
      final store = _Store()
        ..value = const SourceLoginSession(
          loginInfo: {'email': 'saved@example.test'},
        );
      final runtime = _runtime(store, _Adapter());
      addTearDown(runtime.close);
      final fields = await runtime.loadLoginFields(_source);
      expect(fields.first.defaultValue, 'saved@example.test');
      expect(fields.last.defaultValue, isNull);
    },
  );

  test(
    'dynamic and structured login forms share saved-value restoration',
    () async {
      for (final ui in <Object>[
        [
          {'name': 'email', 'type': 'text'},
        ],
        '@js: JSON.stringify([{name: "email", type: "text"}])',
      ]) {
        final source = ReadingSourceConfig.fromJson({
          ..._source.sourceConfig!,
          'loginUi': ui,
        }).toRegisteredSource(enabled: true);
        final store = _Store()
          ..value = const SourceLoginSession(
            loginInfo: {'email': 'saved@example.test'},
          );
        final runtime = _runtime(store, _Adapter());
        try {
          expect(
            (await runtime.loadLoginFields(source)).single.defaultValue,
            'saved@example.test',
          );
        } finally {
          runtime.close();
        }
      }
    },
  );

  test('a settings action preserves existing login headers', () async {
    final store = _Store()
      ..value = const SourceLoginSession(
        loginHeaders: {'Authorization': 'Bearer previous'},
      );
    final adapter = _Adapter();
    final runtime = _runtime(store, adapter);
    addTearDown(runtime.close);
    await runtime.login(_source, const {}, action: 'true;');
    expect(store.value.loginHeaders, {'Authorization': 'Bearer previous'});
    await runtime.clearLoginSession(_source);
    await runtime.search(_source, 'after clear');
    expect(store.value.loginHeaders, isEmpty);
    expect(store.value.loginInfo, isEmpty);
    expect(adapter.requests.last.headers['Authorization'], isNull);
  });
}

final _source = ReadingSourceConfig.fromJson({
  'bookSourceName': 'Script login fixture',
  'bookSourceUrl': 'https://books.test',
  'enabledCookieJar': false,
  'loginUi':
      '[{"name":"email","type":"text","default":"default@example.test"},{"name":"password","type":"password"}]',
  'loginUrl': r'''
function login() {
  const data = JSON.parse(java.ajax('https://books.test/login_api,' + JSON.stringify({
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({register_email: result.email, password: result.password})
  })));
  if (data.code !== 0) throw new Error(data.msg);
  cookie.setCookie('https://books.test', 'qttoken=' + data.key + ';deviceId=test-device');
}
''',
  'searchUrl':
      r'''@js: 'https://books.test/search,' + JSON.stringify({headers: {Cookie: cookie.getCookie('https://books.test')}})''',
  'ruleSearch': {'bookList': r'$.data', 'name': r'$.name', 'bookUrl': r'$.url'},
  'ruleBookInfo': {'name': r'$.name'},
}).toRegisteredSource(enabled: true);

SourceRuntime _runtime(_Store store, _Adapter adapter) => SourceRuntime(
  loginSessionStore: store,
  transport: SourceHttpTransport(
    dio: Dio()..httpClientAdapter = adapter,
    networkPolicy: BookSourceNetworkPolicy(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    ),
  ),
);

class _Store implements SourceLoginSessionStore {
  SourceLoginSession value = const SourceLoginSession();
  @override
  Future<SourceLoginSession> read(String sourceId) async => value;
  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    value = SourceLoginSession.fromJson(
      jsonDecode(jsonEncode(session.toJson())),
    );
  }

  @override
  Future<void> clear(String sourceId) async {
    value = const SourceLoginSession();
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.rejectLogin = false});
  final bool rejectLogin;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        options.uri.path == '/login_api'
            ? (rejectLogin
                  ? {'code': 1, 'msg': 'Credentials rejected'}
                  : {'code': 0, 'key': 'test-token'})
            : {
                'name': 'A book',
                'data': [
                  {'name': 'A book', 'url': '/book/1'},
                ],
              },
      ),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
