import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'storage/immutable_object_store.dart';
import 'storage/sync_storage.dart';

/// A revision is the single commit point for both whole files and chunked TXT.
/// Parents express causality; wall clock time never silently wins a conflict.
class BookRevision {
  const BookRevision(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  String get bookUid => data['book_uid'] as String;
  String get hash => data['sha256'] as String;
  int get size => data['size'] as int;
  List<String> get parents => (data['parents'] as List).cast<String>();
  List<Map<String, dynamic>> get chunks => (data['chunks'] as List)
      .map((item) => (item as Map).cast<String, dynamic>())
      .toList();
  String? get sourceHash => data['source_state_sha256'] as String?;
  List<dynamic> get sourceAssets => data['source_assets'] as List? ?? const [];
  String get remotePath =>
      BookRevisionRepository.revisionPath(bookUid, id).value;
}

class BookRevisionRepository {
  BookRevisionRepository(this.objects);
  final ImmutableObjectStore objects;
  SyncStorage get storage => objects.storage;
  static const minChunkBytes = 32 * 1024;
  static const maxChunkBytes = 256 * 1024;
  static const averageChunkBytes = 64 * 1024;
  static const maxChunks = 100000;
  static final _gear = List<int>.generate(256, (index) {
    var value = index + 1;
    for (var round = 0; round < 5; round++) {
      value = (value * 1664525 + 1013904223) & 0xffffffff;
    }
    return value;
  });

  static String folder(String bookUid) =>
      sha256.convert(utf8.encode(bookUid)).toString();
  static SyncPath revisionPath(String bookUid, String id) =>
      SyncPath('books/${folder(bookUid)}/revisions/$id.json');
  static SyncPath chunkPath(String bookUid, String hash) => SyncPath(
    'books/${folder(bookUid)}/chunks/${hash.substring(0, 2)}/$hash.bin',
  );

  Future<BookRevision> read(String bookUid, String id) async {
    if (!_hashPattern.hasMatch(id)) {
      throw _invalid('Invalid revision identity.');
    }
    final text = await objects.readText(revisionPath(bookUid, id), id);
    final data = (jsonDecode(text) as Map).cast<String, dynamic>();
    if (data['protocol'] != 'open-reading-book' ||
        data['schema_version'] != 2 ||
        data['book_uid'] != bookUid ||
        data['size'] is! int ||
        data['size'] < 0 ||
        !_hashPattern.hasMatch(data['sha256'] as String? ?? '') ||
        data['parents'] is! List ||
        data['chunks'] is! List) {
      throw _invalid('Invalid book revision.');
    }
    final revision = BookRevision(id, data);
    if (revision.parents.length > 1024 ||
        revision.parents.any(
          (parent) => !_hashPattern.hasMatch(parent) || parent == id,
        ) ||
        revision.parents.toSet().length != revision.parents.length ||
        revision.chunks.isEmpty ||
        revision.chunks.length > maxChunks) {
      throw _invalid('Invalid revision ancestry or chunk count.');
    }
    var total = 0;
    for (final chunk in revision.chunks) {
      if (!_hashPattern.hasMatch(chunk['sha256'] as String? ?? '') ||
          chunk['size'] is! int ||
          chunk['size'] < 0) {
        throw _invalid('Invalid content chunk.');
      }
      total += chunk['size'] as int;
    }
    if (total != revision.size) {
      throw _invalid('Revision size does not match its chunks.');
    }
    return revision;
  }

  /// Always union in the known base: a temporarily incomplete DAV listing must
  /// not turn a previously synchronized book into a new, unrelated publication.
  Future<List<BookRevision>> tips(
    String bookUid, {
    String? knownRevision,
  }) async {
    SyncListing listing;
    try {
      listing = await storage.list(
        SyncPath('books/${folder(bookUid)}/revisions'),
      );
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.notFound) rethrow;
      listing = const SyncListing(objects: [], prefixes: []);
    }
    final ids = <String>{
      for (final entry in listing.objects)
        if (RegExp(r'/[a-f0-9]{64}\.json$').hasMatch(entry.path.value))
          path.posix.basenameWithoutExtension(entry.path.value),
      if (knownRevision != null && _hashPattern.hasMatch(knownRevision))
        knownRevision,
    };
    final revisions = <String, BookRevision>{};
    final pending = ids.toList();
    final parents = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (revisions.containsKey(id)) continue;
      final revision = await read(bookUid, id);
      revisions[id] = revision;
      for (final parent in revision.parents) {
        parents.add(parent);
        if (!revisions.containsKey(parent)) pending.add(parent);
      }
    }
    final result =
        revisions.values.where((r) => !parents.contains(r.id)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (revisions.isNotEmpty && result.isEmpty) {
      throw _invalid('Cyclic revision ancestry.');
    }
    return result;
  }

