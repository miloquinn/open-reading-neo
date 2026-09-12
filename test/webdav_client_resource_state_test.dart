import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'open-reading-resource-state-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('uses a strong HEAD ETag without issuing PROPFIND', () async {
    final adapter = _ScriptAdapter((method, _) {
      if (method == 'HEAD') {
        return _response(
          200,
          headers: {
            'etag': ['"head"'],
            'content-length': ['7'],
          },
        );
      }
      fail('unexpected $method');
    });
    final state = await _client(adapter).resourceState(_uri());
    expect(state.etag, '"head"');
    expect(state.contentLength, 7);
    expect(adapter.methods, ['HEAD']);
  });

  test('uses matching resource properties for ETag and length', () async {
    final adapter = _ScriptAdapter((method, _) {
      if (method == 'HEAD') return _response(200);
      if (method == 'PROPFIND') {
        return _xmlResponse('''<d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/OpenReading/books/other/current.txt</d:href>
            <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop><d:getetag>"other"</d:getetag></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/OpenReading/books/book/current.txt</d:href>
            <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop><d:getetag>"dav"</d:getetag><d:getcontentlength>12</d:getcontentlength></d:prop></d:propstat>
          </d:response></d:multistatus>''');
      }
      fail('unexpected $method');
    });
    final state = await _client(adapter).resourceState(_uri());
    expect(state.etag, '"dav"');
    expect(state.contentLength, 12);
    expect(adapter.methods, ['HEAD', 'PROPFIND']);
  });

  test(
    'decodes numeric quotes once and preserves encoded ampersands',
    () async {
      final adapter = _propertyAdapter('''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/OpenReading/books/book/current.txt</d:href>
        <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop>
          <d:getetag>&#34;revision&#x22;</d:getetag>
        </d:prop></d:propstat>
      </d:response></d:multistatus>''');
      expect((await _client(adapter).resourceState(_uri())).etag, '"revision"');

      final literalEntityAdapter = _propertyAdapter(
        '''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/OpenReading/books/book/current.txt</d:href>
        <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop>
          <d:getetag>&quot;a&amp;quot;b&quot;</d:getetag>
        </d:prop></d:propstat>
      </d:response></d:multistatus>''',
      );
      expect(
        (await _client(literalEntityAdapter).resourceState(_uri())).etag,
        '"a&quot;b"',
      );
    },
  );

  test('rejects a property response with only an unrelated href', () async {
    final adapter = _propertyAdapter('''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/OpenReading/books/other/current.txt</d:href>
        <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop><d:getetag>"other"</d:getetag></d:prop></d:propstat>
      </d:response></d:multistatus>''');
    await expectLater(
      _client(adapter).resourceState(_uri()),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (e) => e.code,
          'code',
          WebDavSyncErrorCode.serverIncompatible,
        ),
      ),
    );
  });

  test('does not accept ETag from a failed propstat', () async {
    final adapter = _propertyAdapter('''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/OpenReading/books/book/current.txt</d:href>
        <d:propstat><d:status>HTTP/1.1 404 Not Found</d:status><d:prop><d:getetag>"bad"</d:getetag></d:prop></d:propstat>
      </d:response></d:multistatus>''');
    final state = await _client(adapter).resourceState(_uri());
    expect(state.exists, isTrue);
    expect(state.etag, isNull);
  });

  test('weak or missing property ETags remain unusable', () async {
    for (final etag in ['W/"weak"', null]) {
      final adapter = _propertyAdapter('''<d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/OpenReading/books/book/current.txt</d:href>
          <d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:prop><d:getetag>${etag ?? ''}</d:getetag></d:prop></d:propstat>
        </d:response></d:multistatus>''');
      final state = await _client(adapter).resourceState(_uri());
      expect(state.etag, isNull);
    }
  });

  test('HEAD 404 returns missing without PROPFIND', () async {
    final adapter = _ScriptAdapter((method, _) {
      if (method == 'HEAD') return _response(404);
      fail('unexpected $method');
    });
    expect((await _client(adapter).resourceState(_uri())).exists, isFalse);
    expect(adapter.methods, ['HEAD']);
  });

  test(
    'PROPFIND authentication and rate-limit failures preserve details',
    () async {
      for (final status in [401, 429]) {
        final adapter = _ScriptAdapter((method, _) {
          if (method == 'HEAD') return _response(200);
          if (method == 'PROPFIND') return _response(status);
          fail('unexpected $method');
        });
        await expectLater(
          _client(adapter).resourceState(_uri()),
          throwsA(
            isA<WebDavSyncFailure>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
      }
    },
  );

  test('conditional PUT rejects when remote bytes race after PUT', () async {
    final source = File('${temporaryDirectory.path}/current.txt')
      ..writeAsStringSync('local');
    final adapter = _RaceAdapter(
      remoteBytes: 'other',
      remoteEtags: ['"race"', '"race"'],
    );
    await expectLater(
      _client(adapter).putFileConditionally(_uri(), source, ifNoneMatch: true),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (e) => e.code,
          'code',
          WebDavSyncErrorCode.conflict,
        ),
      ),
    );
  });

  test(
    'conditional PUT rejects when ETag changes during verification',
    () async {
      final source = File('${temporaryDirectory.path}/current.txt')
        ..writeAsStringSync('local');
      final adapter = _RaceAdapter(
        remoteBytes: 'local',
        remoteEtags: ['"one"', '"two"'],
      );
      await expectLater(
        _client(
          adapter,
        ).putFileConditionally(_uri(), source, ifNoneMatch: true),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (e) => e.code,
            'code',
            WebDavSyncErrorCode.conflict,
          ),
        ),
      );
    },
  );
}

