import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/caching/book_source_response_cache.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/protocol/orsp/orsp_http_pipeline.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('orsp-http-validators-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'sends cached validators and treats 304 as a freshness update',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final adapter = _SequenceAdapter([
        _Reply(
          HttpStatus.ok,
          '{"items":[]}',
          headers: {
            HttpHeaders.etagHeader: ['"catalog-v1"'],
            HttpHeaders.lastModifiedHeader: ['Wed, 01 Jan 2025 00:00:00 GMT'],
          },
        ),
        const _Reply(HttpStatus.notModified, ''),
      ]);
      final cache = BookSourceResponseCache(
        cacheDirectory: directory,
        now: () => now,
      );
      addTearDown(cache.flushPendingWrites);
      final pipeline = _pipeline(adapter, cache);

      expect(await _read(pipeline), {'items': []});
      now = now.add(const Duration(minutes: 2));
      expect(await _read(pipeline), {'items': []});

      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.last.headers[HttpHeaders.ifNoneMatchHeader],
        '"catalog-v1"',
      );
      expect(
        adapter.requests.last.headers[HttpHeaders.ifModifiedSinceHeader],
        'Wed, 01 Jan 2025 00:00:00 GMT',
      );

      now = now.add(const Duration(seconds: 30));
      expect(await _read(pipeline), {'items': []});
      expect(adapter.requests, hasLength(2));
    },
  );

  test('uses bounded stale data for transient HTTP failures', () async {
    var now = DateTime.utc(2026, 1, 1);
    final adapter = _SequenceAdapter([
      const _Reply(HttpStatus.ok, '{"items":[1]}'),
      const _Reply(HttpStatus.internalServerError, '{"error":{}}'),
    ]);
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    addTearDown(cache.flushPendingWrites);
    final pipeline = _pipeline(adapter, cache);

    expect(await _read(pipeline), {
      'items': [1],
    });
    now = now.add(const Duration(minutes: 2));
    expect(await _read(pipeline), {
      'items': [1],
    });
  });

  test('does not hide invalid replacement JSON behind stale data', () async {
    var now = DateTime.utc(2026, 1, 1);
    final adapter = _SequenceAdapter([
      const _Reply(HttpStatus.ok, '{"items":[]}'),
      const _Reply(HttpStatus.ok, '{broken'),
    ]);
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    addTearDown(cache.flushPendingWrites);
    final pipeline = _pipeline(adapter, cache);

    await _read(pipeline);
    now = now.add(const Duration(minutes: 2));
    await expectLater(_read(pipeline), throwsA(isA<DioException>()));
  });
}

Future<Map<String, dynamic>> _read(OrspHttpPipeline pipeline) =>
    pipeline.cachedJson(
      key: 'categories',
      ttl: const Duration(minutes: 1),
      uri: Uri.parse('https://example.org/api/v1/categories'),
      validate: (json) {
        if (json['items'] is! List) {
          throw const BookSourceProtocolException('items must be a list');
        }
        return json;
      },
    );

OrspHttpPipeline _pipeline(
  HttpClientAdapter adapter,
  BookSourceResponseCache cache,
) {
  final dio = Dio()..httpClientAdapter = adapter;
  return OrspHttpPipeline(
    dio,
    BookSourceNetworkPolicy(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    ),
    cache,
    systemDio: dio,
  );
}

class _Reply {
  const _Reply(this.status, this.body, {this.headers = const {}});

  final int status;
  final String body;
  final Map<String, List<String>> headers;
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.replies);

  final List<_Reply> replies;
  final List<RequestOptions> requests = [];
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = replies[_index++];
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        ...reply.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
