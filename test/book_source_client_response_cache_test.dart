import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_network_policy.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/services/book_source_response_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('source-client-cache-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'ORSP search hits cache, separates pages, and supports invalidation',
    () async {
      final adapter = _SearchAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final cache = BookSourceResponseCache(cacheDirectory: directory);
      final client = BookSourceClient(
        dio: dio,
        responseCache: cache,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      addTearDown(client.close);
      final source = _source(BookSourceProtocolKind.orsp);

      expect((await client.search(source, 'alpha')).page, 1);
      expect((await client.search(source, 'alpha')).page, 1);
      expect((await client.search(source, 'alpha', page: 2)).page, 2);
      expect(adapter.requestCount, 2);

      await client.invalidateResponseCache(source);
      expect((await client.search(source, 'alpha')).page, 1);
      expect(adapter.requestCount, 3);
      await cache.flushPendingWrites();
      expect(await cache.diskSizeBytes(), 0);
    },
  );

  test('cancellable ORSP searches opt out of shared in-flight work', () async {
    final cache = _RecordingResponseCache();
    final dio = Dio()..httpClientAdapter = _SearchAdapter();
    final client = BookSourceClient(
      dio: dio,
      responseCache: cache,
      networkPolicy: BookSourceNetworkPolicy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
    );
    addTearDown(client.close);

    await client.search(
      _source(BookSourceProtocolKind.orsp),
      'private query',
      cancellation: BookDownloadCancellation(),
    );

    expect(cache.deduplicateInFlightValues, [isFalse]);
    expect(cache.persistToDiskValues, [isFalse]);
  });

  test(
    'registry refresh invalidates a cached manifest before fetching',
    () async {
      final adapter = _ManifestSequenceAdapter(['Old name', 'New name']);
      final dio = Dio()..httpClientAdapter = adapter;
      final cache = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(cache.flushPendingWrites);
      final client = BookSourceClient(
        dio: dio,
        responseCache: cache,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      addTearDown(client.close);
      const manifestUrl = 'https://example.org/source.json';

      final original = await client.discover(manifestUrl);
      expect(original.manifest.name, 'Old name');
      expect((await client.discover(manifestUrl)).manifest.name, 'Old name');
      expect(adapter.requestCount, 1);

      final source = RegisteredBookSource.fromManifest(
        manifest: original.manifest,
        manifestUrl: original.manifestUrl,
      );
      final refreshed = await BookSourceRegistry().refresh(source, client);

      expect(refreshed.single.name, 'New name');
      expect(adapter.requestCount, 2);
    },
  );

  test(
    'reading-source execution never enters the ORSP response cache',
    () async {
      final cache = _RecordingResponseCache();
      final client = BookSourceClient(responseCache: cache);
      addTearDown(client.close);

      await expectLater(
        client.search(_source(BookSourceProtocolKind.readingSource), 'alpha'),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect(cache.loads, 0);

      await client.invalidateResponseCache(
        _source(BookSourceProtocolKind.readingSource),
      );
      expect(cache.invalidations, 0);
    },
  );
}

RegisteredBookSource _source(BookSourceProtocolKind protocol) {
  return RegisteredBookSource(
    id: 'source-id',
    name: 'Source',
    description: '',
    manifestUrl: Uri.parse('https://example.org/source.json'),
    apiBaseUrl: Uri.parse('https://example.org/api/'),
    protocolVersion: '1.5',
    languages: const ['en'],
    capabilities: const {'search', 'detail', 'catalog', 'content'},
    enabled: true,
    addedAt: DateTime.utc(2026, 8, 3),
    sourceProtocol: protocol,
    sourceConfig: protocol == BookSourceProtocolKind.readingSource
        ? const <String, dynamic>{}
        : null,
  );
}

class _SearchAdapter implements HttpClientAdapter {
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    final page = int.parse(options.uri.queryParameters['page']!);
    return ResponseBody.fromString(
      '{"items":[],"page":$page,"pageSize":20,"hasMore":false}',
      HttpStatus.ok,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ManifestSequenceAdapter implements HttpClientAdapter {
  _ManifestSequenceAdapter(this.names);

  final List<String> names;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final name = names[requestCount++];
    return ResponseBody.fromString(
      '{'
      '"protocol":"open-reading-source",'
      '"protocolVersion":"1.5",'
      '"id":"source-id",'
      '"name":"$name",'
      '"description":"",'
      '"apiBaseUrl":"https://example.org/api/",'
      '"languages":["en"],'
      '"capabilities":["search","detail","catalog","content"]'
      '}',
      HttpStatus.ok,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RecordingResponseCache extends BookSourceResponseCache {
  int loads = 0;
  int invalidations = 0;
  final List<bool> deduplicateInFlightValues = [];
  final List<bool> persistToDiskValues = [];

  @override
  Future<Map<String, dynamic>> getOrLoadJson({
    required String key,
    required Duration ttl,
    required Future<Map<String, dynamic>> Function() loader,
    bool forceRefresh = false,
    bool deduplicateInFlight = true,
    bool persistToDisk = true,
  }) {
    loads++;
    deduplicateInFlightValues.add(deduplicateInFlight);
    persistToDiskValues.add(persistToDisk);
    return loader();
  }

  @override
  Future<void> invalidatePrefix(String prefix) async {
    invalidations++;
  }
}
