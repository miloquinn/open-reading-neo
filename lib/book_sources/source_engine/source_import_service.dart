import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_source_network_policy.dart';
import 'source_config.dart';

class SourceImportPreview {
  SourceImportPreview({
    required this.sources,
    required this.errors,
    this.duplicates = 0,
  }) : _reports = Map.unmodifiable({
         for (final source in sources)
           source.stableId: const SourceCompatibilityScanner().scan(source),
       });

  final List<ReadingSourceConfig> sources;
  final List<String> errors;
  final int duplicates;
  final Map<String, SourceCompatibilityReport> _reports;

  int get supported => _count(SourceCompatibilityLevel.supported);
  int get partial => _count(SourceCompatibilityLevel.partial);
  int get unsupported => _count(SourceCompatibilityLevel.unsupported);
  int get skipped => errors.length + duplicates;

  int _count(SourceCompatibilityLevel level) =>
      _reports.values.where((report) => report.level == level).length;

  SourceCompatibilityReport reportFor(ReadingSourceConfig source) =>
      _reports[source.stableId]!;

  List<RegisteredBookSource> toRegisteredSources() => sources
      .map(
        (source) =>
            source.toRegisteredSource(compatibilityReport: reportFor(source)),
      )
      .toList(growable: false);

  /// Materializes a large import result away from the Flutter UI isolate.
  /// The preview already contains compatibility reports, so pass those across
  /// instead of scanning every source again during the commit tap.
  Future<List<RegisteredBookSource>> toRegisteredSourcesAsync() {
    final request = <String, Object?>{
      'sources': sources.map((source) => source.raw).toList(growable: false),
      'reports': <String, Map<String, Object?>>{
        for (final source in sources)
          source.stableId: {
            'level': reportFor(source).level.name,
            'issues': reportFor(
              source,
            ).issues.map((issue) => issue.name).toList(growable: false),
          },
      },
    };
    return compute(_materializeRegisteredSources, request).then(
      (maps) => maps.map(RegisteredBookSource.fromJson).toList(growable: false),
    );
  }
}

