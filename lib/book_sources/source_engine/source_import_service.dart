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
}

class SourceImportService {
  SourceImportService({
    Dio? dio,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(),
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
             ));

  /// Large aggregate source lists commonly exceed 20 MiB. Keep a finite
  /// boundary for malformed or hostile responses without rejecting normal
  /// community-maintained collections.
  static const int maxImportBytes = 64 * 1024 * 1024;
  static const int maxSources = 10000;
  static const int maxNestedUrls = 50;
  static const int maxNestedDepth = 2;

  final Dio _dio;
  final BookSourceNetworkPolicy _networkPolicy;

  void close({bool force = true}) => _dio.close(force: force);

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

  Future<SourceImportPreview> loadUrl(String input) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Import URL must use HTTP or HTTPS.');
    }
    final byUrl = <String, ReadingSourceConfig>{};
    final errors = <String>[];
    final visited = <String>{};
    await _loadRecursive(
      uri,
      depth: 0,
      visited: visited,
      byUrl: byUrl,
      errors: errors,
    );
    return SourceImportPreview(
      sources: List.unmodifiable(byUrl.values),
      errors: List.unmodifiable(errors),
    );
  }

  Future<void> _loadRecursive(
    Uri uri, {
    required int depth,
    required Set<String> visited,
    required Map<String, ReadingSourceConfig> byUrl,
    required List<String> errors,
  }) async {
    if (depth > maxNestedDepth) {
      errors.add('$uri: nested import depth exceeds $maxNestedDepth.');
      return;
    }
    if (!visited.add(uri.toString())) return;
    if (visited.length > maxNestedUrls + 1) {
      throw const FormatException('Too many nested source URLs.');
    }
    final bytes = await _download(uri);
    final parsed = await _parseBytesAsync(bytes);
    for (final source in parsed.sources) {
      byUrl[source.url] = source;
      if (byUrl.length > maxSources) {
        throw const FormatException('Too many sources in import.');
      }
    }
    errors.addAll(parsed.errors.map((error) => '$uri: $error'));
    for (final nested in parsed.sourceUrls) {
      await _loadRecursive(
        nested,
        depth: depth + 1,
        visited: visited,
        byUrl: byUrl,
        errors: errors,
      );
    }
  }

  Future<Uint8List> _download(Uri initial) async {
    var current = initial;
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      final cancelToken = CancelToken();
      try {
        final response = await _dio.getUri<List<int>>(
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
