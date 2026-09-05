import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

class TxtChunkOperationCancelled implements Exception {
  const TxtChunkOperationCancelled();
}

/// Bounded-memory, content-defined chunking for large mutable TXT files.
///
/// Boundaries depend on the surrounding bytes instead of absolute offsets, so
/// an insertion normally changes only the chunks around the edit. Chunks are
/// immutable and addressed by SHA-256; [TxtChunkManifest] is the ordered book
/// version that can later be committed with a conditional WebDAV write.
class TxtChunkManifestBuilder {
  const TxtChunkManifestBuilder({
    this.minChunkBytes = 64 * 1024,
    this.averageChunkBytes = 256 * 1024,
    this.maxChunkBytes = 1024 * 1024,
  }) : assert(minChunkBytes >= 4 * 1024),
       assert(averageChunkBytes >= minChunkBytes),
       assert(maxChunkBytes >= averageChunkBytes),
       assert(maxChunkBytes <= 4 * 1024 * 1024),
       assert(
         averageChunkBytes & (averageChunkBytes - 1) == 0,
         'averageChunkBytes must be a power of two',
       );

  final int minChunkBytes;
  final int averageChunkBytes;
  final int maxChunkBytes;

  Future<TxtChunkManifest> build(
    File source, {
    String? textEncoding,
    FutureOr<void> Function(TxtChunkReference chunk, Uint8List bytes)? onChunk,
  }) async {
    if (!await source.exists()) {
      throw const FileSystemException('TXT source file does not exist.');
    }

    final chunks = <TxtChunkReference>[];
    final current = BytesBuilder(copy: false);
    final wholeOutput = _SingleDigestSink();
    final wholeInput = sha256.startChunkedConversion(wholeOutput);
    final boundaryMask = averageChunkBytes - 1;
    var rolling = 0;
    var offset = 0;
    var totalLength = 0;

    Future<void> finishChunk() async {
      if (current.isEmpty) return;
      final bytes = current.takeBytes();
      final reference = TxtChunkReference(
        sha256: sha256.convert(bytes).toString(),
        offset: offset,
        length: bytes.length,
      );
      chunks.add(reference);
      await onChunk?.call(reference, bytes);
      offset += bytes.length;
      rolling = 0;
    }

    await for (final input in source.openRead()) {
      wholeInput.add(input);
      totalLength += input.length;
      var segmentStart = 0;
      for (var index = 0; index < input.length; index++) {
        final byte = input[index];
        rolling = ((rolling << 1) + _gear[byte]) & _rollingMask;
        final candidateLength = current.length + index - segmentStart + 1;
        final atBoundary =
            candidateLength >= maxChunkBytes ||
            (candidateLength >= minChunkBytes && rolling & boundaryMask == 0);
        if (!atBoundary) continue;
        current.add(input.sublist(segmentStart, index + 1));
        await finishChunk();
        segmentStart = index + 1;
      }
      if (segmentStart < input.length) {
        current.add(input.sublist(segmentStart));
      }
    }
    await finishChunk();
    wholeInput.close();

    return TxtChunkManifest(
      contentSha256: wholeOutput.value.toString(),
      byteLength: totalLength,
      textEncoding: textEncoding,
      chunks: List.unmodifiable(chunks),
      minChunkBytes: minChunkBytes,
      averageChunkBytes: averageChunkBytes,
      maxChunkBytes: maxChunkBytes,
    );
  }
}

class TxtChunkManifest {
  const TxtChunkManifest({
    required this.contentSha256,
    required this.byteLength,
    required this.chunks,
    required this.minChunkBytes,
    required this.averageChunkBytes,
    required this.maxChunkBytes,
    this.textEncoding,
  });

  static const protocolVersion = 1;

  final String contentSha256;
  final int byteLength;
  final String? textEncoding;
  final List<TxtChunkReference> chunks;
  final int minChunkBytes;
  final int averageChunkBytes;
  final int maxChunkBytes;

  int missingByteCount(Set<String> availableChunkHashes) {
    final counted = <String>{};
    return chunks
        .where(
          (chunk) =>
              !availableChunkHashes.contains(chunk.sha256) &&
              counted.add(chunk.sha256),
        )
        .fold(0, (total, chunk) => total + chunk.length);
  }

