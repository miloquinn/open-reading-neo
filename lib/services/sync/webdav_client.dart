import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:dio/dio.dart';

import 'secure_sync_config.dart';
import 'sync_models.dart';

typedef WebDavClientFactory =
    WebDavClient Function(StoredSyncCredentials credentials);

class WebDavClient {
  WebDavClient({required Dio dio, required StoredSyncCredentials credentials})
    : _dio = dio,
      _credentials = credentials,
      _origin = validateWebDavConfiguration(credentials.configuration) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['sync_started'] = Stopwatch()..start();
          handler.next(options);
        },
        onResponse: (response, handler) {
          _recordRequest(response.requestOptions, response.statusCode);
          handler.next(response);
        },
        onError: (error, handler) {
          _recordRequest(error.requestOptions, error.response?.statusCode);
          handler.next(error);
        },
      ),
    );
  }

  factory WebDavClient.standard(StoredSyncCredentials credentials) {
    return WebDavClient(
      dio: Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
          responseType: ResponseType.plain,
        ),
      ),
      credentials: credentials,
    );
  }

  final Dio _dio;
  final StoredSyncCredentials _credentials;
  final Uri _origin;
  DateTime? lastServerDate;
  final Set<String> _knownCollections = {};
  final List<Map<String, Object?>> recentRequests = [];

  void _recordRequest(RequestOptions options, int? status) {
    final watch = options.extra['sync_started'] as Stopwatch?;
    final parts = options.uri.pathSegments;
    final kind = parts.contains('chunks')
        ? 'chunk'
        : parts.contains('revisions')
        ? 'revision'
        : parts.contains('changes')
        ? 'metadata'
        : parts.contains('checkpoints')
        ? 'checkpoint'
        : parts.contains('exports')
        ? 'export'
        : 'connection';
    recentRequests.add({
      'method': options.method,
      'resource': kind,
      'http_status': status,
      'elapsed_ms': watch?.elapsedMilliseconds,
    });
    if (recentRequests.length > 40) recentRequests.removeAt(0);
  }

  Uri uriForRootRelativePath(String relativePath) {
    final segments = relativePath.split('/');
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.endsWith('/') ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Invalid WebDAV root-relative path.',
      );
    }
    return _pathUri([..._rootSegments, ...segments]);
  }

  Future<void> ensureRootRelativeParent(String relativePath) async {
    final segments = relativePath.split('/');
    if (segments.length <= 1) {
      await ensureCollection(_rootSegments);
      return;
    }
    await ensureCollection([
      ..._rootSegments,
      ...segments.take(segments.length - 1),
    ]);
  }

  /// User-visible files live directly below the configured storage folder.
  Uri rootPath(List<String> relativeSegments) =>
      _pathUri([..._rootSegments, ...relativeSegments]);

  String get readableSpaceKey => jsonEncode([
    rootPath(const []).toString(),
    _credentials.configuration.username,
  ]);

  Future<void> ensureRootPath(List<String> relativeSegments) =>
      ensureCollection([..._rootSegments, ...relativeSegments]);

  List<String> get _rootSegments => _credentials.configuration.rootPath
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  Uri _pathUri(List<String> segments) {
    final baseSegments = _origin.pathSegments.where((part) => part.isNotEmpty);
    return _origin.replace(
      pathSegments: [...baseSegments, ...segments],
      query: null,
      fragment: null,
    );
  }

  Future<ConnectionTestResult> testConnection() async {
    try {
      await ensureCollection([..._rootSegments]);
      final rootProbe = await _request(
        'PROPFIND',
        _pathUri(_rootSegments),
        headers: const {'Depth': '0'},
        data: _propfindBody,
      );
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      final testCollection = _pathUri([
        ..._rootSegments,
        '.open-reading-test-$suffix',
      ]);
      final testFile = testCollection.replace(
        pathSegments: [...testCollection.pathSegments, 'probe.txt'],
      );
      await _request('MKCOL', testCollection);
      try {
        final put = await _request(
          'PUT',
          testFile,
          data: 'open-reading-webdav-probe',
        );
        final get = await _request('GET', testFile);
        if (get.data != 'open-reading-webdav-probe') {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.serverIncompatible,
            'The server did not return the test file unchanged.',
          );
        }
        try {
          await _request('DELETE', testFile);
        } catch (_) {
          /* Cleanup is optional. */
        }
        return ConnectionTestResult(
          success: true,
          supportsEtag:
              put.headers.value('etag') != null ||
              rootProbe.headers.value('etag') != null,
          serverDate: _serverDate(get),
        );
      } finally {
        try {
          await _request('DELETE', testCollection);
        } catch (_) {
          // The probe file is already removed. Some servers refuse collection
          // deletion; a unique empty test directory is harmless.
        }
      }
    } on WebDavSyncFailure catch (error) {
      return ConnectionTestResult(
        success: false,
        errorCode: error.code,
        message: error.message,
        failure: error,
      );
    }
  }

  Future<void> ensureCollection(List<String> segments) async {
    final built = <String>[];
    for (final segment in segments) {
      built.add(segment);
      final key = _pathUri(built).toString();
      if (_knownCollections.contains(key)) continue;
      try {
        await _request('MKCOL', _pathUri(built));
      } on WebDavSyncFailure catch (error) {
        if (error.statusCode != 405) rethrow;
      }
      _knownCollections.add(key);
    }
  }

  Future<String?> getText(Uri uri, {bool allowNotFound = false}) async {
    try {
      final response = await _request('GET', uri);
      return response.data;
    } on WebDavSyncFailure catch (error) {
      if (allowNotFound && error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> putFile(
    Uri uri,
    File file, {
    void Function(int sent, int total)? onProgress,
    int redirects = 0,
  }) async {
    if (!_sameOrigin(uri, _origin)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'Book files can only be uploaded to the configured WebDAV origin.',
      );
    }
    final total = await file.length();
    try {
      final response = await _dio.request<void>(
        uri.toString(),
        data: file.openRead(),
        onSendProgress: onProgress,
        options: Options(
          method: 'PUT',
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization': _authorization,
            Headers.contentLengthHeader: total,
            Headers.contentTypeHeader: 'application/octet-stream',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        final redirected = location == null ? null : uri.resolve(location);
        if (redirects >= 5 ||
            redirected == null ||
            !_sameOrigin(redirected, _origin)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.serverIncompatible,
            'The WebDAV upload redirect is unsafe or repeated.',
          );
        }
        return await putFile(
          redirected,
          file,
          onProgress: onProgress,
          redirects: redirects + 1,
        );
      }
      _rememberServerDate(response);
      if (status < 200 || status >= 300) throw _statusFailure(status);
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('PUT', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('PUT', uri);
    }
  }

  Future<void> downloadFile(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!_sameOrigin(uri, _origin)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'Book files can only be downloaded from the configured WebDAV origin.',
      );
    }
    try {
      final response = await _dio.get<ResponseBody>(
        uri.toString(),
        options: Options(
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
          headers: {'Authorization': _authorization},
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) throw _statusFailure(status);
      final body = response.data;
      if (body == null) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The WebDAV server returned an empty book-file response.',
        );
      }
      final total =
          int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          -1;
      final sink = target.openWrite();
      var received = 0;
      try {
        await sink.addStream(
          body.stream.map((chunk) {
            received += chunk.length;
            onProgress?.call(received, total);
            return chunk;
          }),
        );
        await sink.flush();
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('GET', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('GET', uri);
    }
  }

  Future<void> delete(Uri uri, {bool allowNotFound = true}) async {
    try {
      await _request('DELETE', uri);
    } on WebDavSyncFailure catch (error) {
      if (!allowNotFound || error.statusCode != 404) rethrow;
    }
  }

  Future<List<WebDavListEntry>> listEntries(Uri collection) async {
    final response = await _request(
      'PROPFIND',
      collection,
      headers: const {'Depth': '1'},
      data: _resourcePropfindBody,
    );
    final entries = <WebDavListEntry>[];
    final envelopes = _xmlValues(response.data ?? '', 'multistatus').toList();
    if (envelopes.length != 1 ||
        _xmlValues(envelopes.single, 'response').isEmpty) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'The WebDAV server returned an invalid directory listing.',
      );
    }
    for (final responseXml in _xmlValues(envelopes.single, 'response')) {
      final hrefs = _xmlValues(responseXml, 'href').toList();
      if (hrefs.length != 1) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The WebDAV directory entry has no unique resource address.',
        );
      }
      final uri = collection.resolve(_decodeXml(hrefs.single.trim()));
      if (!_sameOrigin(uri, _origin) || uri == collection) continue;
      String? etag;
      int? length;
      var isCollection = false;
      var readable = false;
      for (final propstat in _xmlValues(responseXml, 'propstat')) {
        final statuses = _xmlValues(propstat, 'status').toList();
        if (statuses.length != 1 ||
            !RegExp(
              r'^HTTP/\S+ 200(?:\s|$)',
            ).hasMatch(statuses.single.trim())) {
          continue;
        }
        for (final prop in _xmlValues(propstat, 'prop')) {
          readable = true;
          isCollection = _xmlValues(prop, 'resourcetype').any(
            (value) =>
                RegExp(r'<(?:[A-Za-z0-9_-]+:)?collection\b').hasMatch(value),
          );
          for (final value in _xmlValues(prop, 'getetag')) {
            final decoded = _decodeXml(value.trim());
            if (_isStrongEtag(decoded)) etag = decoded;
          }
          for (final value in _xmlValues(prop, 'getcontentlength')) {
            length = int.tryParse(value.trim());
          }
        }
      }
      if (!readable) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The WebDAV directory contains an unreadable resource.',
        );
      }
      entries.add(
        WebDavListEntry(
          uri: uri,
          isCollection: isCollection,
          etag: etag,
          contentLength: length,
        ),
      );
    }
    return entries;
  }

  Future<Response<String>> _request(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? data,
    int redirects = 0,
  }) async {
    if (!_sameOrigin(uri, _origin)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'The WebDAV server attempted to redirect credentials to another origin.',
      );
    }
    try {
      final response = await _dio.request<String>(
        uri.toString(),
        data: data,
        options: Options(
          method: method,
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
          headers: {'Authorization': _authorization, ...?headers},
        ),
      );
      final status = response.statusCode ?? 0;
      final dateHeader = response.headers.value('date');
      if (dateHeader != null) {
        lastServerDate = _parseHttpDate(dateHeader);
      }
      if (status >= 300 && status < 400) {
        if (redirects >= 5) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.serverIncompatible,
            'The WebDAV server returned too many redirects.',
          );
        }
        final location = response.headers.value('location');
        if (location == null) {
          throw _statusFailure(status);
        }
        final redirected = uri.resolve(location);
        if (!_sameOrigin(redirected, uri)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.serverIncompatible,
            'The WebDAV server attempted to redirect credentials to another origin.',
          );
        }
        return await _request(
          method,
          redirected,
          headers: headers,
          data: data,
          redirects: redirects + 1,
        );
      }
      if (status < 200 || status >= 300) throw _statusFailure(status);
      return response;
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest(method, uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest(method, uri);
    }
  }

  void _rememberServerDate(Response response) {
    final dateHeader = response.headers.value('date');
    if (dateHeader != null) lastServerDate = _parseHttpDate(dateHeader);
  }

  DateTime? _serverDate(Response response) {
    final value = response.headers.value('date');
    return value == null ? null : _parseHttpDate(value);
  }

  String get _authorization =>
      'Basic ${base64Encode(utf8.encode('${_credentials.configuration.username}:${_credentials.password}'))}';
}