class SourceImportService {
  SourceImportService({
    Dio? dio,
    Dio? systemDio,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
  }) : _networkPolicy = networkPolicy,
       _dio =
           dio ??
           (Dio(
               BaseOptions(
                 connectTimeout: const Duration(seconds: 8),
                 receiveTimeout: const Duration(seconds: 20),
                 sendTimeout: const Duration(seconds: 8),
               ),
             )
             ..httpClientAdapter = IOHttpClientAdapter(
               createHttpClient: networkPolicy.createPinnedHttpClient,
             )),
       _systemDio =
           systemDio ??
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 8),
             ),
           );

  /// Large aggregate source lists commonly exceed 20 MiB. Keep a finite
  /// boundary for malformed or hostile responses without rejecting normal
  /// community-maintained collections.
  static const int maxImportBytes = 64 * 1024 * 1024;
  static const int maxSources = 10000;
  static const int maxNestedUrls = 50;
  static const int maxNestedDepth = 2;

  final Dio _dio;
  final Dio _systemDio;
  final BookSourceNetworkPolicy _networkPolicy;

  void close({bool force = true}) {
    _dio.close(force: force);
    if (!identical(_systemDio, _dio)) _systemDio.close(force: force);
  }

  Future<Uint8List> downloadBytes(String input) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Import URL must use HTTP or HTTPS.');
    }
    return _download(uri);
  }

  SourceImportPreview parseBytes(Uint8List bytes) {
    return _collect(_parseBytes(bytes));
  }

  Future<SourceImportPreview> parseBytesAsync(Uint8List bytes) async {
    return _collect(await compute(_parseSourceImportBytes, bytes));
  }

  SourceImportPreview parseDecoded(Object? decoded) {
    return _collect(
      parseReadingSourcePayload(
        decoded,
        maxSources: maxSources,
        maxNestedUrls: maxNestedUrls,
      ),
    );
  }

  SourceImportResult _parseBytes(Uint8List bytes) {
    return _parseSourceImportBytes(bytes);
  }

  Future<SourceImportResult> _parseBytesAsync(Uint8List bytes) {
    return compute(_parseSourceImportBytes, bytes);
  }

  static SourceImportResult _parseSourceImportBytes(Uint8List bytes) {
    if (bytes.length > maxImportBytes) {
      throw const FormatException('Source file exceeds the 64 MiB limit.');
    }
    late final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw FormatException(
        'Source JSON must be valid UTF-8: ${error.message}',
      );
    }
    return parseReadingSources(
      text,
      maxSources: maxSources,
      maxNestedUrls: maxNestedUrls,
    );
  }

  Future<SourceImportPreview> loadUrl(
    String input, {
    Uint8List? initialBytes,
  }) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Import URL must use HTTP or HTTPS.');
    }
    final visited = <String>{};
    final tree = await _loadRecursive(
      uri,
      depth: 0,
      visited: visited,
      initialBytes: initialBytes,
    );
    return SourceImportPreview(
      sources: List.unmodifiable(tree.sources.values),
      errors: List.unmodifiable(tree.errors),
    );
  }

  Future<_SourceImportTree> _loadRecursive(
    Uri uri, {
    required int depth,
    required Set<String> visited,
    Uint8List? initialBytes,
  }) async {
    if (depth > maxNestedDepth) {
      return _SourceImportTree(
        errors: ['$uri: nested import depth exceeds $maxNestedDepth.'],
      );
    }
    if (!visited.add(uri.toString())) return const _SourceImportTree();
    if (visited.length > maxNestedUrls + 1) {
      throw const FormatException('Too many nested source URLs.');
    }
    final bytes = initialBytes ?? await _download(uri);
    final parsed = await _parseBytesAsync(bytes);
    final byUrl = <String, ReadingSourceConfig>{
      for (final source in parsed.sources) source.url: source,
    };
    final errors = <String>[...parsed.errors.map((error) => '$uri: $error')];
    final nestedResults = await _mapWithConcurrency(
      parsed.sourceUrls,
      _maxNestedConcurrent,
      (nested) => _loadRecursive(nested, depth: depth + 1, visited: visited),
    );
    // Merge in declaration order to preserve the historical last-write-wins
    // behavior for duplicate URLs in nested source lists.
    for (final nested in nestedResults) {
      byUrl.addAll(nested.sources);
      errors.addAll(nested.errors);
    }
    if (byUrl.length > maxSources) {
      throw const FormatException('Too many sources in import.');
    }
    return _SourceImportTree(sources: byUrl, errors: errors);
  }

  Future<List<T>> _mapWithConcurrency<T>(
    List<Uri> values,
    int concurrency,
    Future<T> Function(Uri value) operation,
  ) async {
    if (values.isEmpty) return const [];
    final results = List<T?>.filled(values.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= values.length) return;
        results[index] = await operation(values[index]);
      }
    }

    await Future.wait(
      List.generate(values.length.clamp(1, concurrency), (_) => worker()),
    );
    return results.cast<T>();
  }

  Future<Uint8List> _download(Uri initial) async {
    var current = initial;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final resolvedAddresses = await _networkPolicy.resolve(current);
      // Mirrors SourceHttpTransport: virtual-DNS clients (Surge/Clash/etc.)
      // route the reserved 198.18.0.0/15 range through a local tunnel that
      // the pinned connection factory bypasses, turning valid responses into
      // HTTP 400. Use the system client for that explicitly allowed range.
      final client =
          resolvedAddresses.any(BookSourceNetworkPolicy.isSyntheticDnsAddress)
          ? _systemDio
          : _dio;
      final cancelToken = CancelToken();
      try {
        final response = await client.getUri<List<int>>(
          current,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (received > maxImportBytes || total > maxImportBytes) {
              cancelToken.cancel(
                'Source import exceeds $maxImportBytes bytes.',
              );
            }
          },
        );
        final status = response.statusCode ?? 0;
        if (status < 300) {
          final bytes = Uint8List.fromList(response.data ?? const []);
          if (bytes.length > maxImportBytes) {
            throw const FormatException('Source import exceeds 64 MiB.');
          }
          return bytes;
        }
        if (redirects == 5) {
          throw const BookSourceProtocolException(
            'Source import redirected too many times.',
          );
        }
        current = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.headers.value(HttpHeaders.locationHeader),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          throw const FormatException('Source import exceeds 64 MiB.');
        }
        rethrow;
      }
    }
    throw const BookSourceProtocolException('Source import failed.');
  }

  SourceImportPreview _collect(SourceImportResult result) {
    return SourceImportPreview(
      sources: result.sources,
      errors: result.errors,
      duplicates: result.duplicates,
    );
  }
}

const int _maxNestedConcurrent = 4;

class _SourceImportTree {
  const _SourceImportTree({this.sources = const {}, this.errors = const []});

  final Map<String, ReadingSourceConfig> sources;
  final List<String> errors;
}

List<Map<String, dynamic>> _materializeRegisteredSources(
  Map<String, Object?> request,
) {
  final rawSources = request['sources']! as List;
  final reports = request['reports']! as Map;
  return rawSources
      .map((raw) {
        final source = ReadingSourceConfig.fromJson(
          (raw as Map).map((key, value) => MapEntry('$key', value)),
        );
        final reportData = reports[source.stableId] as Map;
        final report = SourceCompatibilityReport(
          level: SourceCompatibilityLevel.values.byName(
            '${reportData['level']}',
          ),
          issues: (reportData['issues'] as List)
              .map((issue) => SourceCompatibilityIssue.values.byName('$issue'))
              .toSet(),
        );
        return source.toRegisteredSource(compatibilityReport: report).toJson();
      })
      .toList(growable: false);
}
