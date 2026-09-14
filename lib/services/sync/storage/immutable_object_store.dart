import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'sync_storage.dart';

/// The protocol writes only immutable, content-addressed objects. ETags are
/// transport hints, never integrity evidence. A successful upload includes a
/// read-back checksum; a local cache entry is usable only after verification.
class ImmutableObjectStore {
  ImmutableObjectStore(this.storage, this.cache);

  final SyncStorage storage;
  final Directory cache;
  int uploadedBytes = 0;
  int downloadedBytes = 0;

  static String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();
  static Future<String> hashFile(File file) async =>
      '${await sha256.bind(file.openRead()).first}';

  File _cached(String hash) => File(path.join(cache.path, hash));

  Future<File> readFile(SyncPath remote, String hash, {int? size}) async {
    _validateHash(hash);
    final cached = _cached(hash);
    if (await cached.exists()) {
      if ((size == null || await cached.length() == size) &&
          await hashFile(cached) == hash) {
        return cached;
      }
      await cached.delete();
    }
    await cache.create(recursive: true);
    final temporary = await Directory.systemTemp.createTemp('sync-object-');
    final file = File(path.join(temporary.path, 'object.part'));
    try {
      final sink = file.openWrite();
      try {
        final result = await storage.download(remote, sink);
        downloadedBytes += result.info.length;
      } finally {
        await sink.close();
      }
      if ((size != null && await file.length() != size) ||
          await hashFile(file) != hash) {
        throw const SyncStorageException(
          SyncStorageErrorCode.invalidData,
          'An immutable cloud object failed checksum verification.',
        );
      }
      await file.copy(cached.path);
      return cached;
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<String> readText(SyncPath remote, String hash) async {
    final file = await readFile(remote, hash);
    if (await file.length() > 16 * 1024 * 1024) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The cloud manifest exceeds the 16 MiB limit.',
      );
    }
    return file.readAsString();
  }

  Future<void> putText(SyncPath remote, String text) async {
    final temporary = await Directory.systemTemp.createTemp('sync-json-');
    final file = File(path.join(temporary.path, 'object'));
    try {
      await file.writeAsString(text, flush: true);
      await putFile(remote, file, hashBytes(utf8.encode(text)));
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> putFile(SyncPath remote, File file, String hash) async {
    _validateHash(hash);
    if (await hashFile(file) != hash) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The local object changed before it could be uploaded.',
      );
    }
    final size = await file.length();
    final existing = await storage.stat(remote);
    if (existing != null) {
      try {
        await readFile(remote, hash, size: size);
        return;
      } on SyncStorageException catch (error) {
        if (error.code != SyncStorageErrorCode.invalidData ||
            storage is! ImmutableWritableStorage) {
          rethrow;
        }
        // Only identical intended bytes may repair their immutable address.
      }
    }
    {
      try {
        if (storage case final ImmutableWritableStorage writer) {
          await writer.writeImmutable(remote, file);
        } else {
          await storage.create(
            remote,
            file.openRead(),
            length: size,
            contentType: 'application/octet-stream',
          );
        }
        uploadedBytes += size;
      } on SyncStorageException catch (error) {
        if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
      }
      // Do not let a local content cache substitute for upload verification.
      final verify = ImmutableObjectStore(
        storage,
        Directory(
          path.join(
            cache.path,
            'verify-${DateTime.now().microsecondsSinceEpoch}',
          ),
        ),
      );
      try {
        final checked = await verify.readFile(remote, hash, size: size);
        await cache.create(recursive: true);
        await checked.copy(_cached(hash).path);
      } finally {
        downloadedBytes += verify.downloadedBytes;
        if (await verify.cache.exists()) {
          await verify.cache.delete(recursive: true);
        }
      }
    }
  }

  static void _validateHash(String hash) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'An immutable object has an invalid checksum.',
      );
    }
  }
}
