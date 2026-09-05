import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/chunked_txt_webdav_transport.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/txt_chunk_manifest.dart';
import 'package:xxread/services/sync/webdav_client.dart';

void main() {
  late Directory temporary;
  late _MemoryDavClient client;
  late TxtChunkStore chunkStore;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('chunked-dav-');
    client = _MemoryDavClient();
    chunkStore = TxtChunkStore(Directory('${temporary.path}/chunks'));
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('small insertion uploads only changed content-defined chunks', () async {
    final random = Random(991);
    final bytes = List<int>.generate(
      8 * 1024 * 1024,
      (_) => random.nextInt(256),
    );
    final source = File('${temporary.path}/book.txt')..writeAsBytesSync(bytes);
    final first = await chunkStore.capture(source, textEncoding: 'utf-8');
    const transport = ChunkedTxtWebDavTransport();
    final initial = await transport.publish(
      client: client,
      bookSegment: 'stable',
      manifest: first,
      store: chunkStore,
      create: true,
    );
    expect(initial.uploadedChunkBytes, first.byteLength);
    client.resetChunkRequestCounts();

    bytes.insertAll(4096, utf8.encode('新增正文'));
    await source.writeAsBytes(bytes);
    final edited = await chunkStore.capture(source, textEncoding: 'utf-8');
    final update = await transport.publish(
      client: client,
      bookSegment: 'stable',
      manifest: edited,
      store: chunkStore,
      expectedEtag: initial.etag,
      trustedRemoteChunkHashes: first.chunks
          .map((chunk) => chunk.sha256)
          .toSet(),
    );

    expect(update.uploadedChunkBytes, lessThan(1024 * 1024));
    expect(update.uploadedChunkBytes, lessThan(edited.byteLength ~/ 8));
    expect(client.chunkHeadCount, update.uploadedChunkCount);
    expect(client.chunkPutCount, update.uploadedChunkCount);
    expect(client.chunkDownloadCount, update.uploadedChunkCount);
    final remote = await transport.readCurrent(client, 'stable');
    expect(remote!.manifest.contentSha256, edited.contentSha256);
  });

  test('retry resumes after already uploaded immutable chunks', () async {
    final random = Random(71);
    final source = File('${temporary.path}/book.txt')
      ..writeAsBytesSync(
        List<int>.generate(5 * 1024 * 1024, (_) => random.nextInt(256)),
      );
    final manifest = await chunkStore.capture(source);
    const transport = ChunkedTxtWebDavTransport();
    client.failAfterChunkUploads = 3;

    await expectLater(
      transport.publish(
        client: client,
        bookSegment: 'stable',
        manifest: manifest,
        store: chunkStore,
        create: true,
      ),
      throwsA(isA<WebDavSyncFailure>()),
    );
    final bytesBeforeRetry = client.chunkUploadBytes;
    client.failAfterChunkUploads = null;
    final resumed = await transport.publish(
      client: client,
      bookSegment: 'stable',
      manifest: manifest,
      store: chunkStore,
      create: true,
    );

    expect(bytesBeforeRetry, greaterThan(0));
    expect(resumed.uploadedChunkBytes, manifest.byteLength - bytesBeforeRetry);
  });

  test(
    'download rejects corrupt remote chunk without producing a book',
    () async {
      final source = File('${temporary.path}/book.txt')
        ..writeAsStringSync(List.filled(600000, '正文').join());
      final manifest = await chunkStore.capture(source, textEncoding: 'utf-8');
      const transport = ChunkedTxtWebDavTransport();
      await transport.publish(
        client: client,
        bookSegment: 'stable',
        manifest: manifest,
        store: chunkStore,
        create: true,
      );
      await chunkStore.root.delete(recursive: true);
      final first = manifest.chunks.first;
      client.files[transport.chunkUri(client, first.sha256).path] = [1, 2, 3];
      final restored = File('${temporary.path}/restored.txt');

      await expectLater(
        transport.download(
          client: client,
          manifest: manifest,
          store: chunkStore,
          destination: restored,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await restored.exists(), isFalse);
    },
  );

  test(
    'publish does not trust an unreferenced same-length remote chunk',
    () async {
      final source = File('${temporary.path}/book.txt')
        ..writeAsStringSync(List.filled(500000, '共享正文').join());
      final manifest = await chunkStore.capture(source, textEncoding: 'utf-8');
      const transport = ChunkedTxtWebDavTransport();
      final first = manifest.chunks.first;
      final remoteUri = transport.chunkUri(client, first.sha256);
      client.files[remoteUri.path] = List<int>.filled(first.length, 7);
      client.versions[remoteUri.path] = 1;

      await expectLater(
        transport.publish(
          client: client,
          bookSegment: 'new-book',
          manifest: manifest,
          store: chunkStore,
          create: true,
        ),
        throwsA(
          isA<WebDavSyncFailure>().having(
            (error) => error.code,
            'code',
            WebDavSyncErrorCode.corruptRemoteData,
          ),
        ),
      );
      expect(
        client.files.keys.where((path) => path.endsWith('/current.json')),
        isEmpty,
      );
    },
  );

  test('2xx chunk write is read back before manifest commit', () async {
    final source = File('${temporary.path}/book.txt')
      ..writeAsStringSync(List.filled(300000, '上传校验').join());
    final manifest = await chunkStore.capture(source, textEncoding: 'utf8');
    const transport = ChunkedTxtWebDavTransport();
    client.corruptNextChunkWrite = true;

    await expectLater(
      transport.publish(
        client: client,
        bookSegment: 'corrupt-chunk',
        manifest: manifest,
        store: chunkStore,
        create: true,
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.corruptRemoteData,
        ),
      ),
    );
    expect(
      client.files.keys.where((path) => path.endsWith('/current.json')),
      isEmpty,
    );
  });

  test('2xx manifest write is read back before success', () async {
    final source = File('${temporary.path}/book.txt')
      ..writeAsStringSync(List.filled(300000, '清单校验').join());
    final manifest = await chunkStore.capture(source, textEncoding: 'utf8');
    const transport = ChunkedTxtWebDavTransport();
    client.corruptNextManifestWrite = true;

    await expectLater(
      transport.publish(
        client: client,
        bookSegment: 'corrupt-manifest',
        manifest: manifest,
        store: chunkStore,
        create: true,
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.corruptRemoteData,
        ),
      ),
    );
  });

  test('cached download honors pause before assembly', () async {
    final source = File('${temporary.path}/book.txt')
      ..writeAsStringSync(List.filled(300000, '缓存正文').join());
    final manifest = await chunkStore.capture(source, textEncoding: 'utf8');
    const transport = ChunkedTxtWebDavTransport();
    final destination = File('${temporary.path}/paused.txt');

    await expectLater(
      transport.download(
        client: client,
        manifest: manifest,
        store: chunkStore,
        destination: destination,
        shouldContinue: () => false,
      ),
      throwsA(isA<ChunkedTxtTransferPaused>()),
    );
    expect(await destination.exists(), isFalse);
  });

  test('stale manifest ETag preserves the winning remote version', () async {
    final source = File('${temporary.path}/book.txt')
      ..writeAsStringSync(List.filled(200000, '甲').join());
    const transport = ChunkedTxtWebDavTransport();
    final first = await chunkStore.capture(source, textEncoding: 'utf-8');
    final created = await transport.publish(
      client: client,
      bookSegment: 'stable',
      manifest: first,
      store: chunkStore,
      create: true,
    );
    await source.writeAsString(List.filled(200000, '乙').join());
    final second = await chunkStore.capture(source, textEncoding: 'utf-8');
    await transport.publish(
      client: client,
      bookSegment: 'stable',
      manifest: second,
      store: chunkStore,
      expectedEtag: created.etag,
    );
    await source.writeAsString(List.filled(200000, '丙').join());
    final stale = await chunkStore.capture(source, textEncoding: 'utf-8');

    await expectLater(
      transport.publish(
        client: client,
        bookSegment: 'stable',
        manifest: stale,
        store: chunkStore,
        expectedEtag: created.etag,
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.conflict,
        ),
      ),
    );
    expect(
      (await transport.readCurrent(client, 'stable'))!.manifest.contentSha256,
      second.contentSha256,
    );
  });
}

