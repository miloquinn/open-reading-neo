import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../dedupe/book_source_dedupe_engine.dart';
import '../dedupe/book_source_dedupe_models.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../networking/book_source_network_policy.dart';
import 'source_config.dart';

class SourceImportCancelledException implements Exception {
  const SourceImportCancelledException([
    this.message = 'Source import cancelled.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class SourceImportPreview {
  factory SourceImportPreview({
    required List<ReadingSourceConfig> sources,
    required List<String> errors,
    List<Uri> sourceUrls = const [],
    BookSourceDedupeMode mode = BookSourceDedupeMode.standard,
    Set<int>? selectedIndices,
  }) {
    final analysis = _analyzeSources(sources, mode);
    return SourceImportPreview._(
      analysis.reports,
      analysis.candidates,
      candidates: List.unmodifiable(sources),
      errors: errors,
      sourceUrls: List.unmodifiable(sourceUrls),
      mode: mode,
      dedupeResult: analysis.result,
      selectedIndices: Set.unmodifiable(
        selectedIndices ?? analysis.result.defaultSelectedIndices,
      ),
    );
  }

  SourceImportPreview._(
    this._reports,
    this._dedupeCandidates, {
    required this.candidates,
    required this.errors,
    required this.sourceUrls,
    required this.mode,
    required this.dedupeResult,
    required this.selectedIndices,
  });

  final List<ReadingSourceConfig> candidates;
  final List<String> errors;
  final List<Uri> sourceUrls;
  final BookSourceDedupeMode mode;
  final BookSourceDedupeResult dedupeResult;
  final List<BookSourceDedupeCandidate> _dedupeCandidates;
  final Set<int> selectedIndices;
  final Map<int, SourceCompatibilityReport> _reports;

  late final List<int> _selectedIndexList = selectedIndices
      .where((index) => index >= 0 && index < candidates.length)
      .toList(growable: false);

  Iterable<(int, ReadingSourceConfig)> get _selectedEntries =>
      _selectedIndexList.map((index) => (index, candidates[index]));

  late final List<ReadingSourceConfig> sources = List.unmodifiable(
    _selectedIndexList.map((index) => candidates[index]),
  );
  late final int duplicates = candidates.length - sources.length;
  int get duplicateGroups => dedupeResult.groups.length;

  SourceImportPreview withMode(BookSourceDedupeMode value) {
    if (value == mode) return this;
    final result = const BookSourceDedupeEngine().analyze(
      _dedupeCandidates,
      mode: value,
    );
    return SourceImportPreview._(
      _reports,
      _dedupeCandidates,
      candidates: candidates,
      errors: errors,
      sourceUrls: sourceUrls,
      mode: value,
      dedupeResult: result,
      selectedIndices: result.defaultSelectedIndices,
    );
  }

  SourceImportPreview withSelectedIndices(Set<int> value) {
    if (setEquals(value, selectedIndices)) return this;
    return SourceImportPreview._(
      _reports,
      _dedupeCandidates,
      candidates: candidates,
      errors: errors,
      sourceUrls: sourceUrls,
      mode: mode,
      dedupeResult: dedupeResult,
      selectedIndices: Set.unmodifiable(value),
    );
  }

  late final int supported = _count(SourceCompatibilityLevel.supported);
  late final int partial = _count(SourceCompatibilityLevel.partial);
  late final int unsupported = _count(SourceCompatibilityLevel.unsupported);
  late final int imageSources = _selectedEntries
      .where((entry) => entry.$2.isImageSource)
      .length;
  late final int textSources = _selectedEntries
      .where((entry) => !entry.$2.isImageSource)
      .length;
  late final int runnableImageSources = _selectedEntries.where((entry) {
    return entry.$2.isImageSource &&
        _reports[entry.$1]?.level != SourceCompatibilityLevel.unsupported;
  }).length;
  late final int runnableTextSources = _selectedEntries.where((entry) {
    return !entry.$2.isImageSource &&
        _reports[entry.$1]?.level != SourceCompatibilityLevel.unsupported;
  }).length;
  late final int skipped = errors.length + duplicates;

  int _count(SourceCompatibilityLevel level) =>
      selectedIndices.where((index) => _reports[index]?.level == level).length;

  SourceCompatibilityReport reportFor(ReadingSourceConfig source) =>
      _reports[_candidateIndices[source]]!;

  late final Map<ReadingSourceConfig, int> _candidateIndices = Map.identity()
    ..addEntries(
      candidates.indexed.map((entry) => MapEntry(entry.$2, entry.$1)),
    );

  List<RegisteredBookSource> toRegisteredSources() => _selectedEntries
      .map(
        (entry) => entry.$2.toRegisteredSource(
          compatibilityReport: _reports[entry.$1],
        ),
      )
      .toList(growable: false);

  /// Materializes a large import result away from the Flutter UI isolate.
  /// The preview already contains compatibility reports, so pass those across
  /// instead of scanning every source again during the commit tap.
  Future<List<RegisteredBookSource>> toRegisteredSourcesAsync() {
    final entries = _selectedEntries.toList(growable: false);
    final request = <String, Object?>{
      'sources': entries.map((entry) => entry.$2.raw).toList(growable: false),
      'reports': entries
          .map(
            (entry) => <String, Object?>{
              'level': _reports[entry.$1]!.level.name,
              'issues': _reports[entry.$1]!.issues
                  .map((issue) => issue.name)
                  .toList(growable: false),
            },
          )
          .toList(growable: false),
    };
    return compute(_materializeRegisteredSources, request);
  }
}

({
  BookSourceDedupeResult result,
  Map<int, SourceCompatibilityReport> reports,
  List<BookSourceDedupeCandidate> candidates,
})
_analyzeSources(List<ReadingSourceConfig> sources, BookSourceDedupeMode mode) {
  final reports = <int, SourceCompatibilityReport>{};
  for (final entry in sources.indexed) {
    final report = const SourceCompatibilityScanner().scan(entry.$2);
    reports[entry.$1] = report;
  }
  final candidates = sources.indexed
      .map((entry) {
        final report = reports[entry.$1]!;
        return BookSourceDedupeCandidate(
          index: entry.$1,
          rawConfig: entry.$2.raw,
          compatibilityRank: switch (report.level) {
            SourceCompatibilityLevel.supported => 2,
            SourceCompatibilityLevel.partial => 1,
            SourceCompatibilityLevel.unsupported => 0,
          },
          runnableCapabilities: entry.$2.runnableCapabilities.length,
        );
      })
      .toList(growable: false);
  return (
    result: const BookSourceDedupeEngine().analyze(candidates, mode: mode),
    reports: Map.unmodifiable(reports),
    candidates: List.unmodifiable(candidates),
  );
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

  static const int maxNestedUrls = 50;
  static const int maxNestedDepth = 2;

  final Dio _dio;
  final Dio _systemDio;
  final BookSourceNetworkPolicy _networkPolicy;
  final Set<CancelToken> _activeDownloads = {};
  var _operationGeneration = 0;
  var _closed = false;

  void cancelActiveDownloads([String reason = 'Source import cancelled.']) {
    _operationGeneration++;
    for (final token in _activeDownloads.toList(growable: false)) {
      token.cancel(reason);
    }
  }

  void close({bool force = true}) {
    if (_closed) return;
    _closed = true;
    cancelActiveDownloads();
    _dio.close(force: force);
    if (!identical(_systemDio, _dio)) _systemDio.close(force: force);
  }

  Future<Uint8List> downloadBytes(String input) async {
    final operationGeneration = _startOperation();
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Import URL must use HTTP or HTTPS.');
    }
    return _download(uri, operationGeneration);
  }

  SourceImportPreview parseBytes(Uint8List bytes) {
    return _collect(_parseBytes(bytes));
  }

  Future<SourceImportPreview> parseBytesAsync(Uint8List bytes) {
    return compute(_parseSourceImportPreview, bytes);
  }

  SourceImportPreview parseDecoded(Object? decoded) {
    return _collect(
      parseReadingSourcePayload(decoded, maxNestedUrls: maxNestedUrls),
    );
  }

  SourceImportResult _parseBytes(Uint8List bytes) {
    return _parseSourceImportBytes(bytes);
  }

  Future<SourceImportResult> _parseBytesAsync(Uint8List bytes) {
    return compute(_parseSourceImportBytes, bytes);
  }

  static SourceImportResult _parseSourceImportBytes(Uint8List bytes) {
    return parseReadingSourcePayload(
      decodeSourceImportBytes(bytes),
      maxNestedUrls: maxNestedUrls,
    );
  }

  Future<SourceImportPreview> loadUrl(
    String input, {
    Uint8List? initialBytes,
    SourceImportPreview? initialPreview,
    VoidCallback? onDownloadsComplete,
  }) async {
    final operationGeneration = _startOperation();
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
      initialPreview: initialPreview,
      operationGeneration: operationGeneration,
    );
    _throwIfCancelled(operationGeneration);
    onDownloadsComplete?.call();
    final preview = await compute(_buildSourceImportPreview, {
      'sources': tree.sources
          .map((source) => source.raw)
          .toList(growable: false),
      'errors': tree.errors,
    });
    _throwIfCancelled(operationGeneration);
    return preview;
  }

