import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:xxread/core/reader/indexed_text_reader.dart';
import 'package:xxread/core/reader/streaming_txt_index.dart';
import 'package:xxread/core/reader/txt_chapter_parser.dart';
import 'package:xxread/models/book.dart';

enum TxtEditEncoding { utf8, requiresUtf8Conversion }

@immutable
class TxtEditableChapter {
  const TxtEditableChapter({
    required this.id,
    required this.title,
    required this.text,
    required this.encoding,
    required this.baseContentHash,
  });

  final String id;
  final String title;
  final String text;
  final TxtEditEncoding encoding;
  final String baseContentHash;
}

@immutable
class TxtEditVersion {
  const TxtEditVersion({
    required this.id,
    required this.createdAt,
    required this.contentHash,
    required this.textEncoding,
    required this.file,
  });

  final String id;
  final DateTime createdAt;
  final String contentHash;
  final String textEncoding;
  final File file;
}

@immutable
class TxtEditCommit {
  const TxtEditCommit({
    required this.contentHash,
    required this.modifiedAt,
    required this.textEncoding,
    this.mapping,
    this.invalidateAllReferences = false,
  });

  final String contentHash;
  final DateTime modifiedAt;
  final String textEncoding;
  final TxtEditRevisionMapping? mapping;
  final bool invalidateAllReferences;
}

@immutable
class TxtEditRevisionMapping {
  const TxtEditRevisionMapping({
    required this.chapterId,
    required this.oldLength,
    required this.oldText,
    required this.newText,
    required this.commonPrefixLength,
    required this.commonSuffixLength,
    this.invalidatedChapterIds = const <String>[],
  });

  final String chapterId;
  final int oldLength;
  final String oldText;
  final String newText;
  final int commonPrefixLength;
  final int commonSuffixLength;
  final List<String> invalidatedChapterIds;

  bool invalidatesChapter(String? chapterId) =>
      chapterId != null && invalidatedChapterIds.contains(chapterId);

  int? mapOffset(int offset) {
    if (offset <= commonPrefixLength) return offset;
    final oldSuffixStart = oldLength - commonSuffixLength;
    if (offset >= oldSuffixStart) return newText.length - (oldLength - offset);
    return null;
  }
}

class TxtEditFailure implements Exception {
  const TxtEditFailure(this.code, [this.cause]);

  final String code;
  final Object? cause;

  @override
  String toString() =>
      'TxtEditFailure($code${cause == null ? '' : ': $cause'})';
}

typedef TxtEditHistoryRootProvider = Future<Directory> Function();
typedef TxtEditCommittedCleanup =
    Future<void> Function(File rollback, File journal);

class TxtEditService {
  static const int maxEditedChapterChars = 4 * 1024 * 1024;
  TxtEditService({
    TxtEditHistoryRootProvider? historyRootProvider,
    TxtEditCommittedCleanup? committedCleanup,
  }) : _committedCleanup = committedCleanup ?? _defaultCommittedCleanup,
       _historyRootProvider =
           historyRootProvider ??
           (() async => Directory(
             path.join(
               (await getApplicationSupportDirectory()).path,
               'txt_edit_history',
             ),
           ));

  final TxtEditHistoryRootProvider _historyRootProvider;
  final TxtEditCommittedCleanup _committedCleanup;

  Future<TxtEditableChapter> loadChapter({
    required Book book,
    required String chapterId,
    required String prefaceTitle,
  }) async {
    await recoverInterruptedEdit(book);
    final source = await _prepareSource(book, prefaceTitle: prefaceTitle);
    try {
      final section = source.section(chapterId);
      if (section == null) throw const TxtEditFailure('chapter_changed');
      return TxtEditableChapter(
        id: section.id,
        title: section.title,
        text: await readIndexedUtf8Range(
          path: source.dataFile.path,
          startOffset: section.start,
          endOffset: section.end,
        ),
        encoding: source.requiresConversion
            ? TxtEditEncoding.requiresUtf8Conversion
            : TxtEditEncoding.utf8,
        baseContentHash: source.contentHash,
      );
    } finally {
      await source.dispose();
    }
  }

