import 'dart:io';

import 'package:dio/dio.dart';

import '../../models/registered_book_source.dart';
import '../../services/book_download_cancellation.dart';
import '../../services/book_source_network_policy.dart';
import '../../services/book_source_response_cache.dart';
import '../book_source_protocol.dart';

class OrspHttpPipeline {
  OrspHttpPipeline(
    this._dio,
    this._networkPolicy,
    this._responseCache, {
    required this._systemDio,
  });

  final Dio _dio;
  final Dio _systemDio;
  final BookSourceNetworkPolicy _networkPolicy;
  final BookSourceResponseCache _responseCache;

  static const int maxResponseBytes = 8 * 1024 * 1024;
  static const int maxDownloadResponseBytes = 24 * 1024 * 1024;
  static const Duration downloadReceiveTimeout = Duration(seconds: 90);
  static const int _maxRetryAttempts = 3;
  static const Duration _maxRetryAfter = Duration(seconds: 60);

  Future<Object?> getBounded(
    Uri uri, {
    int maxBytes = maxResponseBytes,
    Duration? receiveTimeout,
    BookDownloadCancellation? cancellation,
  }) async {
    final cancelToken = CancelToken();
    void cancelRequest() => cancelToken.cancel('Book download cancelled.');
    cancellation?.throwIfCancelled();
    cancellation?.addListener(cancelRequest);
    try {
      var current = uri;
      for (var redirects = 0; redirects <= 5; redirects++) {
        final addresses = await _networkPolicy.resolve(current);
        final client =
            addresses.any(BookSourceNetworkPolicy.isSyntheticDnsAddress)
            ? _systemDio
            : _dio;
        final response = await client.getUri<Object?>(
          current,
          options: Options(
            receiveTimeout: receiveTimeout,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (received > maxBytes || total > maxBytes) {
              cancelToken.cancel('Response exceeds $maxBytes bytes.');
            }
          },
        );
        final status = response.statusCode ?? 0;
        if (status < 300) {
          cancellation?.throwIfCancelled();
          return response.data;
        }
        if (redirects == 5) {
          throw const BookSourceProtocolException(
            'Book source redirected too many times.',
          );
        }
        current = BookSourceNetworkPolicy.redirectTarget(
          current,
          response.headers.value(HttpHeaders.locationHeader),
        );
      }
      cancellation?.throwIfCancelled();
      throw const BookSourceProtocolException('Book source request failed.');
    } on DioException {
      cancellation?.throwIfCancelled();
      rethrow;
    } finally {
      cancellation?.removeListener(cancelRequest);
    }
  }

  Future<Map<String, dynamic>> cachedJson({
    required String key,
    required Duration ttl,
    required Uri uri,
    required Object? Function(Map<String, dynamic>) validate,
    BookDownloadCancellation? cancellation,
    bool deduplicateInFlight = true,
    bool persistToDisk = true,
  }) async {
    final json = await _responseCache.getOrLoadJson(
      key: key,
      ttl: ttl,
      deduplicateInFlight: deduplicateInFlight,
      persistToDisk: persistToDisk,
      loader: () async {
        final value = decodeBookSourceJson(
          await getBounded(uri, cancellation: cancellation),
        );
        validate(value);
        return value;
      },
    );
    try {
      validate(json);
      return json;
    } catch (_) {
      await _responseCache.invalidate(key);
      rethrow;
    }
  }

  Future<T> withRetries<T>(
    Future<T> Function() request, {
    BookDownloadCancellation? cancellation,
  }) async {
    for (var attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      cancellation?.throwIfCancelled();
      try {
        return await request();
      } on DioException catch (error) {
        if (attempt == _maxRetryAttempts || !_isRetryable(error)) {
          throw mapDioException(error);
        }
        final delay = _retryDelay(error, attempt);
        if (cancellation == null) {
          await Future<void>.delayed(delay);
        } else {
          await cancellation.delay(delay);
        }
      }
    }
    throw const BookSourceProtocolException('Source request failed.');
  }

  Future<void> invalidateSource(RegisteredBookSource source) =>
      _responseCache.invalidatePrefix(sourceCachePrefix(source));

  Future<void> invalidateSources(Iterable<RegisteredBookSource> sources) =>
      _responseCache.invalidatePrefixes(sources.map(sourceCachePrefix));

  Future<void> invalidateDiscovery(Uri manifestUrl) =>
      _responseCache.invalidate(discoveryCacheKey(manifestUrl));

  BookSourceProtocolException mapDioException(DioException error) =>
      BookSourceProtocolException(
        _dioErrorMessage(error),
        code: _sourceErrorCode(error),
      );

  static Uri apiUri(Uri baseUrl, String relativePath) {
    final normalizedPath = baseUrl.path.endsWith('/')
        ? baseUrl.path
        : '${baseUrl.path}/';
    return baseUrl.replace(path: normalizedPath).resolve(relativePath);
  }

  static String sourceCachePrefix(RegisteredBookSource source) =>
      'orsp|${Uri.encodeComponent(source.id)}|'
      '${Uri.encodeComponent(source.apiBaseUrl.toString())}|'
      '${Uri.encodeComponent(source.protocolVersion)}|';

  static String cacheKey(
    RegisteredBookSource source,
    String operation, [
    List<String> parameters = const [],
  ]) =>
      '${sourceCachePrefix(source)}${Uri.encodeComponent(operation)}|'
      '${parameters.map(Uri.encodeComponent).join('|')}';

  static String discoveryCacheKey(Uri manifestUrl) =>
      'orsp-discovery|${Uri.encodeComponent(manifestUrl.toString())}';

  bool _isRetryable(DioException error) {
    final status = error.response?.statusCode;
    if (status == null) {
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError => true,
        _ => false,
      };
    }
    return status == HttpStatus.tooManyRequests || status >= 500;
  }

  Duration _retryDelay(DioException error, int attempt) =>
      _retryAfterHeader(error) ??
      Duration(milliseconds: 500 * attempt * attempt);

  Duration? _retryAfterHeader(DioException error) {
    final value = error.response?.headers.value(HttpHeaders.retryAfterHeader);
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(0, _maxRetryAfter.inSeconds));
    }
    try {
      final delta = HttpDate.parse(value.trim()).difference(DateTime.now());
      if (delta.isNegative) return Duration.zero;
      return delta > _maxRetryAfter ? _maxRetryAfter : delta;
    } on FormatException {
      return null;
    }
  }

  String _dioErrorMessage(DioException error) {
    final status = error.response?.statusCode;
    final serverMessage = _errorBody(error)?['message'];
    if (serverMessage is String && serverMessage.trim().isNotEmpty) {
      return status == null
          ? serverMessage.trim()
          : '${serverMessage.trim()} (HTTP $status)';
    }
    if (status != null) return 'Source request failed with HTTP $status.';
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'Source request timed out.',
      DioExceptionType.connectionError => 'Could not connect to the source.',
      _ => error.message ?? 'Source request failed.',
    };
  }

  String? _sourceErrorCode(DioException error) {
    final code = _errorBody(error)?['code'];
    return code is String && code.trim().isNotEmpty ? code.trim() : null;
  }

  Map<String, dynamic>? _errorBody(DioException error) {
    try {
      final data = error.response?.data;
      if (data == null) return null;
      final body = decodeBookSourceJson(data)['error'];
      return body is Map ? decodeBookSourceJson(body) : null;
    } catch (_) {
      return null;
    }
  }
}
