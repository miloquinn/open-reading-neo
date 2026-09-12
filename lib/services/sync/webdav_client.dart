import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ignore_for_file: prefer_initializing_formals

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'secure_sync_config.dart';
import 'sync_models.dart';

typedef WebDavClientFactory =
    WebDavClient Function(StoredSyncCredentials credentials);

class WebDavClient {
  WebDavClient({required Dio dio, required StoredSyncCredentials credentials})
    : _dio = dio,
      _credentials = credentials,
      _origin = validateWebDavConfiguration(credentials.configuration);

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
      final options = await _request('OPTIONS', _origin);
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
        await _request('DELETE', testFile);
        final allow = options.headers.value('allow')?.toUpperCase() ?? '';
        return ConnectionTestResult(
          success: true,
          supportsEtag:
              put.headers.value('etag') != null ||
              rootProbe.headers.value('etag') != null,
          supportsMove: allow.contains('MOVE'),
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

  Future<WebDavResourceState> resourceState(Uri uri) async {
    try {
      final response = await _request('HEAD', uri);
      final etag = response.headers.value('etag');
      final length = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (_isStrongEtag(etag)) {
        return WebDavResourceState(
          exists: true,
          etag: etag!.trim(),
          contentLength: length,
        );
      }
      // Some DAV servers expose validators as properties but omit them from
      // PUT/HEAD headers. Query only this resource, not its containing folder.
      final properties = await _request(
        'PROPFIND',
        uri,
        headers: const {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        data: _resourcePropfindBody,
      );
      return _parseResourceProperties(properties.data ?? '', uri, length);
    } on WebDavSyncFailure catch (error) {
      if (error.statusCode == 404) return const WebDavResourceState.missing();
      rethrow;
    }
  }

  /// Writes a mutable resource without allowing an unobserved overwrite.
  ///
  /// Callers must provide exactly one precondition: [ifMatch] for an existing
  /// resource or [ifNoneMatch] for first publication. A server that omits ETag
  /// in response headers is queried through DAV properties. A validator read
  /// after PUT is accepted only after verifying the stored bytes and version.
  Future<WebDavConditionalWriteResult> putFileConditionally(
    Uri uri,
    File file, {
    String? ifMatch,
    bool ifNoneMatch = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    if ((ifMatch == null) == !ifNoneMatch) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'A mutable WebDAV write requires exactly one version precondition.',
      );
    }
    if (!_sameOrigin(uri, _origin)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'Book files can only be uploaded to the configured WebDAV origin.',
      );
    }
    final total = await file.length();
    final requestHeaders = <String, Object?>{
      'Authorization': _authorization,
      Headers.contentLengthHeader: total,
      Headers.contentTypeHeader: switch (uri.pathSegments.last
          .toLowerCase()
          .split('.')
          .last) {
        'epub' => 'application/epub+zip',
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'json' => 'application/json; charset=utf-8',
        // TXT bytes may retain GBK or UTF-16; do not mislabel them UTF-8.
        'txt' => 'text/plain',
        _ => 'application/octet-stream',
      },
    };
    if (ifMatch case final value?) {
      requestHeaders['If-Match'] = value;
    }
    if (ifNoneMatch) requestHeaders['If-None-Match'] = '*';
    try {
      final response = await _dio.request<void>(
        uri.toString(),
        data: file.openRead(),
        onSendProgress: onProgress,
        options: Options(
          method: 'PUT',
          followRedirects: false,
          validateStatus: (_) => true,
          headers: requestHeaders,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) throw _statusFailure(status);
      var etag = response.headers.value('etag');
      final needsVerification = !_isStrongEtag(etag);
      if (needsVerification) {
        etag = (await resourceState(uri)).etag;
      }
      if (!_isStrongEtag(etag)) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The WebDAV server did not provide an ETag for a mutable file.',
        );
      }
      final version = etag!.trim();
      if (needsVerification) {
        await _verifyWrittenVersion(uri, file, version);
      }
      return WebDavConditionalWriteResult(etag: version, contentLength: total);
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('PUT', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('PUT', uri);
    }
  }

