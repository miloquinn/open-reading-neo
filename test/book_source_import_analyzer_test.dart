import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
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

  test('import preview separates runnable books, comics, and fragments', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes([
        {
          'bookSourceName': 'Novel',
          'bookSourceUrl': 'https://novel.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content@text'},
        },
        {
          'bookSourceName': 'Legacy comic',
          'bookSourceGroup': '漫画',
          'bookSourceType': 0,
          'bookSourceUrl': 'https://comic.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': 'img@data-src', 'imageStyle': 'FULL'},
        },
        {
          'bookSourceName': 'Preference fragment',
          'bookSourceUrl': 'https://fragment.example',
        },
      ]),
    );

    final preview = result.additionalPreview!;
    expect(preview.runnableTextSources, 1);
    expect(preview.runnableImageSources, 1);
    expect(preview.unsupported, 1);
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

  test('standard dedupe normalizes URLs and preserves explicit selection', () {
    final result = BookSourceImportAnalyzer().analyzeBytes(
      _bytes([
        {
          'bookSourceName': 'Canonical old',
          'bookSourceUrl': 'https://EXAMPLE.com:443/?b=2&utm_source=list&a=1',
        },
        {
          'bookSourceName': 'Canonical new',
          'bookSourceUrl': 'https://example.com?a=1&b=2',
        },
      ]),
    );

    final preview = result.additionalPreview!;
    expect(preview.dedupeResult.groups, hasLength(1));
    expect(preview.sources.single.name, 'Canonical new');
    final exact = preview.withMode(BookSourceDedupeMode.exact);
    expect(exact.sources, hasLength(2));
    final manuallySelected = preview.withSelectedIndices({0});
    expect(manuallySelected.sources.single.name, 'Canonical old');
    expect(identical(preview.withMode(preview.mode), preview), isTrue);
    expect(
      identical(
        manuallySelected.withSelectedIndices(manuallySelected.selectedIndices),
        manuallySelected,
      ),
      isTrue,
    );
  });

  test(
    'byte decoding accepts BOM and Unicode while rejecting malformed input',
    () async {
      final service = SourceImportService();
      final analyzer = BookSourceImportAnalyzer();
      addTearDown(service.close);
      addTearDown(analyzer.close);
      final bytes = Uint8List.fromList(
        utf8.encode(
          '\ufeff${jsonEncode({'bookSourceName': '书源 📚', 'bookSourceUrl': 'https://unicode.example'})}',
        ),
      );
      expect(service.parseBytes(bytes).sources.single.name, '书源 📚');
      expect(
        (await service.parseBytesAsync(bytes)).sources.single.name,
        '书源 📚',
      );
      expect(
        (await analyzer.analyzeBytesAsync(
          bytes,
        )).additionalPreview!.sources.single.name,
        '书源 📚',
      );
      for (final invalid in [
        Uint8List.fromList([0xff]),
        Uint8List.fromList(utf8.encode('{invalid')),
        Uint8List(0),
      ]) {
        expect(() => service.parseBytes(invalid), throwsFormatException);
        await expectLater(
          service.parseBytesAsync(invalid),
          throwsFormatException,
        );
        await expectLater(
          analyzer.analyzeBytesAsync(invalid),
          throwsFormatException,
        );
      }
    },
  );

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

  test(
    'reuses the root URL response when importing a nested source list',
    () async {
      final root = _bytes({
        'sourceUrls': ['https://nested.example/sources.json'],
      });
      final nested = _bytes([
        {
          'bookSourceName': 'Nested source',
          'bookSourceUrl': 'https://books.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content'},
        },
      ]);
      final adapter = _ImportAdapter({
        'https://sources.example/list.json': root,
        'https://nested.example/sources.json': nested,
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final service = SourceImportService(
        dio: dio,
        systemDio: dio,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      final analyzer = BookSourceImportAnalyzer(additionalImporter: service);
      final downloadPhases = <String>[];

      final result = await analyzer.analyzeUrl(
        'https://sources.example/list.json',
        onDownloadStarted: () => downloadPhases.add('downloading'),
        onDownloadComplete: () => downloadPhases.add('analyzing'),
      );

      expect(downloadPhases, ['analyzing', 'downloading', 'analyzing']);
      expect(result.additionalPreview?.sources.single.name, 'Nested source');
      expect(adapter.requests, [
        'https://sources.example/list.json',
        'https://nested.example/sources.json',
      ]);
      service.close();
    },
  );

  test(
    'imports a compatible source list through the system client on synthetic DNS',
    () async {
      final compatibleSources = _bytes([
        {
          'bookSourceName': 'Compatible source',
          'bookSourceUrl': 'https://books.example',
          'searchUrl': '/search?q={{key}}',
          'ruleSearch': {'bookList': '.book'},
          'ruleToc': {'chapterList': '.chapter'},
          'ruleContent': {'content': '#content'},
        },
      ]);
      final pinned = _ImportAdapter({});
      final system = _ImportAdapter({
        'https://sources.example/list.json': compatibleSources,
      });
      final pinnedDio = Dio()..httpClientAdapter = pinned;
      final systemDio = Dio()..httpClientAdapter = system;
      final service = SourceImportService(
        dio: pinnedDio,
        systemDio: systemDio,
        networkPolicy: BookSourceNetworkPolicy(
          allowSyntheticDns: true,
          lookup: (_) async => [InternetAddress('198.18.1.90')],
        ),
      );

      final result = await BookSourceImportAnalyzer(
        additionalImporter: service,
      ).analyzeUrl('https://sources.example/list.json');

      expect(result.kind, BookSourceImportKind.additional);
      expect(
        result.additionalPreview?.sources.single.name,
        'Compatible source',
      );
      expect(pinned.requests, isEmpty);
      expect(system.requests, ['https://sources.example/list.json']);
      service.close();
    },
  );

  test('keeps successful nested sources when another URL fails', () async {
    final root = _bytes({
      'sourceUrls': [
        'https://nested.example/good.json',
        'https://nested.example/missing.json',
      ],
    });
    final adapter = _ImportAdapter({
      'https://sources.example/list.json': root,
      'https://nested.example/good.json': _bytes([
        {
          'bookSourceName': 'Nested source',
          'bookSourceUrl': 'https://nested-books.example',
        },
      ]),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final service = SourceImportService(
      dio: dio,
      systemDio: dio,
      networkPolicy: BookSourceNetworkPolicy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
    );

    final result = await BookSourceImportAnalyzer(
      additionalImporter: service,
    ).analyzeUrl('https://sources.example/list.json');

    expect(result.additionalPreview?.sources.single.name, 'Nested source');
    expect(result.additionalPreview?.errors, hasLength(1));
    expect(adapter.requests, [
      'https://sources.example/list.json',
      'https://nested.example/good.json',
      'https://nested.example/missing.json',
    ]);
    service.close();
  });

  test('does not probe ORSP after recognizing an empty aggregate', () async {
    final adapter = _ImportAdapter({
      'https://sources.example/list.json': _bytes({'sources': []}),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final service = SourceImportService(
      dio: dio,
      systemDio: dio,
      networkPolicy: BookSourceNetworkPolicy(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
    );
    var discoveryClients = 0;
    final analyzer = BookSourceImportAnalyzer(
      additionalImporter: service,
      discoveryClientFactory: () {
        discoveryClients++;
        return _DiscoveryClient();
      },
    );

    await expectLater(
      analyzer.analyzeUrl('https://sources.example/list.json'),
      throwsA(isA<FormatException>()),
    );

    expect(discoveryClients, 0);
    service.close();
  });

  testWidgets('URL import timeout cancels download without ORSP fallback', (
    tester,
  ) async {
    final service = _HangingImportService();
    addTearDown(service.close);
    var discoveryClients = 0;
    final analyzer = BookSourceImportAnalyzer(
      additionalImporter: service,
      discoveryClientFactory: () {
        discoveryClients++;
        return _DiscoveryClient();
      },
    );

    final expectation = expectLater(
      analyzer.analyzeUrl('https://sources.example/list.json'),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(seconds: 30));
    await expectation;

    expect(service.cancelCalls, 1);
    expect(discoveryClients, 0);
  });

  testWidgets('ORSP fallback timeout is preserved and closes discovery', (
    tester,
  ) async {
    final service = _ImmediateImportService(Uint8List.fromList([0xff]));
    final discovery = _HangingDiscoveryClient();
    final analyzer = _FallbackAnalyzer(
      service: service,
      discoveryClientFactory: () => discovery,
    );
    addTearDown(() {
      analyzer.close();
      service.close();
    });

    final expectation = expectLater(
      analyzer.analyzeUrl('https://sources.example/list.json'),
      throwsA(isA<TimeoutException>()),
    );
    for (var attempt = 0; attempt < 10 && !discovery.started; attempt++) {
      await tester.pump();
    }
    expect(discovery.started, isTrue);
    await tester.pump(const Duration(seconds: 30));
    await expectation;

    expect(service.cancelCalls, 1);
    expect(discovery.closeCalls, 1);
  });

  test('cancelling ORSP fallback closes it and reports cancellation', () async {
    final service = _ImmediateImportService(Uint8List.fromList([0xff]));
    final discovery = _HangingDiscoveryClient();
    final analyzer = _FallbackAnalyzer(
      service: service,
      discoveryClientFactory: () => discovery,
    );
    addTearDown(() {
      analyzer.close();
      service.close();
    });
    final pending = analyzer.analyzeUrl('https://sources.example/list.json');
    final expectation = expectLater(
      pending,
      throwsA(isA<SourceImportCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(discovery.started, isTrue);
    analyzer.cancel();
    await expectation;

    expect(service.cancelCalls, 1);
    expect(discovery.closeCalls, 1);
  });

  test('cancellation during DNS prevents queued nested requests', () async {
    final lookups = <String, Completer<List<InternetAddress>>>{};
    final adapter = _ImportAdapter({});
    final dio = Dio()..httpClientAdapter = adapter;
    final service = SourceImportService(
      dio: dio,
      systemDio: dio,
      networkPolicy: BookSourceNetworkPolicy(
        lookup: (host) {
          final completer = Completer<List<InternetAddress>>();
          lookups[host] = completer;
          return completer.future;
        },
      ),
    );
    addTearDown(service.close);
    final sourceUrls = List.generate(
      6,
      (index) => Uri.parse('https://nested-$index.example/sources.json'),
    );
    final pending = service.loadUrl(
      'https://sources.example/list.json',
      initialPreview: SourceImportPreview(
        sources: const [],
        errors: const [],
        sourceUrls: sourceUrls,
      ),
    );
    final expectation = expectLater(
      pending,
      throwsA(isA<SourceImportCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(lookups, hasLength(4));
    service.cancelActiveDownloads();
    for (final lookup in lookups.values) {
      lookup.complete([InternetAddress('93.184.216.34')]);
    }
    await expectation;

    expect(lookups, hasLength(4));
    expect(adapter.requests, isEmpty);
  });
}

class _DiscoveryClient extends BookSourceClient {
  @override
  Future<DiscoveredBookSource> discover(String input) =>
      throw StateError('Unexpected ORSP discovery.');
}

class _HangingDiscoveryClient extends BookSourceClient {
  final Completer<DiscoveredBookSource> _discovery = Completer();
  var started = false;
  var closeCalls = 0;

  @override
  Future<DiscoveredBookSource> discover(String input) {
    started = true;
    return _discovery.future;
  }

  @override
  void close({bool force = true}) {
    closeCalls++;
    if (!_discovery.isCompleted) {
      _discovery.completeError(StateError('Discovery cancelled.'));
    }
  }
}

class _FallbackAnalyzer extends BookSourceImportAnalyzer {
  _FallbackAnalyzer({
    required SourceImportService service,
    required BookSourceClient Function() discoveryClientFactory,
  }) : super(
         additionalImporter: service,
         discoveryClientFactory: discoveryClientFactory,
       );

  @override
  Future<BookSourceImportAnalysis> analyzeBytesAsync(
    Uint8List bytes, {
    Uri? documentUri,
  }) async {
    throw const FormatException('Invalid root document.');
  }
}

class _ImmediateImportService extends SourceImportService {
  _ImmediateImportService(this.bytes);

  final Uint8List bytes;
  var cancelCalls = 0;

  @override
  Future<Uint8List> downloadBytes(String input) async => bytes;

  @override
  void cancelActiveDownloads([String reason = 'Source import cancelled.']) {
    cancelCalls++;
    super.cancelActiveDownloads(reason);
  }
}

class _HangingImportService extends SourceImportService {
  final Completer<Uint8List> _download = Completer();
  var cancelCalls = 0;

  @override
  Future<Uint8List> downloadBytes(String input) => _download.future;

  @override
  void cancelActiveDownloads([String reason = 'Source import cancelled.']) {
    cancelCalls++;
    super.cancelActiveDownloads(reason);
  }
}

class _ImportAdapter implements HttpClientAdapter {
  _ImportAdapter(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    final bytes = responses[url];
    if (bytes == null) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException('Missing test response.'),
      );
    }
    return ResponseBody.fromBytes(bytes, HttpStatus.ok);
  }

  @override
  void close({bool force = false}) {}
}