  Map<String, Object?> toJson() => {
    'version': protocolVersion,
    'contentSha256': contentSha256,
    'byteLength': byteLength,
    if (textEncoding != null) 'textEncoding': textEncoding,
    'chunking': {
      'algorithm': 'gear-v1',
      'minBytes': minChunkBytes,
      'averageBytes': averageChunkBytes,
      'maxBytes': maxChunkBytes,
    },
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());

  factory TxtChunkManifest.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != protocolVersion ||
        decoded['contentSha256'] is! String ||
        decoded['byteLength'] is! int ||
        decoded['chunks'] is! List ||
        decoded['chunking'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid TXT chunk manifest.');
    }
    final chunking = decoded['chunking'] as Map<String, dynamic>;
    if (chunking['algorithm'] != 'gear-v1' ||
        chunking['minBytes'] is! int ||
        chunking['averageBytes'] is! int ||
        chunking['maxBytes'] is! int) {
      throw const FormatException('Unsupported TXT chunking parameters.');
    }
    final minBytes = chunking['minBytes'] as int;
    final averageBytes = chunking['averageBytes'] as int;
    final maxBytes = chunking['maxBytes'] as int;
    if (minBytes < 4 * 1024 ||
        averageBytes < minBytes ||
        averageBytes & (averageBytes - 1) != 0 ||
        maxBytes < averageBytes ||
        maxBytes > 4 * 1024 * 1024 ||
        !_sha256Pattern.hasMatch(decoded['contentSha256'] as String) ||
        (decoded['textEncoding'] != null &&
            decoded['textEncoding'] is! String)) {
      throw const FormatException('Unsafe TXT chunk manifest parameters.');
    }
    final chunks = (decoded['chunks'] as List)
        .map(TxtChunkReference.fromJson)
        .toList(growable: false);
    var expectedOffset = 0;
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      if (chunk.offset != expectedOffset ||
          chunk.length <= 0 ||
          chunk.length > maxBytes ||
          (index < chunks.length - 1 && chunk.length < minBytes)) {
        throw const FormatException('TXT chunks are not contiguous.');
      }
      expectedOffset += chunk.length;
    }
    if (expectedOffset != decoded['byteLength']) {
      throw const FormatException('TXT manifest byte length does not match.');
    }
    return TxtChunkManifest(
      contentSha256: decoded['contentSha256'] as String,
      byteLength: decoded['byteLength'] as int,
      textEncoding: decoded['textEncoding'] as String?,
      chunks: List.unmodifiable(chunks),
      minChunkBytes: minBytes,
      averageChunkBytes: averageBytes,
      maxChunkBytes: maxBytes,
    );
  }
}

class TxtChunkReference {
  const TxtChunkReference({
    required this.sha256,
    required this.offset,
    required this.length,
  });

  final String sha256;
  final int offset;
  final int length;

  Map<String, Object> toJson() => {
    'sha256': sha256,
    'offset': offset,
    'length': length,
  };

  factory TxtChunkReference.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['sha256'] is! String ||
        value['offset'] is! int ||
        value['length'] is! int) {
      throw const FormatException('Invalid TXT chunk reference.');
    }
    final hash = value['sha256'] as String;
    if (!_sha256Pattern.hasMatch(hash)) {
      throw const FormatException('Invalid TXT chunk checksum.');
    }
    return TxtChunkReference(
      sha256: hash,
      offset: value['offset'] as int,
      length: value['length'] as int,
    );
  }
}

/// Local immutable cache used for resumable upload and verified reconstruction.
class TxtChunkStore {
  const TxtChunkStore(this.root);

  final Directory root;

  Future<TxtChunkManifest> capture(
    File source, {
    String? textEncoding,
    TxtChunkManifestBuilder builder = const TxtChunkManifestBuilder(),
  }) => builder.build(
    source,
    textEncoding: textEncoding,
    onChunk: (reference, bytes) => _store(reference, bytes),
  );

  Future<Set<String>> availableHashes(TxtChunkManifest manifest) async {
    final available = <String>{};
    for (final chunk in manifest.chunks) {
      final file = fileForHash(chunk.sha256);
      if (await _matches(file, chunk)) available.add(chunk.sha256);
    }
    return available;
  }

