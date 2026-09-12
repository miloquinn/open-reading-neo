import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  for (final entry in {
    401: WebDavSyncErrorCode.authentication,
    403: WebDavSyncErrorCode.permissionDenied,
    409: WebDavSyncErrorCode.conflict,
    423: WebDavSyncErrorCode.conflict,
    429: WebDavSyncErrorCode.rateLimited,
    503: WebDavSyncErrorCode.serverError,
    507: WebDavSyncErrorCode.storageFull,
  }.entries) {
    test(
      'capability probe preserves HTTP ${entry.key} and request details',
      () async {
        final adapter = _DavAdapter(rejection: entry.key);
        await expectLater(
          _client(adapter).verifyMutableWritePreconditions(),
          throwsA(
            isA<WebDavSyncFailure>()
                .having((e) => e.code, 'code', entry.value)
                .having((e) => e.statusCode, 'HTTP', entry.key)
                .having((e) => e.requestMethod, 'method', 'PUT')
                .having(
                  (e) => e.resourcePath,
                  'path',
                  contains('/sync/.capabilities/'),
                ),
          ),
        );
        expect(adapter.deleted, isTrue);
      },
    );
  }

  test('412 for both preconditions validates the seed and cleans up', () async {
    final adapter = _DavAdapter();
    await _client(adapter).verifyMutableWritePreconditions();
    expect(adapter.preconditions, ['If-None-Match', 'If-Match']);
    expect(adapter.deleted, isTrue);
  });

  test('probe accepts ETags supplied only by DAV properties', () async {
    final adapter = _DavAdapter(propertyEtag: true);
    await _client(adapter).verifyMutableWritePreconditions();
    expect(adapter.preconditions, ['If-None-Match', 'If-Match']);
    expect(adapter.propertyQueries, 1);
    expect(adapter.deleted, isTrue);
  });

  for (final ignored in ['If-None-Match', 'If-Match']) {
    test('ignored $ignored names the failing capability', () async {
      final adapter = _DavAdapter(ignored: ignored);
      await expectLater(
        _client(adapter).verifyMutableWritePreconditions(),
        throwsA(
          isA<WebDavSyncFailure>()
              .having(
                (e) => e.code,
                'code',
                WebDavSyncErrorCode.serverIncompatible,
              )
              .having((e) => e.message, 'reason', contains(ignored))
              .having((e) => e.requestMethod, 'method', 'PUT'),
        ),
      );
      expect(adapter.deleted, isTrue);
    });
  }

  test('connection test retains the original structured failure', () async {
    final result = await _client(
      _DavAdapter(optionsStatus: 503),
    ).testConnection();
    expect(result.success, isFalse);
    expect(result.errorCode, WebDavSyncErrorCode.serverError);
    expect(result.failure?.statusCode, 503);
    expect(result.failure?.requestMethod, 'OPTIONS');
  });

  test(
    'probe preserves a timeout rather than declaring incompatibility',
    () async {
      await expectLater(
        _client(_DavAdapter(timeout: true)).verifyMutableWritePreconditions(),
        throwsA(
          isA<WebDavSyncFailure>()
              .having((e) => e.code, 'code', WebDavSyncErrorCode.timeout)
              .having((e) => e.requestMethod, 'method', 'PUT'),
        ),
      );
    },
  );

  test('request diagnostics omit query tokens and authorization', () async {
    final client = _client(_DavAdapter(getStatus: 503));
    await expectLater(
      client.getText(Uri.parse('https://dav.example.com/private?token=secret')),
      throwsA(
        isA<WebDavSyncFailure>()
            .having((e) => e.resourcePath, 'safe path', '/private')
            .having((e) => e.requestMethod, 'method', 'GET')
            .having((e) => e.message, 'reason', isNot(contains('secret'))),
      ),
    );
  });
}

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

class _DavAdapter implements HttpClientAdapter {
  _DavAdapter({
    this.rejection = 412,
    this.ignored,
    this.getStatus = 200,
    this.optionsStatus = 200,
    this.timeout = false,
    this.propertyEtag = false,
  });
  final int rejection;
  final String? ignored;
  final int getStatus;
  final int optionsStatus;
  final bool timeout;
  final bool propertyEtag;
  int propertyQueries = 0;
  final preconditions = <String>[];
  bool exists = false;
  bool deleted = false;
  String content = '';

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'OPTIONS') {
      return ResponseBody.fromString('', optionsStatus);
    }
    if (options.method == 'MKCOL') return ResponseBody.fromString('', 201);
    if (options.method == 'DELETE') {
      deleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (options.method == 'GET') {
      return ResponseBody.fromString(
        content,
        getStatus,
        headers: {
          'etag': ['"probe-revision"'],
        },
      );
    }
    if (options.method == 'HEAD') return ResponseBody.fromString('', 200);
    if (options.method == 'PROPFIND') {
      propertyQueries++;
      expect(options.headers['Depth'], '0');
      return ResponseBody.fromString(
        '<d:multistatus xmlns:d="DAV:"><d:response>'
        '<d:href>${options.uri.path}</d:href><d:propstat><d:prop>'
        '<d:getetag>&quot;probe-revision&quot;</d:getetag></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response></d:multistatus>',
        207,
      );
    }
    if (options.method == 'PUT') {
      final bytes = <int>[];
      if (requestStream != null) {
        await for (final chunk in requestStream) {
          bytes.addAll(chunk);
        }
      }
      if (exists) {
        if (timeout) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );
        }
        final header = options.headers.containsKey('If-Match')
            ? 'If-Match'
            : 'If-None-Match';
        preconditions.add(header);
        if (ignored != header) return ResponseBody.fromString('', rejection);
      }
      exists = true;
      content = String.fromCharCodes(bytes);
      return ResponseBody.fromString(
        '',
        201,
        headers: {
          if (!propertyEtag) 'etag': ['"probe-revision"'],
        },
      );
    }
    throw StateError('Unexpected ${options.method}');
  }
}