  Future<TxtEditCommit> saveChapter({
    required Book book,
    required String chapterId,
    required String prefaceTitle,
    required String editedText,
    required String expectedBaseContentHash,
    required bool allowUtf8Conversion,
    Future<void> Function(TxtEditCommit commit)? onCommitted,
  }) async {
    await recoverInterruptedEdit(book);
    if (editedText.length > maxEditedChapterChars) {
      throw const TxtEditFailure('section_too_large');
    }
    if (_containsChapterHeading(editedText)) {
      throw const TxtEditFailure('chapter_structure_changed');
    }
    final source = await _prepareSource(book, prefaceTitle: prefaceTitle);
    try {
      if (source.contentHash != expectedBaseContentHash) {
        throw const TxtEditFailure('source_changed');
      }
      if (source.requiresConversion && !allowUtf8Conversion) {
        throw const TxtEditFailure('conversion_confirmation_required');
      }
      final selected = source.section(chapterId);
      if (selected == null) throw const TxtEditFailure('chapter_changed');
      final oldBody = await readIndexedUtf8Range(
        path: source.dataFile.path,
        startOffset: selected.start,
        endOffset: selected.end,
      );
      final inserted = _normalizeInsertedNewlines(
        editedText,
        source.predominantNewline,
      );
      final insertedBytes = Uint8List.fromList(utf8.encode(inserted));
      final candidate = File(
        path.join(source.workDirectory.path, 'candidate.txt'),
      );
      final spliceSource = source.requiresConversion
          ? source.dataFile
          : File(book.filePath);
      final bomLength = !source.requiresConversion && source.hasUtf8Bom ? 3 : 0;
      await _writeUtf8Splice(
        source: spliceSource,
        temporary: candidate,
        startByte: selected.start + bomLength,
        endByte: selected.end + bomLength,
        insertedBytes: insertedBytes,
      );
      final nextSource = await _prepareSource(
        book.copyWith(filePath: candidate.path, textEncoding: 'utf8'),
        prefaceTitle: prefaceTitle,
        workDirectory: Directory(path.join(source.workDirectory.path, 'next')),
      );
      final nextSelected = nextSource.section(chapterId);
      final invalidatedChapterIds = <String>[
        if (nextSelected == null) chapterId,
        if (selected.sourceChapterId != null)
          ...source.sections
              .where(
                (section) =>
                    section.sourceChapterId == selected.sourceChapterId &&
                    section.sourceBodyStart > selected.sourceBodyStart,
              )
              .map((section) => section.id),
      ];
      final newBody = nextSelected == null
          ? ''
          : await readIndexedUtf8Range(
              path: nextSource.dataFile.path,
              startOffset: nextSelected.start,
              endOffset: nextSelected.end,
            );
      final mapping = _revisionMapping(
        chapterId,
        oldBody,
        newBody,
        invalidatedChapterIds: invalidatedChapterIds,
      );
      return await _replaceFile(
        book: book,
        expectedBaseContentHash: expectedBaseContentHash,
        expectedNewHash: nextSource.contentHash,
        writeTemporary: (temporary) => _copyFile(candidate, temporary),
        textEncoding: 'utf8',
        mapping: mapping,
        onCommitted: onCommitted,
      );
    } finally {
      await source.dispose();
    }
  }

