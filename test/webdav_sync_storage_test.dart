import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/storage/webdav_sync_storage.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  test(
    'conditional GET binds bytes and version from the same response',
    () async {
    final adapter = _VersionedGetAdapter(etag: '"revision-a"', body: '正文');
      final storage = _storage(adapter);

      final result = await storage.readText(
        SyncPath('books/书/current.txt'),
        expectedVersion: const SyncObjectVersion('"revision-a"'),
      );

      expect(result.text, '正文');
      expect(result.info.version, const SyncObjectVersion('"revision-a"'));
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.headers['If-Match'], '"revision-a"');
    },
  );

  test(
    'a GET carrying another version is rejected without a follow-up HEAD',
    () async {
    final adapter = _VersionedGetAdapter(etag: '"revision-b"', body: 'changed');
      final storage = _storage(adapter);

      await expectLater(
        storage.readText(
          SyncPath('books/书/current.txt'),
          expectedVersion: const SyncObjectVersion('"revision-a"'),
        ),
        throwsA(
          isA<SyncStorageException>().having(
            (error) => error.code,
            'code',
            SyncStorageErrorCode.versionConflict,
          ),
        ),
      );
      expect(adapter.requests.map((request) => request.method), ['GET']);
    },
  );

  test('weak validators disable safe reads', () async {
    final storage = _storage(
      _VersionedGetAdapter(etag: 'W/"weak"', body: '正文'),
    );
    await expectLater(
      storage.readText(SyncPath('books/a/current.txt')),
      throwsA(
        isA<SyncStorageException>().having(
          (error) => error.code,
          'code',
          SyncStorageErrorCode.unsupported,
        ),
      ),
    );
  });

  test(
    'list treats resourcetype collection as prefix even with ETag',
    () async {
      final adapter = _CollectionListingAdapter();
      final storage = _storage(adapter);

      final listing = await storage.list(SyncPath('sync/metadata/devices'));

      expect(listing.objects, isEmpty);
      expect(listing.prefixes.map((path) => path.value), [
        'sync/metadata/devices/device-a',
      ]);
      expect(adapter.requests, hasLength(1));
    },
  );
}

WebDavSyncStorage _storage(HttpClientAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return WebDavSyncStorage(
    WebDavClient(
      dio: dio,
      credentials: const StoredSyncCredentials(
        WebDavSyncConfiguration(
          serverUrl: 'https://dav.example.com',
          username: 'reader',
        ),
        'secret',
      ),
    ),
  );
}

final class _VersionedGetAdapter implements HttpClientAdapter {
  _VersionedGetAdapter({required this.etag, required this.body});

  final String etag;
  final String body;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        'etag': [etag],
        'content-type': ['text/plain; charset=utf-8'],
      },
    );
  }
}

final class _CollectionListingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/OpenReading/sync/metadata/devices/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/OpenReading/sync/metadata/devices/device-a/</d:href>
    <d:propstat><d:prop><d:getetag>"collection-etag"</d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>''',
      207,
      headers: {
        'content-type': ['application/xml'],
      },
    );
  }
}