  Future<_SourceImportTree> _loadRecursive(
    Uri uri, {
    required int depth,
    required Set<String> visited,
    Uint8List? initialBytes,
    SourceImportPreview? initialPreview,
    required int operationGeneration,
  }) async {
    _throwIfCancelled(operationGeneration);
    if (depth > maxNestedDepth) {
      return _SourceImportTree(
        errors: ['$uri: nested import depth exceeds $maxNestedDepth.'],
      );
    }
    if (!visited.add(uri.toString())) return const _SourceImportTree();
    if (visited.length > maxNestedUrls + 1) {
      throw const FormatException('Too many nested source URLs.');
    }
    late final List<ReadingSourceConfig> candidates;
    late final List<Uri> sourceUrls;
    late final List<String> parseErrors;
    if (initialPreview != null) {
      candidates = initialPreview.candidates;
      sourceUrls = initialPreview.sourceUrls;
      parseErrors = initialPreview.errors;
    } else {
      final bytes = initialBytes ?? await _download(uri, operationGeneration);
      final parsed = await _parseBytesAsync(bytes);
      _throwIfCancelled(operationGeneration);
      candidates = parsed.candidates;
      sourceUrls = parsed.sourceUrls;
      parseErrors = parsed.errors;
    }
    final sources = <ReadingSourceConfig>[...candidates];
    final errors = <String>[...parseErrors.map((error) => '$uri: $error')];
    final nestedResults = await _mapWithConcurrency(
      sourceUrls,
      _maxNestedConcurrent,
      (nested) => _loadNestedSafely(
        nested,
        depth: depth + 1,
        visited: visited,
        operationGeneration: operationGeneration,
      ),
    );
    for (final nested in nestedResults) {
      sources.addAll(nested.sources);
      errors.addAll(nested.errors);
    }
    return _SourceImportTree(sources: sources, errors: errors);
  }