  Future<bool> descendsFrom(BookRevision revision, String ancestor) async {
    final pending = [...revision.parents];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (id == ancestor) return true;
      if (visited.add(id)) {
        pending.addAll((await read(revision.bookUid, id)).parents);
      }
    }
    return false;
  }

  Future<BookRevision> publish({
    required String bookUid,
    required File file,
    required String hash,
    required String format,
    required String fileName,
    required List<String> parents,
    required Map<String, dynamic> metadata,
    BookRevision? base,
    bool Function()? shouldContinue,
  }) async {
    final chunks = <Map<String, dynamic>>[];
    final known = {
      for (final chunk in base?.chunks ?? <Map<String, dynamic>>[])
        chunk['sha256'] as String,
    };
    final temporary = await Directory.systemTemp.createTemp('sync-chunk-');
    try {
      Future<void> publishChunk(List<int> bytes) async {
        if (shouldContinue?.call() == false) {
          throw _invalid('Content transfer was paused.');
        }
        final digest = ImmutableObjectStore.hashBytes(bytes);
        chunks.add({'sha256': digest, 'size': bytes.length});
        if (chunks.length > maxChunks) {
          throw _invalid('The book exceeds the revision chunk limit.');
        }
        if (known.contains(digest)) return;
        final chunk = File(path.join(temporary.path, digest));
        await chunk.writeAsBytes(bytes, flush: true);
        await objects.putFile(chunkPath(bookUid, digest), chunk, digest);
        known.add(digest);
        await chunk.delete();
      }

      if (format.toLowerCase() == 'txt') {
        final buffer = Uint8List(maxChunkBytes);
        var count = 0, fingerprint = 0;
        await for (final bytes in file.openRead()) {
          for (final byte in bytes) {
            buffer[count++] = byte;
            fingerprint = ((fingerprint << 1) + _gear[byte]) & 0xffffffff;
            if (count == maxChunkBytes ||
                (count >= minChunkBytes &&
                    (fingerprint & (averageChunkBytes - 1)) == 0)) {
              await publishChunk(Uint8List.sublistView(buffer, 0, count));
              count = 0;
              fingerprint = 0;
            }
          }
        }
        if (count > 0 || chunks.isEmpty) {
          await publishChunk(Uint8List.sublistView(buffer, 0, count));
        }
      } else {
        chunks.add({'sha256': hash, 'size': await file.length()});
        if (!known.contains(hash)) {
          await objects.putFile(chunkPath(bookUid, hash), file, hash);
        }
      }
      if (await ImmutableObjectStore.hashFile(file) != hash) {
        throw _invalid('The local revision changed during upload.');
      }
      final orderedParents = parents.toSet().toList()..sort();
      final data = <String, dynamic>{
        'protocol': 'open-reading-book',
        'schema_version': 2,
        'book_uid': bookUid,
        'parents': orderedParents,
        'sha256': hash,
        'size': await file.length(),
        'format': format,
        'original_file_name': fileName,
        'chunks': chunks,
        ...metadata,
      };
      final text = jsonEncode(data);
      final id = ImmutableObjectStore.hashBytes(utf8.encode(text));
      await objects.putText(revisionPath(bookUid, id), text);
      return BookRevision(id, data);
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> materialize(BookRevision revision, File destination) async {
    final sink = destination.openWrite();
    try {
      for (final chunk in revision.chunks) {
        final hash = chunk['sha256'] as String;
        final file = await objects.readFile(
          chunkPath(revision.bookUid, hash),
          hash,
          size: chunk['size'] as int,
        );
        await sink.addStream(file.openRead());
      }
    } finally {
      await sink.close();
    }
    if (await destination.length() != revision.size ||
        await ImmutableObjectStore.hashFile(destination) != revision.hash) {
      throw _invalid('The reconstructed book failed checksum verification.');
    }
  }

  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  static SyncStorageException _invalid(String message) =>
      SyncStorageException(SyncStorageErrorCode.invalidData, message);
}