Uri _uri() =>
    Uri.parse('https://dav.example.com/OpenReading/books/book/current.txt');

WebDavClient _client(HttpClientAdapter adapter) => WebDavClient(
  dio: Dio()..httpClientAdapter = adapter,
  credentials: const StoredSyncCredentials(
    WebDavSyncConfiguration(
      serverUrl: 'https://dav.example.com',
      username: 'reader',
    ),
    'secret',
  ),
);

ResponseBody _response(
  int status, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody(Stream<Uint8List>.empty(), status, headers: headers);

ResponseBody _xmlResponse(String body) => ResponseBody(
  Stream.value(Uint8List.fromList(utf8.encode(body))),
  207,
  headers: {
    'content-type': ['application/xml'],
  },
);

_ScriptAdapter _propertyAdapter(String body) => _ScriptAdapter((method, _) {
  if (method == 'HEAD') return _response(200);
  if (method == 'PROPFIND') return _xmlResponse(body);
  fail('unexpected $method');
});

class _ScriptAdapter implements HttpClientAdapter {
  _ScriptAdapter(this.handler);
  final ResponseBody Function(String method, RequestOptions options) handler;
  final methods = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain();
    methods.add(options.method);
    return handler(options.method, options);
  }

  @override
  void close({bool force = false}) {}
}

class _RaceAdapter implements HttpClientAdapter {
  _RaceAdapter({required this.remoteBytes, required this.remoteEtags});
  final String remoteBytes;
  final List<String> remoteEtags;
  int headCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain();
    switch (options.method) {
      case 'PUT':
        return _response(204);
      case 'HEAD':
        final etag = remoteEtags[headCount++];
        return _response(
          200,
          headers: {
            'etag': [etag],
          },
        );
      case 'GET':
        return ResponseBody(
          Stream.value(Uint8List.fromList(utf8.encode(remoteBytes))),
          200,
          headers: {
            'etag': [remoteEtags[headCount++]],
          },
        );
      default:
        fail('unexpected ${options.method}');
    }
  }

  @override
  void close({bool force = false}) {}
}