  Future<void> _verifyWrittenVersion(Uri uri, File file, String etag) async {
    final response = await _dio.get<ResponseBody>(
      uri.toString(),
      options: Options(
        followRedirects: false,
        validateStatus: (_) => true,
        responseType: ResponseType.stream,
        headers: {
          'Authorization': _authorization,
          'If-Match': etag,
          'Cache-Control': 'no-cache',
        },
      ),
    );
    final status = response.statusCode ?? 0;
    if (status != 200 || response.data == null) {
      await response.data?.stream.listen(null).cancel();
      throw _statusFailure(status).withRequest('GET', uri);
    }
    _requireResponseEtag(response, expectedEtag: etag);
    final remoteHash = await sha256.bind(response.data!.stream).first;
    final localHash = await sha256.bind(file.openRead()).first;
    if (remoteHash != localHash) {
      throw WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The uploaded file differs from its verified WebDAV response.',
        requestMethod: 'GET',
        resourcePath: uri.path,
      );
    }
  }

  /// Probes conditional writes in an isolated protocol folder.
  ///
  /// Advertising ETags is insufficient: some WebDAV frontends accept but
  /// ignore precondition headers. This probe requires both stale If-Match and
  /// existing If-None-Match writes to fail while preserving the seed bytes.
  Future<void> verifyMutableWritePreconditions() async {
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    const seed = 'open-reading-conditional-seed';
    final root = await Directory.systemTemp.createTemp(
      'open-reading-dav-probe-',
    );
    final seedFile = File('${root.path}/seed.txt');
    final replacementFile = File('${root.path}/replacement.txt');
    await seedFile.writeAsString(seed, flush: true);
    await replacementFile.writeAsString('must-not-replace-seed', flush: true);
    final relativeDirectory = ['sync', '.capabilities'];
    final remote = rootPath([...relativeDirectory, 'conditional-$suffix.txt']);
    try {
      await ensureRootPath(relativeDirectory);
      await putFileConditionally(remote, seedFile, ifNoneMatch: true);
      await _expectPreconditionRejection(remote, 'If-None-Match', () async {
        await putFileConditionally(remote, replacementFile, ifNoneMatch: true);
      });
      await _expectPreconditionRejection(remote, 'If-Match', () async {
        await putFileConditionally(
          remote,
          replacementFile,
          ifMatch: '"open-reading-intentionally-stale"',
        );
      });
      if (await getText(remote) != seed) {
        throw WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The conditional-write probe file changed despite rejected writes.',
          requestMethod: 'GET',
          resourcePath: remote.path,
        );
      }
    } finally {
      try {
        await delete(remote);
      } catch (_) {
        // A failed cleanup does not change the capability result.
      }
      if (await root.exists()) await root.delete(recursive: true);
    }
  }

  Future<void> _expectPreconditionRejection(
    Uri uri,
    String precondition,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } on WebDavSyncFailure catch (error) {
      if (error.statusCode == 412) return;
      rethrow;
    }
    throw WebDavSyncFailure(
      WebDavSyncErrorCode.serverIncompatible,
      'The WebDAV server accepted a PUT that should have been rejected '
      'by $precondition. TXT overwrite protection could not be verified.',
      requestMethod: 'PUT',
      resourcePath: uri.path,
    );
  }

  Future<void> ensureCollection(List<String> segments) async {
    final built = <String>[];
    for (final segment in segments) {
      built.add(segment);
      try {
        await _request('MKCOL', _pathUri(built));
      } on WebDavSyncFailure catch (error) {
        if (error.statusCode != 405) rethrow;
      }
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

  /// Reads UTF-8 text and binds the returned bytes to the strong validator
  /// carried by the same GET response.
  Future<WebDavVersionedText> getTextWithVersion(
    Uri uri, {
    String? expectedEtag,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        uri.toString(),
        options: Options(
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.bytes,
          headers: {
            'Authorization': _authorization,
            'Cache-Control': 'no-cache',
            'If-Match': ?expectedEtag,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      _rememberServerDate(response);
      if (status < 200 || status >= 300) throw _statusFailure(status);
      final etag = _requireResponseEtag(response, expectedEtag: expectedEtag);
      final bytes = response.data ?? const <int>[];
      return WebDavVersionedText(
        text: utf8.decode(bytes),
        etag: etag,
        contentLength: bytes.length,
        contentType: response.headers.value(Headers.contentTypeHeader),
      );
    } on FormatException {
      throw WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The WebDAV object is not valid UTF-8 text.',
      ).withRequest('GET', uri);
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('GET', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('GET', uri);
    }
  }

  /// Streams a response into [destination]. The returned strong validator is
  /// taken from that same GET response; no later HEAD is used as proof.
  Future<WebDavConditionalWriteResult> downloadWithVersion(
    Uri uri,
    IOSink destination, {
    String? expectedEtag,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        uri.toString(),
        options: Options(
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
          headers: {
            'Authorization': _authorization,
            'Cache-Control': 'no-cache',
            'If-Match': ?expectedEtag,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      _rememberServerDate(response);
      final body = response.data;
      if (status < 200 || status >= 300 || body == null) {
        await body?.stream.listen(null).cancel();
        throw _statusFailure(status);
      }
      final etag = _requireResponseEtag(response, expectedEtag: expectedEtag);
      var received = 0;
      await destination.addStream(
        body.stream.map((chunk) {
          received += chunk.length;
          return chunk;
        }),
      );
      await destination.flush();
      final declaredLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength != received) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The WebDAV response length did not match its body.',
        );
      }
      return WebDavConditionalWriteResult(
        etag: etag,
        contentLength: received,
        contentType: response.headers.value(Headers.contentTypeHeader),
      );
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('GET', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('GET', uri);
    }
  }

  Future<WebDavConditionalWriteResult> putStreamConditionally(
    Uri uri,
    Stream<List<int>> bytes, {
    required int length,
    required String contentType,
    String? ifMatch,
    bool ifNoneMatch = false,
  }) async {
    if ((ifMatch == null) == !ifNoneMatch) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'A mutable WebDAV write requires exactly one version precondition.',
      );
    }
    try {
      final response = await _dio.request<void>(
        uri.toString(),
        data: bytes,
        options: Options(
          method: 'PUT',
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization': _authorization,
            Headers.contentLengthHeader: length,
            Headers.contentTypeHeader: contentType,
            'If-Match': ?ifMatch,
            if (ifNoneMatch) 'If-None-Match': '*',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      _rememberServerDate(response);
      if (status < 200 || status >= 300) throw _statusFailure(status);
      var etag = response.headers.value('etag');
      if (!_isStrongEtag(etag)) {
        etag = (await resourceState(uri)).etag;
      }
      if (!_isStrongEtag(etag)) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.serverIncompatible,
          'The WebDAV server did not provide a strong object validator.',
        );
      }
      return WebDavConditionalWriteResult(
        etag: etag!.trim(),
        contentLength: length,
        contentType: contentType,
      );
    } on WebDavSyncFailure catch (error) {
      throw error.withRequest('PUT', uri);
    } on DioException catch (error) {
      throw _dioFailure(error).withRequest('PUT', uri);
    }
  }

  Future<void> deleteConditionally(Uri uri, {required String ifMatch}) async {
    await _request('DELETE', uri, headers: {'If-Match': ifMatch});
  }

  Future<void> putFile(
    Uri uri,
    File file, {
    void Function(int sent, int total)? onProgress,
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
    for (final responseXml in _xmlValues(response.data ?? '', 'response')) {
      final hrefs = _xmlValues(responseXml, 'href').toList();
      if (hrefs.length != 1) continue;
      final uri = collection.resolve(_decodeXml(hrefs.single.trim()));
      if (!_sameOrigin(uri, _origin) || uri == collection) continue;
      String? etag;
      int? length;
      var isCollection = false;
      for (final propstat in _xmlValues(responseXml, 'propstat')) {
        final statuses = _xmlValues(propstat, 'status').toList();
        if (statuses.length != 1 ||
            !RegExp(
              r'^HTTP/\S+ 200(?:\s|$)',
            ).hasMatch(statuses.single.trim())) {
          continue;
        }
        for (final prop in _xmlValues(propstat, 'prop')) {
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
        return _request(
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

  String _requireResponseEtag(Response response, {String? expectedEtag}) {
    final etag = response.headers.value('etag')?.trim();
    if (!_isStrongEtag(etag)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'The WebDAV GET response did not include a strong ETag.',
      );
    }
    if (expectedEtag != null && etag != expectedEtag) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The WebDAV object version changed during the conditional read.',
      );
    }
    return etag!;
  }

  DateTime? _serverDate(Response response) {
    final value = response.headers.value('date');
    return value == null ? null : _parseHttpDate(value);
  }

  String get _authorization =>
      'Basic ${base64Encode(utf8.encode('${_credentials.configuration.username}:${_credentials.password}'))}';
}

class WebDavResourceState {
  const WebDavResourceState({
    required this.exists,
    this.etag,
    this.contentLength,
  });

  const WebDavResourceState.missing()
    : exists = false,
      etag = null,
      contentLength = null;

  final bool exists;
  final String? etag;
  final int? contentLength;
}

class WebDavConditionalWriteResult {
  const WebDavConditionalWriteResult({
    required this.etag,
    required this.contentLength,
    this.contentType,
  });

  final String etag;
  final int contentLength;
  final String? contentType;
}

class WebDavVersionedText {
  const WebDavVersionedText({
    required this.text,
    required this.etag,
    required this.contentLength,
    this.contentType,
  });

  final String text;
  final String etag;
  final int contentLength;
  final String? contentType;
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
<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontentlength/></d:prop></d:propfind>''';

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

WebDavResourceState _parseResourceProperties(
  String body,
  Uri uri,
  int? headLength,
) {
  for (final response in _xmlValues(body, 'response')) {
    final hrefs = _xmlValues(response, 'href').toList();
    if (hrefs.length != 1) continue;
    final target = uri.resolve(_decodeXml(hrefs.single.trim()));
    if (target != uri) continue;
    String? etag;
    int? length;
    for (final propstat in _xmlValues(response, 'propstat')) {
      final statuses = _xmlValues(propstat, 'status').toList();
      if (statuses.length != 1 ||
          !RegExp(r'^HTTP/\S+ 200(?:\s|$)').hasMatch(statuses.single.trim())) {
        continue;
      }
      for (final prop in _xmlValues(propstat, 'prop')) {
        for (final value in _xmlValues(prop, 'getetag')) {
          final decoded = _decodeXml(value.trim());
          if (_isStrongEtag(decoded)) etag = decoded;
        }
        for (final value in _xmlValues(prop, 'getcontentlength')) {
          length = int.tryParse(value.trim());
        }
      }
    }
    return WebDavResourceState(
      exists: true,
      etag: etag,
      contentLength: length ?? headLength,
    );
  }
  throw WebDavSyncFailure(
    WebDavSyncErrorCode.serverIncompatible,
    'The WebDAV property response did not identify the requested resource.',
    requestMethod: 'PROPFIND',
    resourcePath: uri.path,
  );
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