  Future<_SourceImportTree> _loadNestedSafely(
    Uri uri, {
    required int depth,
    required Set<String> visited,
    required int operationGeneration,
  }) async {
    try {
      return await _loadRecursive(
        uri,
        depth: depth,
        visited: visited,
        operationGeneration: operationGeneration,
      );
    } on SourceImportCancelledException {
      rethrow;
    } on Object catch (error) {
      return _SourceImportTree(errors: ['$uri: $error']);
    }
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

  Future<Uint8List> _download(Uri initial, int operationGeneration) async {
    var current = initial;
    for (var redirects = 0; redirects <= 5; redirects++) {
      _throwIfCancelled(operationGeneration);
      final resolvedAddresses = await _networkPolicy.resolve(current);
      _throwIfCancelled(operationGeneration);
      // Mirrors SourceHttpTransport: virtual-DNS clients (Surge/Clash/etc.)
      // route the reserved 198.18.0.0/15 range through a local tunnel that
      // the pinned connection factory bypasses, turning valid responses into
      // HTTP 400. Use the system client for that explicitly allowed range.
      final client =
          resolvedAddresses.any(BookSourceNetworkPolicy.isSyntheticDnsAddress)
          ? _systemDio
          : _dio;
      final cancelToken = CancelToken();
      _activeDownloads.add(cancelToken);
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
        );
        _throwIfCancelled(operationGeneration);
        final status = response.statusCode ?? 0;
        if (status < 300) {
          final data = response.data;
          return data is Uint8List
              ? data
              : Uint8List.fromList(data ?? const []);
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
          throw SourceImportCancelledException(
            error.error?.toString() ?? 'Source import cancelled.',
          );
        }
        rethrow;
      } finally {
        _activeDownloads.remove(cancelToken);
      }
    }
    throw const BookSourceProtocolException('Source import failed.');
  }

  int _startOperation() {
    if (_closed) throw const SourceImportCancelledException();
    return _operationGeneration;
  }

  void _throwIfCancelled(int operationGeneration) {
    if (_closed || operationGeneration != _operationGeneration) {
      throw const SourceImportCancelledException();
    }
  }

  SourceImportPreview _collect(SourceImportResult result) {
    return SourceImportPreview(
      sources: result.candidates,
      errors: result.errors,
      sourceUrls: result.sourceUrls,
    );
  }
}

