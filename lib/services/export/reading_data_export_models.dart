import 'dart:typed_data';

import 'package:xxread/models/book.dart';
import 'package:xxread/models/book_note.dart';

typedef ReadingDataExportClock = DateTime Function();
typedef ReadingDataOverwriteConfirmation = Future<bool> Function(String path);

enum ReadingDataExportStatus { success, cancelled, unsupported, failure }

class ReadingDataExportCounts {
  const ReadingDataExportCounts({
    required this.total,
    required this.highlights,
    required this.underlines,
    required this.notes,
  });

  final int total;
  final int highlights;
  final int underlines;
  final int notes;
}

class ReadingDataExportLabels {
  const ReadingDataExportLabels({
    this.author = 'Author',
    this.wholeBook = 'Whole book',
    this.contents = 'Contents',
    this.exportedAt = 'Exported',
    this.myNote = 'My note',
    this.highlight = 'Highlight',
    this.underline = 'Underline',
    this.note = 'Note',
    this.unknownChapter = 'Unlocated annotations',
    this.pageLabel = _defaultPageLabel,
  });

  final String author;
  final String wholeBook;
  final String contents;
  final String exportedAt;
  final String myNote;
  final String highlight;
  final String underline;
  final String note;
  final String unknownChapter;
  final String Function(int page) pageLabel;

  static String _defaultPageLabel(int page) => 'Page $page';
}

class PreparedReadingDataExport {
  const PreparedReadingDataExport({
    required this.book,
    required this.annotations,
    required this.counts,
    required this.labels,
    required this.preparedAt,
  });

  final Book book;
  final List<BookNote> annotations;
  final ReadingDataExportCounts counts;
  final ReadingDataExportLabels labels;
  final DateTime preparedAt;
}

class ReadingDataExportDocument {
  const ReadingDataExportDocument({
    required this.prepared,
    required this.fileName,
    required this.markdown,
  });

  final PreparedReadingDataExport prepared;
  final String fileName;
  final String markdown;
  ReadingDataExportCounts get counts => prepared.counts;
  ReadingDataExportLabels get labels => prepared.labels;
  String get suggestedFileName => fileName;
  int get totalCount => counts.total;
  int get highlightCount => counts.highlights;
  int get underlineCount => counts.underlines;
  int get noteCount => counts.notes;
}

class ReadingDataExportRequest {
  ReadingDataExportRequest({
    required this.bytes,
    required this.suggestedName,
    this.mimeType = 'text/markdown',
  });

  final Uint8List bytes;
  final String suggestedName;
  final String mimeType;
}

class ReadingDataExportBackendResult {
  const ReadingDataExportBackendResult._(
    this.status, {
    this.displayName,
    this.location,
    this.uri,
    this.error,
  });

  const ReadingDataExportBackendResult.success({
    required String displayName,
    String? location,
    String? uri,
  }) : this._(
         ReadingDataExportStatus.success,
         displayName: displayName,
         location: location,
         uri: uri,
       );
  const ReadingDataExportBackendResult.cancelled()
    : this._(ReadingDataExportStatus.cancelled);
  const ReadingDataExportBackendResult.unsupported()
    : this._(ReadingDataExportStatus.unsupported);
  const ReadingDataExportBackendResult.failure([Object? error])
    : this._(ReadingDataExportStatus.failure, error: error);

  final ReadingDataExportStatus status;
  final String? displayName;
  final String? location;
  final String? uri;
  final Object? error;
}

class ReadingDataExportResult {
  const ReadingDataExportResult._(
    this.status, {
    this.displayName,
    this.location,
    this.uri,
    this.error,
  });

  const ReadingDataExportResult.success({
    required String displayName,
    String? location,
    String? uri,
  }) : this._(
         ReadingDataExportStatus.success,
         displayName: displayName,
         location: location,
         uri: uri,
       );
  const ReadingDataExportResult.cancelled()
    : this._(ReadingDataExportStatus.cancelled);
  const ReadingDataExportResult.unsupported()
    : this._(ReadingDataExportStatus.unsupported);
  const ReadingDataExportResult.failure([Object? error])
    : this._(ReadingDataExportStatus.failure, error: error);

  final ReadingDataExportStatus status;
  final String? displayName;
  final String? location;
  final String? uri;
  final Object? error;
  bool get isSuccess => status == ReadingDataExportStatus.success;
}

abstract interface class ReadingDataExportBackend {
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  );
}
