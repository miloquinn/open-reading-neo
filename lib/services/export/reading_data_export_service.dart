import 'dart:convert';
import 'dart:typed_data';

import 'package:xxread/models/book.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/services/export/reading_data_export_backend.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';
import 'package:xxread/services/export/reading_data_export_renderer.dart';
import 'package:xxread/services/export/reading_data_export_repository.dart';

class ReadingDataExportService {
  ReadingDataExportService({
    ReadingDataExportRepository? repository,
    ReadingDataExportBackend? backend,
    ReadingDataMarkdownRenderer? renderer,
    ReadingDataExportClock? clock,
    ReadingDataOverwriteConfirmation? overwriteConfirmation,
  }) : _repository = repository ?? BookNoteReadingDataExportRepository(),
       _backend =
           backend ??
           createDefaultReadingDataExportBackend(
             overwriteConfirmation: overwriteConfirmation,
           ),
       _renderer = renderer ?? const ReadingDataMarkdownRenderer(),
       _clock = clock ?? DateTime.now;

  final ReadingDataExportRepository _repository;
  final ReadingDataExportBackend _backend;
  final ReadingDataMarkdownRenderer _renderer;
  final ReadingDataExportClock _clock;

  Future<PreparedReadingDataExport> prepare(
    Book book, {
    ReadingDataExportLabels labels = const ReadingDataExportLabels(),
  }) async {
    final bookId = book.id;
    if (bookId == null) throw StateError('The book must have a local id');
    final rows = await _repository.annotationsForBook(bookId);
    final seenAnnotationIds = <String>{};
    final notes = <BookNote>[];
    for (final row in rows) {
      if (row.type != 'highlight' &&
          row.type != 'underline' &&
          row.type != 'note') {
        continue;
      }
      final annotationId = row.annotationId.trim();
      if (annotationId.isNotEmpty && !seenAnnotationIds.add(annotationId)) {
        continue;
      }
      notes.add(row);
    }
    notes.sort(_compareNotes);
    return PreparedReadingDataExport(
      book: book,
      annotations: List.unmodifiable(notes),
      counts: ReadingDataExportCounts(
        total: notes.length,
        highlights: notes.where((note) => note.type == 'highlight').length,
        underlines: notes.where((note) => note.type == 'underline').length,
        notes: notes.where((note) => note.type == 'note').length,
      ),
      labels: labels,
      preparedAt: _clock(),
    );
  }

  ReadingDataExportDocument render(PreparedReadingDataExport prepared) {
    return ReadingDataExportDocument(
      prepared: prepared,
      fileName: safeReadingDataExportFileName(prepared.book.title),
      markdown: _renderer.render(prepared),
    );
  }

  Future<ReadingDataExportDocument> prepareDocument(
    Book book, {
    ReadingDataExportLabels labels = const ReadingDataExportLabels(),
  }) async => render(await prepare(book, labels: labels));

  Future<ReadingDataExportResult> export(
    Object source, {
    ReadingDataExportLabels labels = const ReadingDataExportLabels(),
  }) async {
    try {
      final document = switch (source) {
        ReadingDataExportDocument document => document,
        Book book => await prepareDocument(book, labels: labels),
        _ => throw ArgumentError.value(source, 'source'),
      };
      final result = await _backend.export(
        ReadingDataExportRequest(
          bytes: Uint8List.fromList(utf8.encode(document.markdown)),
          suggestedName: document.fileName,
        ),
      );
      return switch (result.status) {
        ReadingDataExportStatus.success => ReadingDataExportResult.success(
          displayName: result.displayName ?? document.fileName,
          location: result.location,
          uri: result.uri,
        ),
        ReadingDataExportStatus.cancelled =>
          const ReadingDataExportResult.cancelled(),
        ReadingDataExportStatus.unsupported =>
          const ReadingDataExportResult.unsupported(),
        ReadingDataExportStatus.failure => ReadingDataExportResult.failure(
          result.error,
        ),
      };
    } catch (error) {
      return ReadingDataExportResult.failure(error);
    }
  }
}

int _compareNotes(BookNote left, BookNote right) {
  int compare(Comparable? a, Comparable? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  return compare(left.pageNumber, right.pageNumber) != 0
      ? compare(left.pageNumber, right.pageNumber)
      : compare(left.chapter, right.chapter) != 0
      ? compare(left.chapter, right.chapter)
      : compare(left.startOffset, right.startOffset) != 0
      ? compare(left.startOffset, right.startOffset)
      : compare(left.createTime, right.createTime) != 0
      ? compare(left.createTime, right.createTime)
      : compare(left.id, right.id) != 0
      ? compare(left.id, right.id)
      : left.annotationId.compareTo(right.annotationId);
}

String safeReadingDataExportFileName(String title) {
  var value = title
      .replaceAll(RegExp(r'[\u202A-\u202E\u2066-\u2069]'), '')
      .replaceAll(RegExp(r'[\u2215\u2044]'), '-')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (value.isEmpty || value == '.' || value == '..') value = 'reading-notes';
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(value.toUpperCase())) value = '_$value';
  final runes = value.runes.toList();
  if (runes.length > 120) value = String.fromCharCodes(runes.take(120));
  return '$value.md';
}
