import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_export_service.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';

void main() {
  test('exports compatible sources in reusable community JSON form', () async {
    final backend = _RecordingBackend();
    final service = BookSourceExportService(
      backend: backend,
      clock: () => DateTime(2026, 9, 16, 8, 7, 6),
    );
    final source = _readingSource().copyWith(
      enabled: false,
      groups: ['Fiction', 'Favorites'],
    );

    final result = await service.export([source]);

    expect(result.status, BookSourceExportStatus.success);
    expect(
      backend.request!.suggestedName,
      'open-reading-book-sources-20260916-080706.json',
    );
    expect(backend.request!.mimeType, 'application/json');
    final decoded = jsonDecode(utf8.decode(backend.request!.bytes)) as List;
    expect(decoded, hasLength(1));
    expect(decoded.single['bookSourceName'], 'Community source');
    expect(decoded.single['enabled'], isFalse);
    expect(decoded.single['bookSourceGroup'], 'Fiction,Favorites');
    expect(decoded.single, isNot(contains('_openReadingCompatibilityLevel')));
  });

  test('retains complete ORSP registration data in the JSON export', () {
    final service = BookSourceExportService(
      backend: _RecordingBackend(),
      clock: () => DateTime.utc(2026, 9, 16),
    );
    final source = _orspSource();

    final document = service.prepare([source]);
    final decoded = jsonDecode(document.json) as List;

    expect(document.sourceCount, 1);
    expect(decoded.single['id'], source.id);
    expect(decoded.single['sourceProtocol'], 'orsp');
    expect(decoded.single['manifestUrl'], source.manifestUrl.toString());
  });

  test('empty selection is rejected before opening the save dialog', () async {
    final backend = _RecordingBackend();
    final service = BookSourceExportService(backend: backend);

    final result = await service.export(const []);

    expect(result.status, BookSourceExportStatus.failure);
    expect(backend.request, isNull);
  });
}

class _RecordingBackend implements ReadingDataExportBackend {
  ReadingDataExportRequest? request;

  @override
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  ) async {
    this.request = request;
    return ReadingDataExportBackendResult.success(
      displayName: request.suggestedName,
      location: '/tmp/${request.suggestedName}',
    );
  }
}

RegisteredBookSource _readingSource() => RegisteredBookSource(
  id: 'source.community',
  name: 'Community source',
  description: '',
  manifestUrl: Uri.parse('https://books.example'),
  apiBaseUrl: Uri.parse('https://books.example'),
  protocolVersion: 'reading-source-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026, 9, 1),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: const {
    'bookSourceName': 'Community source',
    'bookSourceUrl': 'https://books.example',
    'enabled': true,
    '_openReadingCompatibilityLevel': 'supported',
  },
);

RegisteredBookSource _orspSource() => RegisteredBookSource(
  id: 'org.example.source',
  name: 'ORSP source',
  description: '',
  manifestUrl: Uri.parse('https://example.org/.well-known/open-reading.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.5',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026, 9, 1),
);
