import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/txt_chunk_manifest.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('txt-chunks-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('insertion near start preserves most content-defined chunks', () async {
    final random = Random(4201);
    final originalBytes = List<int>.generate(
      8 * 1024 * 1024,
      (_) => random.nextInt(256),
    );
    final editedBytes = <int>[
      ...originalBytes.take(8192),
      ...utf8.encode('插入一小段正文'),
      ...originalBytes.skip(8192),
    ];
    final original = File('${temporary.path}/original.txt')
      ..writeAsBytesSync(originalBytes);
    final edited = File('${temporary.path}/edited.txt')
      ..writeAsBytesSync(editedBytes);
    const builder = TxtChunkManifestBuilder();

    final before = await builder.build(original);
    final after = await builder.build(edited);
    final oldHashes = before.chunks.map((chunk) => chunk.sha256).toSet();
    final reused = after.chunks
        .where((chunk) => oldHashes.contains(chunk.sha256))
        .fold(0, (sum, chunk) => sum + chunk.length);

    expect(reused, greaterThan(7 * 1024 * 1024));
    expect(after.missingByteCount(oldHashes), lessThan(1024 * 1024));
    expect(after.contentSha256, sha256.convert(editedBytes).toString());
  });

  test('capture resumes around verified cached chunks', () async {
    final source = File('${temporary.path}/book.txt');
    final bytes = List<int>.generate(
      3 * 1024 * 1024,
      (index) => (index * 31 + index ~/ 101) & 0xff,
    );
    await source.writeAsBytes(bytes);
    final store = TxtChunkStore(Directory('${temporary.path}/cache'));
    final first = await store.capture(source, textEncoding: 'utf-8');
    final keep = first.chunks.first;
    final removed = first.chunks.last;
    await store.fileForHash(removed.sha256).delete();

    final availableBefore = await store.availableHashes(first);
    expect(availableBefore, contains(keep.sha256));
    expect(availableBefore, isNot(contains(removed.sha256)));
    expect(first.missingByteCount(availableBefore), greaterThan(0));

    final resumed = await store.capture(source, textEncoding: 'utf-8');
    expect(resumed.encode(), first.encode());
    expect(
      await store.availableHashes(resumed),
      resumed.chunks.map((chunk) => chunk.sha256).toSet(),
    );
  });

  test(
    'assemble rejects a corrupt chunk and leaves no partial output',
    () async {
      final source = File('${temporary.path}/book.txt')
        ..writeAsStringSync(List.filled(400000, '章节内容').join());
      final store = TxtChunkStore(Directory('${temporary.path}/cache'));
      final manifest = await store.capture(source, textEncoding: 'utf-8');
      final damaged = store.fileForHash(manifest.chunks.first.sha256);
      await damaged.writeAsBytes([1, 2, 3], flush: true);
      final restored = File('${temporary.path}/restored.txt');

      await expectLater(
        store.assemble(manifest, restored),
        throwsA(isA<FileSystemException>()),
      );
      expect(await restored.exists(), isFalse);
      expect(
        restored.parent.listSync().whereType<File>().where(
          (file) => file.path.startsWith('${restored.path}.'),
        ),
        isEmpty,
      );
    },
  );

  test('assemble cancellation removes its partial output', () async {
    final source = File('${temporary.path}/book.txt')
      ..writeAsStringSync(List.filled(800000, '章节正文').join());
    final store = TxtChunkStore(Directory('${temporary.path}/cache'));
    final manifest = await store.capture(source, textEncoding: 'utf8');
    final restored = File('${temporary.path}/cancelled.txt');
    var checks = 0;

    await expectLater(
      store.assemble(manifest, restored, shouldContinue: () => checks++ < 2),
      throwsA(isA<TxtChunkOperationCancelled>()),
    );
    expect(await restored.exists(), isFalse);
    expect(
      restored.parent.listSync().whereType<File>().where(
        (file) => file.path.startsWith('${restored.path}.'),
      ),
      isEmpty,
    );
  });

  test(
    'manifest round trip preserves protocol fields and validates layout',
    () async {
      final source = File('${temporary.path}/book.txt')
        ..writeAsStringSync('第一章\n${List.filled(200000, '内容').join()}');
      const builder = TxtChunkManifestBuilder();
      final manifest = await builder.build(source, textEncoding: 'utf-8');

      final decoded = TxtChunkManifest.decode(manifest.encode());
      expect(decoded.contentSha256, manifest.contentSha256);
      expect(decoded.byteLength, manifest.byteLength);
      expect(decoded.textEncoding, 'utf-8');
      expect(decoded.chunks.length, manifest.chunks.length);

      final json = manifest.toJson();
      final chunks = (json['chunks'] as List).cast<Map<String, Object>>();
      chunks.first['offset'] = 1;
      expect(
        () => TxtChunkManifest.decode(jsonEncode(json)),
        throwsFormatException,
      );
    },
  );
}