  Future<bool> contains(TxtChunkReference reference) =>
      _matches(fileForHash(reference.sha256), reference);

  Future<void> acceptDownloaded(
    TxtChunkReference reference,
    File downloaded,
  ) async {
    if (!await _matches(downloaded, reference)) {
      throw FileSystemException(
        'Downloaded TXT chunk is corrupt.',
        downloaded.path,
      );
    }
    final destination = fileForHash(reference.sha256);
    if (await _matches(destination, reference)) {
      await downloaded.delete();
      return;
    }
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      if (await _matches(destination, reference)) {
        await downloaded.delete();
        return;
      }
      await destination.delete();
    }
    try {
      await downloaded.rename(destination.path);
    } on FileSystemException {
      if (await _matches(destination, reference)) {
        if (await downloaded.exists()) await downloaded.delete();
        return;
      }
      rethrow;
    }
  }

  /// Reconstructs into a new file. The caller owns any final journaled swap.
  Future<void> assemble(
    TxtChunkManifest manifest,
    File destination, {
    bool Function()? shouldContinue,
  }) async {
    if (await destination.exists()) {
      throw FileSystemException(
        'Refusing to replace an existing file without a caller-owned journal.',
        destination.path,
      );
    }
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.${_uniqueSuffix()}.part');
    final output = partial.openWrite();
    final wholeOutput = _SingleDigestSink();
    final wholeInput = sha256.startChunkedConversion(wholeOutput);
    var written = 0;
    var hashClosed = false;
    var outputClosed = false;
    try {
      for (final chunk in manifest.chunks) {
        if (shouldContinue?.call() == false) {
          throw const TxtChunkOperationCancelled();
        }
        final source = fileForHash(chunk.sha256);
        if (!await _matches(source, chunk)) {
          throw FileSystemException(
            'TXT chunk is missing or corrupt.',
            source.path,
          );
        }
        await output.addStream(
          source.openRead().map((bytes) {
            if (shouldContinue?.call() == false) {
              throw const TxtChunkOperationCancelled();
            }
            wholeInput.add(bytes);
            written += bytes.length;
            return bytes;
          }),
        );
      }
      await output.flush();
      wholeInput.close();
      hashClosed = true;
      if (written != manifest.byteLength ||
          wholeOutput.value.toString() != manifest.contentSha256) {
        throw const FormatException(
          'Reconstructed TXT checksum does not match.',
        );
      }
      await output.close();
      outputClosed = true;
      await partial.rename(destination.path);
    } catch (_) {
      if (!hashClosed) {
        try {
          wholeInput.close();
        } catch (_) {}
      }
      if (!outputClosed) {
        try {
          await output.close();
        } catch (_) {}
      }
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    }
  }

  File fileForHash(String hash) =>
      File(path.join(root.path, hash.substring(0, 2), '$hash.chunk'));

  Future<void> _store(TxtChunkReference reference, Uint8List bytes) async {
    final destination = fileForHash(reference.sha256);
    if (await _matches(destination, reference)) return;
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.${_uniqueSuffix()}.part');
    await partial.writeAsBytes(bytes, flush: true);
    if (!await _matches(partial, reference)) {
      await partial.delete();
      throw const FormatException(
        'Generated TXT chunk checksum does not match.',
      );
    }
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
  }

  Future<bool> _matches(File file, TxtChunkReference reference) async =>
      await file.exists() &&
      await file.length() == reference.length &&
      (await sha256.bind(file.openRead()).first).toString() == reference.sha256;
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) throw StateError('Digest is not complete.');
    return digest;
  }

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

const _rollingMask = 0x7fffffff;
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

// Deterministic pseudo-random gear values. They are protocol constants derived
// from each byte and do not depend on process hash randomization.
final List<int> _gear = List<int>.generate(256, (index) {
  var value = (index + 1) * 0x45d9f3b;
  value = ((value >> 16) ^ value) * 0x45d9f3b;
  value = (value >> 16) ^ value;
  return value & _rollingMask;
}, growable: false);

String _uniqueSuffix() =>
    '$pid-${DateTime.now().microsecondsSinceEpoch}-'
    '${Random.secure().nextInt(1 << 32)}';
