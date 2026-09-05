import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';

void main() {
  test(
    'async materialization preserves selected source records and reports',
    () async {
      final preview = SourceImportPreview(
        sources: [
          _source('ignored', 'https://ignored.example'),
          _source('selected', 'https://selected.example'),
          _source(
            'opaque',
            'opaque-app-source',
            jsLib: 'const endpoint = "https://opaque.example/api";',
            searchUrl: '',
          ),
        ],
        errors: const [],
        selectedIndices: const {1, 2},
      );

      final synchronous = preview.toRegisteredSources();
      final asynchronous = await preview.toRegisteredSourcesAsync();

      expect(asynchronous.map((source) => source.name), ['selected', 'opaque']);
      expect(
        asynchronous.map((source) => source.id),
        synchronous.map((source) => source.id),
      );
      expect(
        asynchronous.map(_withoutAddedAt),
        synchronous.map(_withoutAddedAt),
      );
      expect(
        asynchronous.last.sourceConfig?['_openReadingCompatibilityLevel'],
        SourceCompatibilityLevel.unsupported.name,
      );
      expect(
        asynchronous.last.sourceConfig?['_openReadingCompatibilityIssues'],
        contains(SourceCompatibilityIssue.missingSearch.name),
      );
      expect(asynchronous.last.manifestUrl.host, 'opaque.example');
    },
  );

  test('reports stay aligned when selected sources share an id', () async {
    final preview = SourceImportPreview(
      sources: [
        _source('supported', 'https://same.example'),
        _source('unsupported', 'https://same.example', searchUrl: ''),
      ],
      errors: const [],
      selectedIndices: const {0, 1},
    );

    final materialized = await preview.toRegisteredSourcesAsync();

    expect(materialized.map((source) => source.name), [
      'supported',
      'unsupported',
    ]);
    expect(
      materialized.map(
        (source) => source.sourceConfig?['_openReadingCompatibilityLevel'],
      ),
      [
        SourceCompatibilityLevel.supported.name,
        SourceCompatibilityLevel.unsupported.name,
      ],
    );
  });
}

ReadingSourceConfig _source(
  String name,
  String url, {
  String jsLib = '',
  String searchUrl = 'https://search.example?q={{key}}',
}) {
  return ReadingSourceConfig.fromJson({
    'bookSourceName': name,
    'bookSourceUrl': url,
    'searchUrl': searchUrl,
    'jsLib': jsLib,
    'ruleSearch': {'bookList': '.book', 'name': '.name@text'},
    'ruleBookInfo': {'name': 'h1@text'},
    'ruleToc': {'chapterList': '.chapter', 'chapterName': 'a@text'},
    'ruleContent': {'content': '#content@html'},
  });
}

Map<String, dynamic> _withoutAddedAt(RegisteredBookSource source) {
  return Map<String, dynamic>.from(source.toJson())..remove('addedAt');
}