  Future<List<TxtEditVersion>> listVersions(Book book) async {
    await recoverInterruptedEdit(book);
    final directory = await _historyDirectory(book);
    if (!await directory.exists()) return const <TxtEditVersion>[];
    final versions = <TxtEditVersion>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      final id = path.basenameWithoutExtension(entity.path);
      final parts = id.split('_');
      final micros = int.tryParse(parts.first);
      if (micros == null) continue;
      final metadata = File('${entity.path}.json');
      var textEncoding = 'utf8';
      if (await metadata.exists()) {
        try {
          final values = jsonDecode(await metadata.readAsString()) as Map;
          textEncoding = values['textEncoding'] as String? ?? 'utf8';
        } catch (_) {}
      }
      versions.add(
        TxtEditVersion(
          id: id,
          createdAt: DateTime.fromMicrosecondsSinceEpoch(micros),
          contentHash: (await sha256.bind(entity.openRead()).first).toString(),
          textEncoding: textEncoding,
          file: entity,
        ),
      );
    }
    versions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return versions;
  }

  Future<TxtEditCommit> restoreVersion({
    required Book book,
    required TxtEditVersion version,
    Future<void> Function(TxtEditCommit commit)? onCommitted,
  }) async {
    await recoverInterruptedEdit(book);
    if (!await version.file.exists()) {
      throw const TxtEditFailure('version_missing');
    }
    return _replaceFile(
      book: book,
      expectedNewHash: version.contentHash,
      writeTemporary: (file) => _copyFile(version.file, file),
      textEncoding: version.textEncoding,
      invalidateAllReferences: true,
      onCommitted: onCommitted,
    );
  }

  Future<_PreparedTxtSource> _prepareSource(
    Book book, {
    required String prefaceTitle,
    Directory? workDirectory,
  }) async {
    if (book.format.toLowerCase() != 'txt' || book.isOnline) {
      throw const TxtEditFailure('unsupported_book');
    }
    final file = File(book.filePath);
    if (!await file.exists()) throw const TxtEditFailure('source_missing');
    final directory =
        workDirectory ??
        Directory(
          path.join(
            (await _historyDirectory(book)).path,
            'work-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
    await directory.create(recursive: true);
    final dataFile = File(path.join(directory.path, 'normalized.utf8'));
    late Map<String, dynamic> values;
    try {
      values = await compute(buildStreamingTxtIndexWorker, <String, dynamic>{
        'sourcePath': file.path,
        'dataPath': dataFile.path,
        'encoding': book.textEncoding,
        'title': book.title,
        'prefaceTitle': prefaceTitle,
      });
    } catch (error) {
      if (await directory.exists()) await directory.delete(recursive: true);
      if (error is FormatException) {
        throw TxtEditFailure('invalid_encoding', error);
      }
      rethrow;
    }
    return _PreparedTxtSource.fromMap(
      values,
      workDirectory: directory,
      dataFile: dataFile,
    );
  }

  Future<void> _copyFile(File source, File target) async {
    await source.openRead().pipe(target.openWrite());
  }

  bool _containsChapterHeading(String text) => splitOversizedTxtSections(
    text,
    parseTxtChapterSections(text, fallbackTitle: '', prefaceTitle: ''),
  ).any((section) => section.isNeedSplitTitle);

  Future<TxtEditCommit> _replaceFile({
    required Book book,
    String? expectedBaseContentHash,
    String? expectedNewHash,
    required Future<void> Function(File temporary) writeTemporary,
    required String textEncoding,
    TxtEditRevisionMapping? mapping,
    bool invalidateAllReferences = false,
    Future<void> Function(TxtEditCommit commit)? onCommitted,
  }) async {
    final source = File(book.filePath);
    final originalHash = (await sha256.bind(source.openRead()).first)
        .toString();
    final baseContentHash = expectedBaseContentHash ?? originalHash;
    if (originalHash != baseContentHash) {
      throw const TxtEditFailure('source_changed');
    }
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporary = File('${source.path}.edit-$nonce.tmp');
    final rollback = File('${source.path}.edit-$nonce.rollback');
    final journal = _journalFile(source);
    try {
      await _writeJournal(
        journal,
        phase: 'writing',
        source: source,
        temporary: temporary,
        rollback: rollback,
        newHash: expectedNewHash,
      );
      await writeTemporary(temporary);
      final writtenHash = await sha256.bind(temporary.openRead()).first;
      final newHash = writtenHash.toString();
      if (expectedNewHash != null && newHash != expectedNewHash) {
        throw const TxtEditFailure('write_verification_failed');
      }
      if (originalHash == newHash) {
        await _verifySourceHash(source, baseContentHash);
        final stat = await source.stat();
        if (await journal.exists()) await journal.delete();
        final commit = TxtEditCommit(
          contentHash: newHash,
          modifiedAt: stat.modified,
          textEncoding: textEncoding,
          mapping: mapping,
          invalidateAllReferences: false,
        );
        await onCommitted?.call(commit);
        return commit;
      }
      await _verifySourceHash(source, baseContentHash);
      await _writeHistory(book, source, originalHash);
      await _writeJournal(
        journal,
        phase: 'prepared',
        source: source,
        temporary: temporary,
        rollback: rollback,
        newHash: newHash,
      );
      await _verifySourceHash(source, baseContentHash);
      await source.rename(rollback.path);
      await _writeJournal(
        journal,
        phase: 'source_moved',
        source: source,
        temporary: temporary,
        rollback: rollback,
        newHash: newHash,
      );
      try {
        await temporary.rename(source.path);
        await _writeJournal(
          journal,
          phase: 'swapped',
          source: source,
          temporary: temporary,
          rollback: rollback,
          newHash: newHash,
        );
        final stat = await source.stat();
        final commit = TxtEditCommit(
          contentHash: newHash,
          modifiedAt: stat.modified,
          textEncoding: textEncoding,
          mapping: mapping,
          invalidateAllReferences: invalidateAllReferences,
        );
        await onCommitted?.call(commit);
        try {
          await _committedCleanup(rollback, journal);
        } catch (error) {
          // Metadata already names the new hash. Keep the rollback and journal
          // so startup recovery can finish cleanup; never restore old bytes
          // after the database commit has succeeded.
          debugPrint('TXT committed cleanup deferred: $error');
        }
        return commit;
      } catch (error) {
        if (await source.exists()) await source.delete();
        if (await rollback.exists()) await rollback.rename(source.path);
        if (await journal.exists()) await journal.delete();
        rethrow;
      }
    } catch (error) {
      if (await temporary.exists()) await temporary.delete();
      if (await rollback.exists()) {
        if (await source.exists()) await source.delete();
        await rollback.rename(source.path);
      }
      if (await journal.exists()) await journal.delete();
      if (error is TxtEditFailure) rethrow;
      throw TxtEditFailure('save_failed', error);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _verifySourceHash(File source, String expectedHash) async {
    if (!await source.exists()) {
      throw const TxtEditFailure('source_changed');
    }
    final currentHash = (await sha256.bind(source.openRead()).first).toString();
    if (currentHash != expectedHash) {
      throw const TxtEditFailure('source_changed');
    }
  }

  /// Repairs a process-killed edit before the file is read again.
  Future<void> recoverInterruptedEdit(Book book) async {
    final source = File(book.filePath);
    final journal = _journalFile(source);
    if (!await journal.exists()) return;
    try {
      final values = jsonDecode(await journal.readAsString()) as Map;
      final phase = values['phase'] as String? ?? 'prepared';
      final temporary = File(values['temporary'] as String);
      final rollback = File(values['rollback'] as String);
      final newHash = values['newHash'] as String?;
      if (phase == 'swapped' &&
          await source.exists() &&
          await rollback.exists() &&
          newHash != null &&
          book.contentHash == newHash) {
        await rollback.delete();
      } else if (await rollback.exists()) {
        if (await source.exists()) await source.delete();
        await rollback.rename(source.path);
      }
      if (await temporary.exists()) await temporary.delete();
      await journal.delete();
    } catch (error) {
      throw TxtEditFailure('recovery_failed', error);
    }
  }

  File _journalFile(File source) =>
      File('${source.path}.openreading-edit-journal.json');

  Future<void> _writeJournal(
    File journal, {
    required String phase,
    required File source,
    required File temporary,
    required File rollback,
    required String? newHash,
  }) => journal.writeAsString(
    jsonEncode(<String, Object?>{
      'phase': phase,
      'source': source.path,
      'temporary': temporary.path,
      'rollback': rollback.path,
      'newHash': newHash,
    }),
    flush: true,
  );

  static Future<void> _defaultCommittedCleanup(
    File rollback,
    File journal,
  ) async {
    if (await rollback.exists()) await rollback.delete();
    if (await journal.exists()) await journal.delete();
  }

  Future<void> _writeHistory(Book book, File source, String contentHash) async {
    final directory = await _historyDirectory(book);
    await directory.create(recursive: true);
    final id =
        '${DateTime.now().microsecondsSinceEpoch}_${contentHash.substring(0, 12)}';
    final snapshot = File(path.join(directory.path, '$id.txt'));
    if (!await snapshot.exists()) {
      await source.copy(snapshot.path);
      await File('${snapshot.path}.json').writeAsString(
        jsonEncode(<String, Object?>{
          'textEncoding': book.textEncoding ?? 'auto',
        }),
        flush: true,
      );
    }
  }

  Future<void> _writeUtf8Splice({
    required File source,
    required File temporary,
    required int startByte,
    required int endByte,
    required Uint8List insertedBytes,
  }) async {
    final input = await source.open();
    final output = await temporary.open(mode: FileMode.write);
    try {
      await _copyByteRange(input, output, 0, startByte);
      await output.writeFrom(insertedBytes);
      final length = await input.length();
      await _copyByteRange(input, output, endByte, length);
      await output.flush();
    } finally {
      await input.close();
      await output.close();
    }
  }

  Future<void> _copyByteRange(
    RandomAccessFile input,
    RandomAccessFile output,
    int start,
    int end,
  ) async {
    await input.setPosition(start);
    var remaining = end - start;
    while (remaining > 0) {
      final bytes = await input.read(remaining.clamp(0, 64 * 1024));
      if (bytes.isEmpty) throw const TxtEditFailure('source_changed');
      await output.writeFrom(bytes);
      remaining -= bytes.length;
    }
  }

  Future<Directory> _historyDirectory(Book book) async {
    final root = await _historyRootProvider();
    final key = book.id == null
        ? sha1.convert(utf8.encode(book.filePath)).toString()
        : 'book-${book.id}';
    return Directory(path.join(root.path, key));
  }
}

class _PreparedTxtSource {
  const _PreparedTxtSource({
    required this.workDirectory,
    required this.dataFile,
    required this.contentHash,
    required this.requiresConversion,
    required this.hasUtf8Bom,
    required this.predominantNewline,
    required this.sections,
  });

  factory _PreparedTxtSource.fromMap(
    Map<String, dynamic> values, {
    required Directory workDirectory,
    required File dataFile,
  }) {
    final rawSections = values['chapters']! as List;
    return _PreparedTxtSource(
      workDirectory: workDirectory,
      dataFile: dataFile,
      contentHash: values['contentHash']! as String,
      requiresConversion: values['requiresUtf8Conversion']! as bool,
      hasUtf8Bom: values['hasUtf8Bom']! as bool,
      predominantNewline: values['predominantNewline']! as String,
      sections: rawSections
          .map(
            (raw) => _IndexedTxtSection.fromMap(
              Map<String, dynamic>.from(raw as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final Directory workDirectory;
  final File dataFile;
  final String contentHash;
  final bool requiresConversion;
  final bool hasUtf8Bom;
  final String predominantNewline;
  final List<_IndexedTxtSection> sections;

  _IndexedTxtSection? section(String id) =>
      sections.where((section) => section.id == id).firstOrNull;

  Future<void> dispose() async {
    if (await workDirectory.exists()) {
      await workDirectory.delete(recursive: true);
    }
  }
}

class _IndexedTxtSection {
  const _IndexedTxtSection({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.sourceChapterId,
    required this.sourceBodyStart,
  });

  factory _IndexedTxtSection.fromMap(Map<String, dynamic> values) =>
      _IndexedTxtSection(
        id: values['id']! as String,
        title: values['title']! as String,
        start: values['start']! as int,
        end: values['end']! as int,
        sourceChapterId: values['sourceChapterId'] as String?,
        sourceBodyStart: values['sourceBodyStart']! as int,
      );

  final String id;
  final String title;
  final int start;
  final int end;
  final String? sourceChapterId;
  final int sourceBodyStart;
}

String _normalizeInsertedNewlines(String text, String newline) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', newline);

TxtEditRevisionMapping _revisionMapping(
  String chapterId,
  String before,
  String after, {
  List<String> invalidatedChapterIds = const <String>[],
}) {
  var prefix = 0;
  final prefixLimit = before.length < after.length
      ? before.length
      : after.length;
  while (prefix < prefixLimit &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  final suffixLimit = prefixLimit - prefix;
  while (suffix < suffixLimit &&
      before.codeUnitAt(before.length - suffix - 1) ==
          after.codeUnitAt(after.length - suffix - 1)) {
    suffix++;
  }
  return TxtEditRevisionMapping(
    chapterId: chapterId,
    oldLength: before.length,
    oldText: before,
    newText: after,
    commonPrefixLength: prefix,
    commonSuffixLength: suffix,
    invalidatedChapterIds: invalidatedChapterIds,
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
