import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sync_models.dart';
import 'txt_chunk_manifest.dart';
import 'webdav_client.dart';

class ChunkedTxtTransferPaused implements Exception {
  const ChunkedTxtTransferPaused();
}

class ChunkedTxtRemoteVersion {
  const ChunkedTxtRemoteVersion({required this.manifest, required this.etag});

  final TxtChunkManifest manifest;
  final String etag;
}

class ChunkedTxtPublishResult {
  const ChunkedTxtPublishResult({
    required this.manifest,
    required this.etag,
    required this.uploadedChunkBytes,
    required this.uploadedChunkCount,
  });

  final TxtChunkManifest manifest;
  final String etag;
  final int uploadedChunkBytes;
  final int uploadedChunkCount;
}

/// WebDAV v3 transport for an explicitly upgraded mutable TXT binding.
///
/// Immutable chunks are published first. The small current manifest is the
/// sole mutable resource and is committed with a strong-ETag compare-and-swap.
class ChunkedTxtWebDavTransport {
  const ChunkedTxtWebDavTransport();

  Future<ChunkedTxtRemoteVersion?> readCurrent(
    WebDavClient client,
    String bookSegment,
  ) async {
    final uri = currentUri(client, bookSegment);
    final state = await client.resourceState(uri);
    if (!state.exists) return null;
    final etag = _requireStrongEtag(state.etag);
    if ((state.contentLength ?? 0) > 16 * 1024 * 1024) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The TXT chunk manifest is unreasonably large.',
      );
    }
    final temporary = File(
      '${Directory.systemTemp.path}/open-reading-manifest-'
      '${_uniqueSuffix()}.part',
    );
    late final String encoded;
    try {
      await client.downloadFile(
        uri,
        temporary,
        onProgress: (received, _) {
          if (received > 16 * 1024 * 1024) {
            throw const WebDavSyncFailure(
              WebDavSyncErrorCode.corruptRemoteData,
              'The TXT chunk manifest is unreasonably large.',
            );
          }
        },
      );
      if (await temporary.length() > 16 * 1024 * 1024) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The TXT chunk manifest is unreasonably large.',
        );
      }
      encoded = await temporary.readAsString();
      return ChunkedTxtRemoteVersion(
        manifest: TxtChunkManifest.decode(encoded),
        etag: etag,
      );
    } on FormatException catch (error) {
      throw WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The TXT chunk manifest is invalid: ${error.message}',
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<ChunkedTxtPublishResult> publish({
    required WebDavClient client,
    required String bookSegment,
    required TxtChunkManifest manifest,
    required TxtChunkStore store,
    String? expectedEtag,
    bool create = false,
    Set<String> trustedRemoteChunkHashes = const {},
    bool Function()? shouldContinue,
  }) async {
    if ((expectedEtag == null) != create) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'A chunk manifest publish requires create or an expected ETag.',
      );
    }
    await client.ensureIncrementalMutableProtocolPath(['books', bookSegment]);
    await client.ensureIncrementalMutableProtocolPath(['chunks', 'sha256']);
    var uploadedBytes = 0;
    var uploadedCount = 0;
    final visited = <String>{};
    for (final chunk in manifest.chunks) {
      if (shouldContinue?.call() == false) {
        throw const ChunkedTxtTransferPaused();
      }
      if (!visited.add(chunk.sha256) ||
          trustedRemoteChunkHashes.contains(chunk.sha256)) {
        continue;
      }
      final remoteUri = chunkUri(client, chunk.sha256);
      final state = await client.resourceState(remoteUri);
      if (state.exists) {
        if (state.contentLength != null &&
            state.contentLength != chunk.length) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'An immutable cloud TXT chunk has the wrong length.',
          );
        }
        if (!await _remoteChunkMatches(client, remoteUri, chunk, store)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'An immutable cloud TXT chunk failed checksum verification.',
          );
        }
        continue;
      }
      await client.ensureIncrementalMutableProtocolPath([
        'chunks',
        'sha256',
        chunk.sha256.substring(0, 2),
      ]);
      final file = store.fileForHash(chunk.sha256);
      try {
        await client.putFileConditionally(remoteUri, file, ifNoneMatch: true);
        if (!await _remoteChunkMatches(client, remoteUri, chunk, store)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'A newly uploaded cloud TXT chunk failed checksum verification.',
          );
        }
        uploadedBytes += chunk.length;
        uploadedCount++;
      } on WebDavSyncFailure catch (error) {
        if (error.code != WebDavSyncErrorCode.conflict ||
            !await _remoteChunkMatches(client, remoteUri, chunk, store)) {
          rethrow;
        }
      }
    }

    if (shouldContinue?.call() == false) {
      throw const ChunkedTxtTransferPaused();
    }

    final manifestFile = File(
      '${store.root.path}/manifest-${manifest.contentSha256}-'
      '${_uniqueSuffix()}.json',
    );
    await manifestFile.parent.create(recursive: true);
    await manifestFile.writeAsString(manifest.encode(), flush: true);
    try {
      final result = await client.putFileConditionally(
        currentUri(client, bookSegment),
        manifestFile,
        ifMatch: expectedEtag,
        ifNoneMatch: create,
      );
      final verified = await readCurrent(client, bookSegment);
      if (verified == null) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The committed TXT chunk manifest is missing.',
        );
      }
      if (verified.etag != result.etag) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.conflict,
          'The cloud TXT manifest changed while it was being verified.',
          statusCode: 412,
        );
      }
      if (verified.manifest.encode() != manifest.encode()) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The committed TXT chunk manifest failed read-back verification.',
        );
      }
      return ChunkedTxtPublishResult(
        manifest: manifest,
        etag: verified.etag,
        uploadedChunkBytes: uploadedBytes,
        uploadedChunkCount: uploadedCount,
      );
    } finally {
      if (await manifestFile.exists()) await manifestFile.delete();
    }
  }

  Future<File> download({
    required WebDavClient client,
    required TxtChunkManifest manifest,
    required TxtChunkStore store,
    required File destination,
    bool Function()? shouldContinue,
  }) async {
    for (final chunk in manifest.chunks) {
      if (shouldContinue?.call() == false) {
        throw const ChunkedTxtTransferPaused();
      }
      if (await store.contains(chunk)) continue;
      final partial = File(
        '${store.root.path}/.download-${chunk.sha256}-${_uniqueSuffix()}.part',
      );
      await partial.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      try {
        await client.downloadFile(chunkUri(client, chunk.sha256), partial);
        await store.acceptDownloaded(chunk, partial);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    if (shouldContinue?.call() == false) {
      throw const ChunkedTxtTransferPaused();
    }
    try {
      await store.assemble(
        manifest,
        destination,
        shouldContinue: shouldContinue,
      );
    } on TxtChunkOperationCancelled {
      throw const ChunkedTxtTransferPaused();
    }
    return destination;
  }

  Uri currentUri(WebDavClient client, String bookSegment) =>
      client.incrementalMutablePath(['books', bookSegment, 'current.json']);

  Uri chunkUri(WebDavClient client, String hash) =>
      client.incrementalMutablePath([
        'chunks',
        'sha256',
        hash.substring(0, 2),
        '$hash.chunk',
      ]);

  Future<bool> _remoteChunkMatches(
    WebDavClient client,
    Uri uri,
    TxtChunkReference expected,
    TxtChunkStore store,
  ) async {
    final temporary = File(
      '${store.root.path}/.verify-${expected.sha256}-${_uniqueSuffix()}.part',
    );
    try {
      if (await temporary.exists()) await temporary.delete();
      await client.downloadFile(uri, temporary);
      return await temporary.length() == expected.length &&
          (await sha256.bind(temporary.openRead()).first).toString() ==
              expected.sha256;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

String _uniqueSuffix() =>
    '$pid-${DateTime.now().microsecondsSinceEpoch}-'
    '${Random.secure().nextInt(1 << 32)}';

String _requireStrongEtag(String? etag) {
  final value = etag?.trim();
  if (value == null || value.isEmpty || value.startsWith('W/')) {
    throw const WebDavSyncFailure(
      WebDavSyncErrorCode.serverIncompatible,
      'Safe editable TXT sync requires a strong WebDAV ETag.',
    );
  }
  return value;
}
