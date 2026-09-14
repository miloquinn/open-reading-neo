import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'storage/sync_storage.dart';

/// A format marker is the only non-content-addressed protocol object. It is
/// created once with If-None-Match and always read back. Existing formats are
/// never overwritten or interpreted as empty spaces.
class SyncSpace {
  static final formatPath = SyncPath('format.json');
  static String validate(String text) {
    try {
      final data = (jsonDecode(text) as Map).cast<String, dynamic>();
      if (data['protocol'] != 'open-reading-sync' ||
          data['schema_version'] != 2 ||
          data['space_id'] is! String ||
          (data['space_id'] as String).isEmpty ||
          data['metadata_encoding'] != 'json' ||
          data['content_encryption'] != 'none') {
        throw const FormatException();
      }
      return data['space_id'] as String;
    } catch (_) {
      throw const SyncStorageException(
        SyncStorageErrorCode.unsupported,
        'This folder uses an older or unsupported sync protocol. Choose a new empty folder; existing cloud files will be preserved.',
      );
    }
  }

  static Future<String?> inspect(SyncStorage storage) async {
    try {
      return validate((await storage.readText(formatPath)).text);
    } on SyncStorageException catch (error) {
      if (error.code == SyncStorageErrorCode.notFound) return null;
      rethrow;
    }
  }

  static Future<String> ensure(SyncStorage storage) async {
    final existing = await inspect(storage);
    if (existing != null) return existing;
    final text = jsonEncode({
      'protocol': 'open-reading-sync',
      'schema_version': 2,
      'space_id': const Uuid().v4(),
      'metadata_encoding': 'json',
      'content_encryption': 'none',
    });
    final bytes = utf8.encode(text);
    try {
      await storage.create(
        formatPath,
        Stream.value(bytes),
        length: bytes.length,
        contentType: 'application/json; charset=utf-8',
      );
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
    }
    return validate((await storage.readText(formatPath)).text);
  }
}
