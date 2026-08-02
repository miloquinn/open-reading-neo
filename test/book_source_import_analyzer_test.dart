import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';

Uint8List _bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('detects an ORSP discovery document', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes({
        'protocol': 'open-reading-source',
        'protocolVersion': '1.5',
        'id': 'org.example.books',
        'name': 'Example Books',
        'description': '',
        'apiBaseUrl': 'https://example.org/api/',
        'languages': ['en'],
        'capabilities': ['search', 'detail', 'catalog', 'content'],
      }),
      documentUri: Uri.parse('https://example.org/source.json'),
    );

    expect(result.kind, BookSourceImportKind.orsp);
    expect(result.sources.single.sourceProtocol, BookSourceProtocolKind.orsp);
    expect(result.sources.single.enabled, isTrue);
  });

  test('detects aggregate compatible JSON without live probing', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes([
        {
          'bookSourceName': 'Compatible source',
          'bookSourceUrl': 'https://books.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content'},
        },
      ]),
    );

    expect(result.kind, BookSourceImportKind.additional);
    expect(result.sources, isEmpty);
    expect(result.additionalPreview?.sources, hasLength(1));
    final imported = result.additionalPreview!.toRegisteredSources();
    expect(imported.single.enabled, isTrue);
    expect(imported.single.capabilities, contains('search'));
  });

  test('imports advanced sources optimistically without live probing', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes([
        {
          'bookSourceName': 'Script source',
          'bookSourceUrl': 'https://script.example',
          'searchUrl': '@js:source.search()',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content'},
        },
      ]),
    );

    final imported = result.additionalPreview!.toRegisteredSources();
    expect(imported, hasLength(1));
    expect(imported.single.enabled, isTrue);
    expect(
      imported.single.capabilities,
      containsAll(['search', 'catalog', 'content']),
    );
    expect(
      imported.single.sourceConfig?['_openReadingCompatibilityLevel'],
      'supported',
    );
  });

  test('deduplicates by source URL and reports skipped entries', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes([
        {'bookSourceName': 'Old name', 'bookSourceUrl': 'https://same.example'},
        {'bookSourceName': 'New name', 'bookSourceUrl': 'https://same.example'},
        {'bookSourceName': 'Missing URL'},
      ]),
    );

    final preview = result.additionalPreview!;
    expect(preview.sources.single.name, 'New name');
    expect(preview.duplicates, 1);
    expect(preview.errors, hasLength(1));
    expect(preview.skipped, 2);
  });

  test('accepts realistic aggregate files larger than the old 4 MiB limit', () {
    expect(SourceImportService.maxImportBytes, 64 * 1024 * 1024);
    expect(SourceImportService.maxImportBytes, greaterThan(25 * 1024 * 1024));
  });

  test('parses aggregate bytes off the UI isolate', () async {
    final result = await BookSourceImportAnalyzer().analyzeBytesAsync(
      _bytes([
        {
          'bookSourceName': 'Background source',
          'bookSourceUrl': 'https://background.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content'},
        },
      ]),
    );

    expect(result.additionalPreview?.sources.single.name, 'Background source');
  });
}
