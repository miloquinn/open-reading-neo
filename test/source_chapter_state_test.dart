import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/models/book.dart';

void main() {
  const store = SourceChapterStateStore();
  late Directory directory;
  late Book book;
  SourceChapterState state(String hash, {bool known = true}) =>
      SourceChapterState(
        schemaVersion: 1,
        bookUid: 'book',
        sourceId: 'source',
        sourceBookId: 'serial',
        materializedContentHash: hash,
        baselineKnown: known,
        chapters: const [],
        catalogChapterIds: const ['one'],
        conflicts: const [],
        revisionOrigin: SourceRevisionOrigin.initialDownload,
      );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-state-');
    book = Book(
      title: 'Book',
      filePath: '${directory.path}/book.txt',
      format: 'txt',
    );
    await File(book.filePath).writeAsString('正文');
  });
  tearDown(() => directory.delete(recursive: true));

  test('restores sidecar after process exits between renames', () async {
    final backup = File('${store.sidecarFor(book).path}.backup');
    await backup.writeAsString(jsonEncode(state('old').toJson()));
    expect((await store.load(book))?.materializedContentHash, 'old');
    expect(await store.sidecarFor(book).exists(), isTrue);
  });
  test('completed sidecar wins over leftover backup', () async {
    await store.save(book, state('new'));
    await File(
      '${store.sidecarFor(book).path}.backup',
    ).writeAsString(jsonEncode(state('old').toJson()));
    expect((await store.load(book))?.materializedContentHash, 'new');
  });
  test(
    'corrupt sidecar is preserved while valid backup is recovered',
    () async {
      await store.sidecarFor(book).writeAsString('{broken');
      await File(
        '${store.sidecarFor(book).path}.backup',
      ).writeAsString(jsonEncode(state('old').toJson()));
      expect((await store.load(book))?.materializedContentHash, 'old');
      final assets = await store.enumerateAssets(book);
      expect(
        await Future.wait(assets.map((a) => a.file.readAsString())),
        contains('{broken'),
      );
    },
  );
  test(
    'same conflict label with different bytes keeps both candidates',
    () async {
      final first = await store.writeConflictAsset(
        book: book,
        conflictId: 'same',
        label: 'source',
        title: 'Chapter',
        body: 'old',
      );
      final second = await store.writeConflictAsset(
        book: book,
        conflictId: 'same',
        label: 'source',
        title: 'Chapter',
        body: 'new',
      );
      expect(first, isNot(second));
      expect(await store.readAsset(book, first), contains('old'));
      expect(await store.readAsset(book, second), contains('new'));
      expect(
        await store.writeConflictAsset(
          book: book,
          conflictId: 'same',
          label: 'source',
          title: 'Chapter',
          body: 'new',
        ),
        second,
      );
    },
  );
  test('resetting a trusted baseline archives its full state', () async {
    await store.save(book, state('old'));
    await store.save(book, state('new', known: false));
    final archives = (await store.enumerateAssets(
      book,
    )).where((a) => a.relativePath.startsWith('source/history/'));
    expect(archives, isNotEmpty);
    final saved = jsonDecode(await archives.single.file.readAsString()) as Map;
    expect(saved['materialized_content_hash'], 'old');
    expect(saved['baseline_known'], isTrue);
    expect((await store.load(book))?.materializedContentHash, 'new');
  });
}
