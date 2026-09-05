import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/txt_edit_service.dart';

void main() {
  late Directory temporary;
  late Directory history;
  late File source;
  late TxtEditService service;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('txt-edit-test-');
    history = Directory(path.join(temporary.path, 'history'));
    source = File(path.join(temporary.path, 'book.txt'));
    service = TxtEditService(historyRootProvider: () async => history);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Book book({String encoding = 'utf8'}) => Book(
    id: 7,
    title: '测试书',
    filePath: source.path,
    format: 'txt',
    textEncoding: encoding,
  );

  test(
    'edits only the exact chapter body and preserves BOM and CRLF',
    () async {
      const original = '第一章 开始\r\n\r\n旧正文\r\n\r\n第二章 后续\r\n第二章正文';
      await source.writeAsBytes(<int>[
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(original),
      ]);
      final chapter = await service.loadChapter(
        book: book(),
        chapterId: 'txt-0',
        prefaceTitle: '序言',
      );

      await service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '新正文\n下一行',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      );

      final bytes = await source.readAsBytes();
      expect(bytes.take(3), <int>[0xef, 0xbb, 0xbf]);
      expect(
        utf8.decode(bytes.sublist(3)),
        '第一章 开始\r\n\r\n新正文\r\n下一行\r\n\r\n第二章 后续\r\n第二章正文',
      );
      expect(await service.listVersions(book()), hasLength(1));
    },
  );

  test('rejects a save when the source changed after opening editor', () async {
    await source.writeAsString('第一章\n原文', encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );
    await source.writeAsString('第一章\n外部修改', encoding: utf8);

    await expectLater(
      service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '编辑器修改',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      ),
      throwsA(
        isA<TxtEditFailure>().having((e) => e.code, 'code', 'source_changed'),
      ),
    );
    expect(await source.readAsString(), '第一章\n外部修改');
  });

  test(
    'preserves an external change made while the replacement is built',
    () async {
      final tail = List<String>.filled(3 * 1024 * 1024, 'a').join();
      await source.writeAsString('第一章\n原文\n$tail', encoding: utf8);
      final chapter = await service.loadChapter(
        book: book(),
        chapterId: 'txt-0',
        prefaceTitle: '序言',
      );
      final journal = File('${source.path}.openreading-edit-journal.json');

      final saving = service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '编辑器修改',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      );
      await _waitUntil(() => journal.exists());
      await source.writeAsString('第一章\n外部并发修改', encoding: utf8, flush: true);

      await expectLater(
        saving,
        throwsA(
          isA<TxtEditFailure>().having((e) => e.code, 'code', 'source_changed'),
        ),
      );
      expect(await source.readAsString(), '第一章\n外部并发修改');
      expect(await journal.exists(), isFalse);
    },
  );

  test('blocks body edits that introduce chapter structure', () async {
    await source.writeAsString('第一章\n原文', encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );

    await expectLater(
      service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '原文\n第二章 新标题\n内容',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      ),
      throwsA(
        isA<TxtEditFailure>().having(
          (e) => e.code,
          'code',
          'chapter_structure_changed',
        ),
      ),
    );
    expect(await source.readAsString(), '第一章\n原文');
  });

  test('rolls file back when metadata commit fails', () async {
    await source.writeAsString('第一章\n原文', encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );

    await expectLater(
      service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '新正文',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
        onCommitted: (_) => throw StateError('database unavailable'),
      ),
      throwsA(isA<TxtEditFailure>()),
    );
    expect(await source.readAsString(), '第一章\n原文');
  });

  test('requires confirmation to convert a non UTF-8 source', () async {
    final utf16 = <int>[0xff, 0xfe];
    for (final unit in '第一章\n原文'.codeUnits) {
      utf16.add(unit & 0xff);
      utf16.add(unit >> 8);
    }
    await source.writeAsBytes(utf16);
    final chapter = await service.loadChapter(
      book: book(encoding: 'utf16le'),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );
    expect(chapter.encoding, TxtEditEncoding.requiresUtf8Conversion);

    await expectLater(
      service.saveChapter(
        book: book(encoding: 'utf16le'),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '新正文',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      ),
      throwsA(
        isA<TxtEditFailure>().having(
          (e) => e.code,
          'code',
          'conversion_confirmation_required',
        ),
      ),
    );

    await service.saveChapter(
      book: book(encoding: 'utf16le'),
      chapterId: chapter.id,
      prefaceTitle: '序言',
      editedText: '新正文',
      expectedBaseContentHash: chapter.baseContentHash,
      allowUtf8Conversion: true,
    );
    expect(utf8.decode(await source.readAsBytes()), '第一章\n新正文');
    final originalVersion = (await service.listVersions(
      book(encoding: 'utf16le'),
    )).single;
    expect(originalVersion.textEncoding, 'utf16le');
    final restored = await service.restoreVersion(
      book: book(encoding: 'utf8'),
      version: originalVersion,
    );
    expect(restored.textEncoding, 'utf16le');
    expect(await source.readAsBytes(), utf16);
  });

  test('restore creates a new recoverable version', () async {
    await source.writeAsString('第一章\n原文', encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );
    await service.saveChapter(
      book: book(),
      chapterId: chapter.id,
      prefaceTitle: '序言',
      editedText: '新正文',
      expectedBaseContentHash: chapter.baseContentHash,
      allowUtf8Conversion: false,
    );
    final originalVersion = (await service.listVersions(book())).single;

    final commit = await service.restoreVersion(
      book: book(),
      version: originalVersion,
    );

    expect(await source.readAsString(), '第一章\n原文');
    expect(
      commit.contentHash,
      sha256.convert(utf8.encode('第一章\n原文')).toString(),
    );
    expect(await service.listVersions(book()), hasLength(2));
  });

  test(
    'recovers the original after a process stops with source moved',
    () async {
      await source.writeAsString('原始内容', encoding: utf8);
      final rollback = File('${source.path}.edit-1.rollback');
      final temporaryFile = File('${source.path}.edit-1.tmp');
      await source.rename(rollback.path);
      await temporaryFile.writeAsString('新内容', encoding: utf8);
      final journal = File('${source.path}.openreading-edit-journal.json');
      await journal.writeAsString(
        jsonEncode(<String, Object>{
          'phase': 'source_moved',
          'source': source.path,
          'temporary': temporaryFile.path,
          'rollback': rollback.path,
          'newHash': sha256.convert(utf8.encode('新内容')).toString(),
        }),
      );

      await service.recoverInterruptedEdit(book());

      expect(await source.readAsString(), '原始内容');
      expect(await rollback.exists(), isFalse);
      expect(await temporaryFile.exists(), isFalse);
      expect(await journal.exists(), isFalse);
    },
  );

  test(
    'finishes a swapped edit when database hash already committed',
    () async {
      await source.writeAsString('新内容', encoding: utf8);
      final rollback = File('${source.path}.edit-2.rollback');
      await rollback.writeAsString('原始内容', encoding: utf8);
      final newHash = sha256.convert(utf8.encode('新内容')).toString();
      final journal = File('${source.path}.openreading-edit-journal.json');
      await journal.writeAsString(
        jsonEncode(<String, Object>{
          'phase': 'swapped',
          'source': source.path,
          'temporary': '${source.path}.edit-2.tmp',
          'rollback': rollback.path,
          'newHash': newHash,
        }),
      );
      final committedBook = book().copyWith(contentHash: newHash);

      await service.recoverInterruptedEdit(committedBook);

      expect(await source.readAsString(), '新内容');
      expect(await rollback.exists(), isFalse);
      expect(await journal.exists(), isFalse);
    },
  );

  test('streams a splice for a multi-megabyte UTF-8 source', () async {
    final tail = List<String>.filled(1100000, '界').join();
    await source.writeAsString('第一章\n开头🙂\n$tail', encoding: utf8);
    expect(await source.length(), greaterThan(2 * 1024 * 1024));
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );

    await service.saveChapter(
      book: book(),
      chapterId: chapter.id,
      prefaceTitle: '序言',
      editedText: '流式替换🙂',
      expectedBaseContentHash: chapter.baseContentHash,
      allowUtf8Conversion: false,
    );

    final result = await source.readAsString();
    expect(result, startsWith('第一章\n流式替换🙂'));
    expect(result, endsWith(tail.substring(32763)));
  });

  test('bounds one pasted edit without limiting the whole TXT', () async {
    await source.writeAsString('第一章\n原文', encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );

    await expectLater(
      service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: List<String>.filled(
          TxtEditService.maxEditedChapterChars + 1,
          'a',
        ).join(),
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
      ),
      throwsA(
        isA<TxtEditFailure>().having(
          (error) => error.code,
          'code',
          'section_too_large',
        ),
      ),
    );
  });

  test(
    'unchanged save still commits metadata for the reader handoff',
    () async {
      await source.writeAsString('第一章\n原文', encoding: utf8);
      final chapter = await service.loadChapter(
        book: book(),
        chapterId: 'txt-0',
        prefaceTitle: '序言',
      );
      TxtEditCommit? metadataCommit;

      await service.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: chapter.text,
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
        onCommitted: (commit) async => metadataCommit = commit,
      );

      expect(metadataCommit, isNotNull);
      expect(await source.readAsString(), '第一章\n原文');
    },
  );

  test(
    'cleanup failure after metadata commit never rolls back new text',
    () async {
      await source.writeAsString('第一章\n原文', encoding: utf8);
      final failingCleanupService = TxtEditService(
        historyRootProvider: () async => history,
        committedCleanup: (_, _) => throw StateError('disk busy'),
      );
      final chapter = await failingCleanupService.loadChapter(
        book: book(),
        chapterId: 'txt-0',
        prefaceTitle: '序言',
      );
      TxtEditCommit? metadataCommit;

      final commit = await failingCleanupService.saveChapter(
        book: book(),
        chapterId: chapter.id,
        prefaceTitle: '序言',
        editedText: '新正文',
        expectedBaseContentHash: chapter.baseContentHash,
        allowUtf8Conversion: false,
        onCommitted: (value) async => metadataCommit = value,
      );

      expect(metadataCommit, isNotNull);
      expect(await source.readAsString(), '第一章\n新正文');
      final journal = File('${source.path}.openreading-edit-journal.json');
      expect(await journal.exists(), isTrue);
      await service.recoverInterruptedEdit(
        book().copyWith(contentHash: commit.contentHash),
      );
      expect(await source.readAsString(), '第一章\n新正文');
      expect(await journal.exists(), isFalse);
    },
  );

  test('oversized chapter edit invalidates following bounded parts', () async {
    final original = List<String>.filled(40000, 'a').join();
    final addition = List<String>.filled(100, 'b').join();
    await source.writeAsString(original, encoding: utf8);
    final chapter = await service.loadChapter(
      book: book(),
      chapterId: 'txt-0',
      prefaceTitle: '序言',
    );
    expect(chapter.text, hasLength(32 * 1024));
    TxtEditCommit? metadataCommit;

    await service.saveChapter(
      book: book(),
      chapterId: chapter.id,
      prefaceTitle: '序言',
      editedText: '${chapter.text}$addition',
      expectedBaseContentHash: chapter.baseContentHash,
      allowUtf8Conversion: false,
      onCommitted: (commit) async => metadataCommit = commit,
    );

    expect(metadataCommit!.mapping!.newText, hasLength(32 * 1024));
    expect(
      metadataCommit!.mapping!.invalidatedChapterIds,
      contains('txt-0-part-1'),
    );
    expect(await source.length(), 40100);
  });
}

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
