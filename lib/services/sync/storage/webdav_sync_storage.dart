import 'dart:io';

import '../sync_models.dart';
import '../webdav_client.dart';
import 'sync_storage.dart';

final class WebDavSyncStorage implements SyncStorage {
  WebDavSyncStorage(this._client);

  final WebDavClient _client;
  Future<void>? _writeSafetyCheck;

  @override
  SyncStorageCapabilities get capabilities =>
      const SyncStorageCapabilities(strongVersions: true);

  @override
  String get spaceKey => _client.readableSpaceKey;

  @override
  DateTime? get serverDate => _client.lastServerDate;

  @override
  Future<SyncListing> list(SyncPath prefix) async {
    final root = _client.rootPath(const []);
    final objects = <SyncObjectInfo>[];
    final prefixes = <SyncPath>[];
    try {
      for (final entry in await _client.listEntries(_uri(prefix))) {
        if (!_isBelow(entry.uri, _uri(prefix))) continue;
        final path = SyncPath(_relativePath(root, entry.uri));
        if (entry.isCollection) {
          prefixes.add(path);
          continue;
        }
        final etag = entry.etag;
        if (etag == null) {
          throw const SyncStorageException(
            SyncStorageErrorCode.unsupported,
            'A listed WebDAV object has no strong validator.',
          );
        }
        objects.add(
          SyncObjectInfo(
            path: path,
            version: SyncObjectVersion(etag),
            length: entry.contentLength ?? 0,
          ),
        );
      }
    } on WebDavSyncFailure catch (error) {
      throw _map(error);
    }
    objects.sort((a, b) => a.path.compareTo(b.path));
    prefixes.sort((a, b) => a.compareTo(b));
    return SyncListing(objects: objects, prefixes: prefixes);
  }

  @override
  Future<SyncObjectInfo?> stat(SyncPath path) async {
    try {
      final state = await _client.resourceState(_uri(path));
      if (!state.exists) return null;
      final etag = state.etag;
      if (etag == null) {
        throw const SyncStorageException(
          SyncStorageErrorCode.unsupported,
          'The WebDAV object has no strong validator.',
        );
      }
      return SyncObjectInfo(
        path: path,
        version: SyncObjectVersion(etag),
        length: state.contentLength ?? 0,
      );
    } on WebDavSyncFailure catch (error) {
      if (error.code == WebDavSyncErrorCode.notFound) return null;
      throw _map(error);
    }
  }

  @override
  Future<SyncTextRead> readText(
    SyncPath path, {
    SyncObjectVersion? expectedVersion,
  }) async {
    try {
      final result = await _client.getTextWithVersion(
        _uri(path),
        expectedEtag: expectedVersion?.value,
      );
      return SyncTextRead(
        text: result.text,
        info: SyncObjectInfo(
          path: path,
          version: SyncObjectVersion(result.etag),
          length: result.contentLength,
          contentType: result.contentType,
        ),
      );
    } on WebDavSyncFailure catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<SyncDownload> download(
    SyncPath path,
    IOSink destination, {
    SyncObjectVersion? expectedVersion,
  }) async {
    try {
      final result = await _client.downloadWithVersion(
        _uri(path),
        destination,
        expectedEtag: expectedVersion?.value,
      );
      return SyncDownload(
        info: SyncObjectInfo(
          path: path,
          version: SyncObjectVersion(result.etag),
          length: result.contentLength,
          contentType: result.contentType,
        ),
      );
    } on WebDavSyncFailure catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<SyncWrite> create(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
  }) async {
    return _write(
      path,
      bytes,
      length: length,
      contentType: contentType,
      createOnly: true,
    );
  }

  @override
  Future<SyncWrite> compareAndSwap(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    required SyncObjectVersion expectedVersion,
  }) async {
    return _write(
      path,
      bytes,
      length: length,
      contentType: contentType,
      expectedVersion: expectedVersion,
    );
  }

  Future<SyncWrite> _write(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    bool createOnly = false,
    SyncObjectVersion? expectedVersion,
  }) async {
    try {
      await (_writeSafetyCheck ??= _client.verifyMutableWritePreconditions());
      await _client.ensureRootRelativeParent(path.value);
      final result = await _client.putStreamConditionally(
        _uri(path),
        bytes,
        length: length,
        contentType: contentType,
        ifMatch: expectedVersion?.value,
        ifNoneMatch: createOnly,
      );
      return SyncWrite(
        info: SyncObjectInfo(
          path: path,
          version: SyncObjectVersion(result.etag),
          length: result.contentLength,
          contentType: result.contentType,
        ),
      );
    } on WebDavSyncFailure catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required SyncObjectVersion expectedVersion,
  }) async {
    try {
      await _client.deleteConditionally(
        _uri(path),
        ifMatch: expectedVersion.value,
      );
    } on WebDavSyncFailure catch (error) {
      throw _map(error);
    }
  }

  Uri _uri(SyncPath path) => _client.uriForRootRelativePath(path.value);
}

bool _isBelow(Uri child, Uri parent) {
  final parentSegments = parent.pathSegments.where((part) => part.isNotEmpty);
  final childSegments = child.pathSegments.where((part) => part.isNotEmpty);
  final expected = parentSegments.toList(growable: false);
  final actual = childSegments.toList(growable: false);
  if (actual.length <= expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

String _relativePath(Uri root, Uri object) {
  final rootSegments = root.pathSegments
      .where((part) => part.isNotEmpty)
      .toList();
  final objectSegments = object.pathSegments
      .where((part) => part.isNotEmpty)
      .toList();
  if (objectSegments.length <= rootSegments.length) {
    throw const SyncStorageException(
      SyncStorageErrorCode.invalidData,
      'The WebDAV listing returned an object outside the sync root.',
    );
  }
  for (var index = 0; index < rootSegments.length; index++) {
    if (rootSegments[index] != objectSegments[index]) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The WebDAV listing returned an object outside the sync root.',
      );
    }
  }
  return objectSegments.skip(rootSegments.length).join('/');
}

SyncStorageException _map(WebDavSyncFailure failure) {
  final code = switch (failure.code) {
    WebDavSyncErrorCode.authentication => SyncStorageErrorCode.authentication,
    WebDavSyncErrorCode.permissionDenied =>
      SyncStorageErrorCode.permissionDenied,
    WebDavSyncErrorCode.notFound => SyncStorageErrorCode.notFound,
    WebDavSyncErrorCode.conflict => SyncStorageErrorCode.versionConflict,
    WebDavSyncErrorCode.rateLimited => SyncStorageErrorCode.rateLimited,
    WebDavSyncErrorCode.storageFull => SyncStorageErrorCode.storageFull,
    WebDavSyncErrorCode.timeout => SyncStorageErrorCode.timeout,
    WebDavSyncErrorCode.network => SyncStorageErrorCode.network,
    WebDavSyncErrorCode.tls => SyncStorageErrorCode.tls,
    WebDavSyncErrorCode.corruptRemoteData ||
    WebDavSyncErrorCode.localDataCorrupt => SyncStorageErrorCode.invalidData,
    WebDavSyncErrorCode.serverError => SyncStorageErrorCode.serverError,
    _ => SyncStorageErrorCode.unsupported,
  };
  return SyncStorageException(code, failure.message, cause: failure);
}