class WebDavListEntry {
  const WebDavListEntry({
    required this.uri,
    required this.isCollection,
    this.etag,
    this.contentLength,
  });

  final Uri uri;
  final bool isCollection;
  final String? etag;
  final int? contentLength;
}

const _propfindBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/></d:prop></d:propfind>''';

const _resourcePropfindBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>''';

bool _isStrongEtag(String? value) =>
    value != null &&
    RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value.trim());

// The DAV properties used here contain only text. Keep extraction scoped to
// the matching response and successful propstat, as a 207 can include failures
// and properties belonging to other resources.
Iterable<String> _xmlValues(String body, String name) sync* {
  final pattern = RegExp(
    '<((?:[A-Za-z_][A-Za-z0-9_.-]*:)?$name)(?:\\s[^>]*)?>(.*?)</\\1\\s*>',
    dotAll: true,
  );
  for (final match in pattern.allMatches(body)) {
    yield match.group(2)!;
  }
}

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port;

DateTime? _parseHttpDate(String value) {
  try {
    return HttpDate.parse(value).toUtc();
  } catch (_) {
    return DateTime.tryParse(value)?.toUtc();
  }
}

String _decodeXml(String value) => value.replaceAllMapped(
  RegExp(r'&(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);'),
  (match) {
    final entity = match.group(0)!;
    final named = switch (entity) {
      '&amp;' => '&',
      '&lt;' => '<',
      '&gt;' => '>',
      '&quot;' => '"',
      '&apos;' => "'",
      _ => null,
    };
    if (named != null) return named;
    final hex = entity.startsWith('&#x');
    final code = int.tryParse(
      entity.substring(hex ? 3 : 2, entity.length - 1),
      radix: hex ? 16 : 10,
    );
    if (code == null ||
        code > 0x10ffff ||
        code == 0 ||
        (code >= 0xd800 && code <= 0xdfff)) {
      return entity;
    }
    return String.fromCharCode(code);
  },
);