const _credentials = StoredSyncCredentials(
  WebDavSyncConfiguration(
    serverUrl: 'https://dav.example.com',
    username: 'reader',
  ),
  'secret',
);

class _MemoryDavClient extends WebDavClient {
  _MemoryDavClient() : super(dio: Dio(), credentials: _credentials);

  final Map<String, List<int>> files = {};
  final Map<String, int> versions = {};
  int chunkUploadBytes = 0;
  int? failAfterChunkUploads;
  int _chunkUploads = 0;
  int chunkHeadCount = 0;
  int chunkPutCount = 0;
  int chunkDownloadCount = 0;
  bool corruptNextChunkWrite = false;
  bool corruptNextManifestWrite = false;

  void resetChunkRequestCounts() {
    chunkHeadCount = 0;
    chunkPutCount = 0;
    chunkDownloadCount = 0;
  }

  String _etag(String key) => '"${versions[key] ?? 0}"';

  @override
  Future<void> ensureIncrementalMutableProtocolPath(
    List<String> relativeSegments,
  ) async {}

  @override
  Future<WebDavResourceState> resourceState(Uri uri) async {
    if (uri.path.endsWith('.chunk')) chunkHeadCount++;
    final bytes = files[uri.path];
    if (bytes == null) return const WebDavResourceState.missing();
    return WebDavResourceState(
      exists: true,
      etag: _etag(uri.path),
      contentLength: bytes.length,
    );
  }

