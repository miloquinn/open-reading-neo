import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_storage.dart';

/// Deterministic storage adapter for protocol and cross-device tests.
final class MemorySyncStorage implements SyncStorage {
  MemorySyncStorage({this.spaceKey = 'memory:default'});

  final Map<SyncPath, _MemoryObject> _objects = {};

  @override
  final String spaceKey;

  @override
  SyncStorageCapabilities get capabilities =>
      const SyncStorageCapabilities(strongVersions: true);

  @override
  DateTime? get serverDate => DateTime.now().toUtc();

  @override
  Future<SyncListing> list(SyncPath prefix) async {
    final prefixValue = '${prefix.value}/';
    final objects = <SyncObjectInfo>[];
    final prefixes = <SyncPath>{};
    for (final entry in _objects.entries) {
      if (!entry.key.value.startsWith(prefixValue)) continue;
      final suffix = entry.key.value.substring(prefixValue.length);
      final separator = suffix.indexOf('/');
      if (separator < 0) {
        objects.add(entry.value.info(entry.key));
      } else {
        prefixes.add(prefix.child(suffix.substring(0, separator)));
      }
    }
    objects.sort((a, b) => a.path.compareTo(b.path));
    final orderedPrefixes = prefixes.toList()..sort((a, b) => a.compareTo(b));
    return SyncListing(objects: objects, prefixes: orderedPrefixes);
  }

  @override
  Future<SyncObjectInfo?> stat(SyncPath path) async =>
      _objects[path]?.info(path);

  @override
  Future<SyncTextRead> readText(
    SyncPath path, {
    SyncObjectVersion? expectedVersion,
  }) async {
    final object = _require(path, expectedVersion);
    try {
      return SyncTextRead(
        text: utf8.decode(object.bytes),
        info: object.info(path),
      );
    } on FormatException catch (error) {
      throw SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The object is not valid UTF-8 text.',
        cause: error,
      );
    }
  }

  @override
  Future<SyncDownload> download(
    SyncPath path,
    IOSink destination, {
    SyncObjectVersion? expectedVersion,
  }) async {
    final object = _require(path, expectedVersion);
    destination.add(object.bytes);
    await destination.flush();
    return SyncDownload(info: object.info(path));
  }

  @override
  Future<SyncWrite> create(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
  }) async {
    if (_objects.containsKey(path)) {
      throw const SyncStorageException(
        SyncStorageErrorCode.versionConflict,
        'The object already exists.',
      );
    }
    return _store(path, bytes, length: length, contentType: contentType);
  }

  @override
  Future<SyncWrite> compareAndSwap(
    SyncPath path,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    required SyncObjectVersion expectedVersion,
  }) async {
    _require(path, expectedVersion);
    return _store(path, bytes, length: length, contentType: contentType);
  }

  @override
  Future<void> delete(
    SyncPath path, {
    required SyncObjectVersion expectedVersion,
  }) async {
    _require(path, expectedVersion);
    _objects.remove(path);
  }

  _MemoryObject _require(SyncPath path, SyncObjectVersion? expectedVersion) {
    final object = _objects[path];
    if (object == null) {
      throw const SyncStorageException(
        SyncStorageErrorCode.notFound,
        'The object does not exist.',
      );
    }
    if (expectedVersion != null && object.version != expectedVersion) {
      throw const SyncStorageException(
        SyncStorageErrorCode.versionConflict,
        'The object version changed.',
      );
    }
    return object;
  }

  Future<SyncWrite> _store(
    SyncPath path,
    Stream<List<int>> stream, {
    required int length,
    required String contentType,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != length) {
      throw SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'Expected $length bytes but received ${bytes.length}.',
      );
    }
    final object = _MemoryObject(
      bytes: bytes,
      version: SyncObjectVersion('"${sha256.convert(bytes)}"'),
      contentType: contentType,
    );
    _objects[path] = object;
    return SyncWrite(info: object.info(path));
  }
}

final class _MemoryObject {
  const _MemoryObject({
    required this.bytes,
    required this.version,
    required this.contentType,
  });

  final List<int> bytes;
  final SyncObjectVersion version;
  final String contentType;

  SyncObjectInfo info(SyncPath path) => SyncObjectInfo(
    path: path,
    version: version,
    length: bytes.length,
    contentType: contentType,
  );
}