WebDavSyncFailure _statusFailure(int status) {
  final code = switch (status) {
    401 => WebDavSyncErrorCode.authentication,
    403 => WebDavSyncErrorCode.permissionDenied,
    404 => WebDavSyncErrorCode.notFound,
    409 || 412 || 423 => WebDavSyncErrorCode.conflict,
    429 => WebDavSyncErrorCode.rateLimited,
    507 => WebDavSyncErrorCode.storageFull,
    >= 500 && <= 599 => WebDavSyncErrorCode.serverError,
    _ => WebDavSyncErrorCode.serverIncompatible,
  };
  return WebDavSyncFailure(
    code,
    'The WebDAV server rejected the request (HTTP $status).',
    statusCode: status,
  );
}

WebDavSyncFailure _dioFailure(DioException error) {
  final code = switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => WebDavSyncErrorCode.timeout,
    DioExceptionType.badCertificate => WebDavSyncErrorCode.tls,
    DioExceptionType.connectionError => WebDavSyncErrorCode.network,
    _ => WebDavSyncErrorCode.network,
  };
  return WebDavSyncFailure(
    code,
    code == WebDavSyncErrorCode.tls
        ? 'The WebDAV server certificate could not be verified.'
        : 'The WebDAV server could not be reached.',
  );
}