  @override
  Future<String?> getText(Uri uri, {bool allowNotFound = false}) async {
    final bytes = files[uri.path];
    if (bytes == null) {
      if (allowNotFound) return null;
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'missing',
        statusCode: 404,
      );
    }
    return utf8.decode(bytes);
  }

  @override
  Future<WebDavConditionalWriteResult> putFileConditionally(
    Uri uri,
    File file, {
    String? ifMatch,
    bool ifNoneMatch = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final key = uri.path;
    final exists = files.containsKey(key);
    if ((ifNoneMatch && exists) ||
        (ifMatch != null && (!exists || ifMatch != _etag(key)))) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'precondition failed',
        statusCode: 412,
      );
    }
    final chunk = key.endsWith('.chunk');
    if (chunk &&
        failAfterChunkUploads != null &&
        _chunkUploads >= failAfterChunkUploads!) {
      throw const WebDavSyncFailure(WebDavSyncErrorCode.network, 'offline');
    }
    List<int> bytes = await file.readAsBytes();
    if (chunk && corruptNextChunkWrite) {
      corruptNextChunkWrite = false;
      bytes = List<int>.filled(bytes.length, 0);
    }
    if (key.endsWith('/current.json') && corruptNextManifestWrite) {
      corruptNextManifestWrite = false;
      bytes = utf8.encode('{}');
    }
    files[key] = bytes;
    versions[key] = (versions[key] ?? 0) + 1;
    if (chunk) {
      _chunkUploads++;
      chunkUploadBytes += bytes.length;
      chunkPutCount++;
    }
    return WebDavConditionalWriteResult(
      etag: _etag(key),
      contentLength: bytes.length,
    );
  }

  @override
  Future<void> downloadFile(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (uri.path.endsWith('.chunk')) chunkDownloadCount++;
    final bytes = files[uri.path];
    if (bytes == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'missing',
        statusCode: 404,
      );
    }
    await target.writeAsBytes(bytes, flush: true);
  }
}
