import 'dart:async';

import 'package:flutter/foundation.dart';

import '../source_engine/source_import_service.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_client.dart';

enum BookSourceImportKind { orsp, additional }

class BookSourceImportAnalysis {
  const BookSourceImportAnalysis._({
    required this.kind,
    required this.sources,
    this.additionalPreview,
  });

  factory BookSourceImportAnalysis.orsp(RegisteredBookSource source) {
    return BookSourceImportAnalysis._(
      kind: BookSourceImportKind.orsp,
      sources: [source],
    );
  }

  factory BookSourceImportAnalysis.additional(SourceImportPreview preview) {
    return BookSourceImportAnalysis._(
      kind: BookSourceImportKind.additional,
      sources: const [],
      additionalPreview: preview,
    );
  }

  final BookSourceImportKind kind;
  final List<RegisteredBookSource> sources;
  final SourceImportPreview? additionalPreview;
}

class BookSourceImportAnalyzer {
  BookSourceImportAnalyzer({
    SourceImportService? additionalImporter,
    BookSourceClient Function()? discoveryClientFactory,
  }) : _additionalImporter = additionalImporter ?? SourceImportService(),
       _ownsAdditionalImporter = additionalImporter == null,
       _discoveryClientFactory = discoveryClientFactory ?? BookSourceClient.new;

  final SourceImportService _additionalImporter;
  final bool _ownsAdditionalImporter;
  final BookSourceClient Function() _discoveryClientFactory;
  BookSourceClient? _activeDiscoveryClient;
  var _generation = 0;
  var _closed = false;
  static const urlImportTimeout = Duration(seconds: 30);

  Future<BookSourceImportAnalysis> analyzeUrl(
    String input, {
    VoidCallback? onDownloadStarted,
    VoidCallback? onDownloadComplete,
  }) async {
    if (_closed) throw const SourceImportCancelledException();
    final generation = _generation;
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Source URL must use HTTP or HTTPS.');
    }
    final startedAt = DateTime.now();
    Object? directError;
    late final Uint8List bytes;
    try {
      bytes = await _withinUrlBudget(
        _additionalImporter.downloadBytes(input),
        startedAt,
      );
      _throwIfCancelled(generation);
    } on SourceImportCancelledException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (error) {
      directError = error;
    }
    if (directError == null) {
      onDownloadComplete?.call();
      BookSourceImportAnalysis? result;
      try {
        result = await _withinUrlBudget(
          analyzeBytesAsync(bytes, documentUri: uri),
          startedAt,
        );
        _throwIfCancelled(generation);
      } on TimeoutException {
        _additionalImporter.cancelActiveDownloads('Source import timed out.');
        rethrow;
      } on FormatException catch (error) {
        directError = error;
      }
      if (result != null) {
        if (result.kind == BookSourceImportKind.orsp) return result;
        final preview = result.additionalPreview!;
        if (preview.sourceUrls.isNotEmpty) {
          onDownloadStarted?.call();
          final nested = await _withinUrlBudget(
            _additionalImporter.loadUrl(
              input,
              initialPreview: preview,
              onDownloadsComplete: onDownloadComplete,
            ),
            startedAt,
          );
          _throwIfCancelled(generation);
          if (nested.sources.isEmpty) {
            throw const FormatException(
              'No recognized book sources were found at this URL.',
            );
          }
          return BookSourceImportAnalysis.additional(nested);
        }
        if (preview.sources.isEmpty) {
          throw const FormatException(
            'No recognized book sources were found at this URL.',
          );
        }
        return result;
      }
    }
    // A bare ORSP service URL usually has no JSON body at its root. Keep
    // discovery as the fallback only after direct JSON analysis fails.
    _throwIfCancelled(generation);
    onDownloadStarted?.call();
    final client = _discoveryClientFactory();
    _activeDiscoveryClient = client;
    try {
      final discovered = await _withinUrlBudget(
        client.discover(input),
        startedAt,
      );
      _throwIfCancelled(generation);
      return BookSourceImportAnalysis.orsp(
        RegisteredBookSource.fromManifest(
          manifest: discovered.manifest,
          manifestUrl: discovered.manifestUrl,
        ),
      );
    } on TimeoutException {
      rethrow;
    } catch (_) {
      _throwIfCancelled(generation);
      Error.throwWithStackTrace(directError!, StackTrace.current);
    } finally {
      if (identical(_activeDiscoveryClient, client)) {
        _activeDiscoveryClient = null;
        client.close();
      }
    }
  }

  void cancel() {
    _generation++;
    _additionalImporter.cancelActiveDownloads();
    _activeDiscoveryClient?.close();
    _activeDiscoveryClient = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancel();
    if (_ownsAdditionalImporter) _additionalImporter.close();
  }

  void _throwIfCancelled(int generation) {
    if (_closed || generation != _generation) {
      throw const SourceImportCancelledException();
    }
  }

  Future<T> _withinUrlBudget<T>(Future<T> operation, DateTime startedAt) {
    final remaining = urlImportTimeout - DateTime.now().difference(startedAt);
    if (remaining <= Duration.zero) {
      _additionalImporter.cancelActiveDownloads('Source import timed out.');
      throw TimeoutException(
        'Source import exceeded ${urlImportTimeout.inSeconds} seconds.',
        urlImportTimeout,
      );
    }
    return operation.timeout(
      remaining,
      onTimeout: () {
        _additionalImporter.cancelActiveDownloads('Source import timed out.');
        throw TimeoutException(
          'Source import exceeded ${urlImportTimeout.inSeconds} seconds.',
          urlImportTimeout,
        );
      },
    );
  }

  BookSourceImportAnalysis analyzeBytes(Uint8List bytes, {Uri? documentUri}) {
    return _analyzeBookSourceBytes(
      bytes,
      documentUri: documentUri,
      additionalImporter: _additionalImporter,
    );
  }

  Future<BookSourceImportAnalysis> analyzeBytesAsync(
    Uint8List bytes, {
    Uri? documentUri,
  }) {
    return compute(_analyzeBookSourceBytesInBackground, {
      'bytes': bytes,
      if (documentUri != null) 'documentUri': documentUri.toString(),
    });
  }
}

BookSourceImportAnalysis _analyzeBookSourceBytesInBackground(
  Map<String, Object?> message,
) {
  final bytes = message['bytes']! as Uint8List;
  final documentUri = switch (message['documentUri']) {
    final String value => Uri.parse(value),
    _ => null,
  };
  return _analyzeBookSourceBytes(bytes, documentUri: documentUri);
}

BookSourceImportAnalysis _analyzeBookSourceBytes(
  Uint8List bytes, {
  Uri? documentUri,
  SourceImportService? additionalImporter,
}) {
  late final Object? decoded;
  try {
    decoded = decodeSourceImportBytes(bytes);
  } on FormatException catch (error) {
    throw FormatException('Source JSON is invalid: ${error.message}');
  }

  if (decoded is Map && decoded['protocol'] == openReadingSourceProtocol) {
    final manifest = BookSourceManifest.fromJson(
      decoded.map((key, value) => MapEntry('$key', value)),
    );
    final manifestUrl =
        documentUri ??
        manifest.apiBaseUrl.resolve('/$openReadingSourceDiscoveryPath');
    return BookSourceImportAnalysis.orsp(
      RegisteredBookSource.fromManifest(
        manifest: manifest,
        manifestUrl: manifestUrl,
      ),
    );
  }

  final importer = additionalImporter ?? SourceImportService();
  try {
    return BookSourceImportAnalysis.additional(importer.parseDecoded(decoded));
  } finally {
    if (additionalImporter == null) importer.close();
  }
}
