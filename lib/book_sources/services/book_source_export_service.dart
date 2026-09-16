import 'dart:convert';
import 'dart:typed_data';

import '../models/registered_book_source.dart';
import '../../services/export/reading_data_export_backend.dart';
import '../../services/export/reading_data_export_models.dart';

enum BookSourceExportStatus { success, cancelled, unsupported, failure }

class BookSourceExportDocument {
  const BookSourceExportDocument({
    required this.fileName,
    required this.json,
    required this.sourceCount,
  });

  final String fileName;
  final String json;
  final int sourceCount;
}

class BookSourceExportResult {
  const BookSourceExportResult._(
    this.status, {
    this.displayName,
    this.location,
    this.error,
  });

  const BookSourceExportResult.success({
    required String displayName,
    String? location,
  }) : this._(
         BookSourceExportStatus.success,
         displayName: displayName,
         location: location,
       );

  const BookSourceExportResult.cancelled()
    : this._(BookSourceExportStatus.cancelled);

  const BookSourceExportResult.unsupported()
    : this._(BookSourceExportStatus.unsupported);

  const BookSourceExportResult.failure([Object? error])
    : this._(BookSourceExportStatus.failure, error: error);

  final BookSourceExportStatus status;
  final String? displayName;
  final String? location;
  final Object? error;
}

class BookSourceExportService {
  BookSourceExportService({
    ReadingDataExportBackend? backend,
    ReadingDataExportClock? clock,
    ReadingDataOverwriteConfirmation? overwriteConfirmation,
  }) : _backend =
           backend ??
           createDefaultReadingDataExportBackend(
             overwriteConfirmation: overwriteConfirmation,
           ),
       _clock = clock ?? DateTime.now;

  final ReadingDataExportBackend _backend;
  final ReadingDataExportClock _clock;

  BookSourceExportDocument prepare(Iterable<RegisteredBookSource> sources) {
    final exported = sources.map(_exportSource).toList(growable: false);
    final now = _clock().toLocal();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return BookSourceExportDocument(
      fileName: 'open-reading-book-sources-$stamp.json',
      json: '${const JsonEncoder.withIndent('  ').convert(exported)}\n',
      sourceCount: exported.length,
    );
  }

  Future<BookSourceExportResult> export(
    Iterable<RegisteredBookSource> sources,
  ) async {
    try {
      final document = prepare(sources);
      if (document.sourceCount == 0) {
        return BookSourceExportResult.failure(
          StateError('No book sources were selected.'),
        );
      }
      final result = await _backend.export(
        ReadingDataExportRequest(
          bytes: Uint8List.fromList(utf8.encode(document.json)),
          suggestedName: document.fileName,
          mimeType: 'application/json',
        ),
      );
      return switch (result.status) {
        ReadingDataExportStatus.success => BookSourceExportResult.success(
          displayName: result.displayName ?? document.fileName,
          location: result.location ?? result.uri,
        ),
        ReadingDataExportStatus.cancelled =>
          const BookSourceExportResult.cancelled(),
        ReadingDataExportStatus.unsupported =>
          const BookSourceExportResult.unsupported(),
        ReadingDataExportStatus.failure => BookSourceExportResult.failure(
          result.error,
        ),
      };
    } on Object catch (error) {
      return BookSourceExportResult.failure(error);
    }
  }
}

Map<String, dynamic> _exportSource(RegisteredBookSource source) {
  if (source.sourceProtocol == BookSourceProtocolKind.readingSource &&
      source.sourceConfig != null) {
    final config = Map<String, dynamic>.from(source.sourceConfig!);
    config.removeWhere((key, _) => key.startsWith('_openReading'));
    config['enabled'] = source.enabled;
    if (source.groups.isEmpty) {
      config.remove('bookSourceGroup');
    } else {
      config['bookSourceGroup'] = source.groups.join(',');
    }
    return config;
  }
  return source.toJson();
}