const int _maxNestedConcurrent = 4;

class _SourceImportTree {
  const _SourceImportTree({this.sources = const [], this.errors = const []});

  final List<ReadingSourceConfig> sources;
  final List<String> errors;
}

SourceImportPreview _buildSourceImportPreview(Map<String, Object?> request) {
  final sources = (request['sources']! as List)
      .map(
        (raw) => ReadingSourceConfig.fromJson(
          (raw as Map).map((key, value) => MapEntry('$key', value)),
        ),
      )
      .toList(growable: false);
  return SourceImportPreview(
    sources: sources,
    errors: List<String>.from(request['errors']! as List),
  );
}

List<RegisteredBookSource> _materializeRegisteredSources(
  Map<String, Object?> request,
) {
  final rawSources = request['sources']! as List;
  final reports = request['reports']! as List;
  return rawSources.indexed
      .map((entry) {
        final raw = entry.$2;
        final source = ReadingSourceConfig.fromJson(
          (raw as Map).map((key, value) => MapEntry('$key', value)),
        );
        final reportData = reports[entry.$1] as Map;
        final report = SourceCompatibilityReport(
          level: SourceCompatibilityLevel.values.byName(
            '${reportData['level']}',
          ),
          issues: (reportData['issues'] as List)
              .map((issue) => SourceCompatibilityIssue.values.byName('$issue'))
              .toSet(),
        );
        return source.toRegisteredSource(compatibilityReport: report);
      })
      .toList(growable: false);
}

// On the Dart VM, fusing parses JSON directly from UTF-8 bytes without an
// additional whole-document String allocation. Web uses the SDK fallback.
Object? decodeSourceImportBytes(Uint8List bytes) => const Utf8Decoder(
  allowMalformed: false,
).fuse(const JsonDecoder()).convert(bytes);

SourceImportPreview _parseSourceImportPreview(Uint8List bytes) {
  final result = SourceImportService._parseSourceImportBytes(bytes);
  return SourceImportPreview(
    sources: result.candidates,
    errors: result.errors,
    sourceUrls: result.sourceUrls,
  );
}
