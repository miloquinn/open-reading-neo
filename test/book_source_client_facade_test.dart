import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/protocol/orsp/orsp_book_source_backend.dart';
import 'package:xxread/book_sources/protocol/reading_source/reading_source_backend.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_client_resources.dart';

void main() {
  test(
    'routes only reading-source operations to the reading backend',
    () async {
      final orsp = _RecordingOrspBackend();
      final reading = _RecordingReadingBackend();
      final client = BookSourceClient.withResources(
        BookSourceClientResources.create(
          dio: Dio(),
          orspBackend: orsp,
          readingBackend: reading,
        ),
      );

      expect((await client.search(_source(), 'query')).page, 1);
      expect((await client.search(_source(reading: true), 'query')).page, 2);
      await client.getDiscovery(_source(reading: true));
      await client.invalidateResponseCache(_source(reading: true));

      expect(orsp.searchCalls, 1);
      expect(reading.searchCalls, 1);
      expect(orsp.discoveryCalls, 1);
      expect(orsp.invalidateCalls, 0);
    },
  );

  test('prefetch preserves virtual dispatch and swallows failures', () async {
    final client = _OverridingClient();

    await client.prefetchChapterContent(
      _source(),
      bookId: 'book',
      chapterId: 'chapter',
    );

    expect(client.contentCalls, 1);
  });
}

RegisteredBookSource _source({bool reading = false}) => RegisteredBookSource(
  id: reading ? 'reading' : 'orsp',
  name: 'Source',
  description: '',
  manifestUrl: Uri.parse('https://example.test/source.json'),
  apiBaseUrl: Uri.parse('https://example.test/api/'),
  protocolVersion: '1.0',
  languages: const [],
  capabilities: const {'search', 'discover'},
  enabled: true,
  addedAt: DateTime(2025),
  sourceProtocol: reading
      ? BookSourceProtocolKind.readingSource
      : BookSourceProtocolKind.orsp,
  sourceConfig: reading ? const {} : null,
);

class _RecordingOrspBackend implements OrspBookSourceBackendPort {
  int searchCalls = 0;
  int discoveryCalls = 0;
  int invalidateCalls = 0;

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    cancellation,
  }) async {
    searchCalls++;
    return const BookSourceSearchPage(
      items: [],
      page: 1,
      pageSize: 20,
      hasMore: false,
    );
  }

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source,
  ) async {
    discoveryCalls++;
    return const BookSourceDiscoveryPage(sections: []);
  }

  @override
  Future<void> invalidateResponseCache(RegisteredBookSource source) async {
    invalidateCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingReadingBackend implements ReadingSourceBackendPort {
  int searchCalls = 0;

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    cancellation,
  }) async {
    searchCalls++;
    return const BookSourceSearchPage(
      items: [],
      page: 2,
      pageSize: 20,
      hasMore: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OverridingClient extends BookSourceClient {
  int contentCalls = 0;

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    contentCalls++;
    throw StateError('expected');
  }
}
