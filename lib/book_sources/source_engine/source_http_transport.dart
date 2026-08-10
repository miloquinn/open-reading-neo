import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import '../services/book_source_network_policy.dart';
import 'source_cookie_jar.dart';
import 'source_request_template.dart';
import 'source_response.dart';
import 'source_response_codec.dart';
import 'source_transport.dart';
import 'source_webview_loader.dart';

class SourceHttpTransport
    implements
        SourceTransport,
        SourceInteractionTransport,
        SourceCookieTransport,
        SourceClosableTransport {
  SourceHttpTransport({
    Dio? dio,
    Dio? systemDio,
    this._webViewLoader = const SourceWebViewLoader(),
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _networkPolicy = networkPolicy,
       _dio = dio ?? _createDio(networkPolicy, requestTimeout),
       _systemDio = systemDio ?? dio ?? _createDio(null, requestTimeout);

  final Dio _dio;
  final Dio _systemDio;
  final SourceWebViewLoader _webViewLoader;
  final BookSourceNetworkPolicy _networkPolicy;
  final int maxResponseBytes;
  final Duration requestTimeout;
  final SourceCookieJar _cookieJar = SourceCookieJar();

  static Dio _createDio(
    BookSourceNetworkPolicy? policy,
    Duration requestTimeout,
  ) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        sendTimeout: requestTimeout,
      ),
    );
    if (policy != null) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: policy.createPinnedHttpClient,
      );
    }
    return dio;
  }

  @override
  void close({bool force = true}) {
    _cookieJar.clear();
    _dio.close(force: force);
    if (!identical(_systemDio, _dio)) {
      _systemDio.close(force: force);
    }
  }

  @override
  String scriptCookieHeader(String jarKey, Uri uri) =>
      _cookieJar.scriptCookieHeader(jarKey, uri);

  @override
  void setScriptCookies(String jarKey, Uri uri, String cookieHeader) {
    _cookieJar.setScriptCookies(jarKey, uri, cookieHeader);
  }

  @override
  void removeScriptCookies(String jarKey, Uri uri) {
    _cookieJar.removeScriptCookies(jarKey, uri);
  }

  @override
  Future<Uint8List> fetchInteractionBytes({
    required Uri uri,
    required Map<String, String> headers,
    String? cookieJarKey,
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    var current = uri;
    var requestHeaders = Map<String, String>.from(headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      await _networkPolicy.validate(current);
      final outgoing = Map<String, String>.from(requestHeaders);
      String? configuredCookie;
      outgoing.removeWhere((name, value) {
        if (name.toLowerCase() != HttpHeaders.cookieHeader) return false;
        configuredCookie = value;
        return true;
      });
      final cookie = SourceCookieJar.mergeHeaders(
        configuredCookie,
        _cookieJar.header(cookieJarKey, current),
      );
      if (cookie != null) outgoing[HttpHeaders.cookieHeader] = cookie;
      final response = await _dio.getUri<List<int>>(
        current,
        options: Options(
          headers: outgoing,
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
        ),
      );
      _cookieJar.store(cookieJarKey, current, response.headers);
      final status = response.statusCode ?? 0;
      if (status < 300) {
        final bytes = response.data ?? const <int>[];
        if (bytes.length > maxBytes) {
          throw BookSourceProtocolException(
            'Verification image exceeds $maxBytes bytes.',
          );
        }
        return Uint8List.fromList(bytes);
      }
      if (redirects == 5) {
        throw const BookSourceProtocolException(
          'Verification image redirected too many times.',
        );
      }
      final next = BookSourceNetworkPolicy.redirectTarget(
        current,
        response.headers.value(HttpHeaders.locationHeader),
      );
      if (current.authority != next.authority) {
        requestHeaders.removeWhere((name, _) {
          final normalized = name.toLowerCase();
          return normalized == 'authorization' ||
              normalized == HttpHeaders.cookieHeader ||
              normalized == 'host';
        });
      }
      current = next;
    }
    throw const BookSourceProtocolException(
      'Verification image request failed.',
    );
  }

  @override
  Future<void> validateInteractionUri(Uri uri) => _networkPolicy.validate(uri);

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    if (request.useWebView) {
      cancellation?.throwIfCancelled();
      await _networkPolicy.validate(request.url);
      final browserHeaders = Map<String, String>.from(request.headers);
      String? configuredCookie;
      browserHeaders.removeWhere((name, value) {
        if (name.toLowerCase() != HttpHeaders.cookieHeader) return false;
        configuredCookie = value;
        return true;
      });
      final mergedCookies = SourceCookieJar.mergeHeaders(
        configuredCookie,
        _cookieJar.header(request.cookieJarKey, request.url),
      );
      if (mergedCookies != null) {
        browserHeaders[HttpHeaders.cookieHeader] = mergedCookies;
      }
      final loaded = await _webViewLoader.load(
        url: request.url,
        method: request.method.name.toUpperCase(),
        headers: browserHeaders,
        body: request.body,
        webJs: request.webJs,
        html: request.webViewHtml,
      );
      cancellation?.throwIfCancelled();
      await _networkPolicy.validate(loaded.finalUri);
      if (utf8.encode(loaded.body).length > maxResponseBytes) {
        throw BookSourceProtocolException(
          'Reading source response exceeds $maxResponseBytes bytes.',
        );
      }
      _cookieJar.storeBrowserCookies(
        request.cookieJarKey,
        loaded.finalUri,
        loaded.cookieHeader,
      );
      return SourceResponse(
        body: loaded.body,
        finalUri: loaded.finalUri,
        cookies: SourceResponseCodec.cookieMapFromHeader(loaded.cookieHeader),
      );
    }
    const maxRedirects = 20;
    var current = request.url;
    var method = request.method;
    var body = request.body;
    var headers = Map<String, String>.from(request.headers);
    // `enabledCookieJar` controls persistence between top-level source
    // requests. Cookies set while following one redirect chain still belong
    // to that HTTP transaction and must be replayed even when persistence is
    // disabled (for example, CDN/WAF cookies set by an HTTP -> HTTPS redirect).
    final redirectCookies = _cookieJar.createTransientJar();
    final redirectStates = <String>{};
    final redirectHops = <String>[];
    final connectionRetries = <Uri, int>{};
    final systemFallbacks = <Uri>{};
    CancelToken? activeCancelToken;
    void cancelRequest() =>
        activeCancelToken?.cancel('reading source request cancelled.');
    cancellation?.throwIfCancelled();
    cancellation?.addListener(cancelRequest);
    try {
      for (var redirects = 0; redirects <= maxRedirects; redirects++) {
        cancellation?.throwIfCancelled();
        final resolvedAddresses = await _networkPolicy.resolve(current);
        // Virtual-DNS clients route the reserved 198.18.0.0/15 range through
        // a local tunnel. Dart's custom connection factory bypasses part of
        // that system path and can turn valid responses into HTTP 400. Keep
        // pinned sockets for ordinary public DNS, but use the system client
        // for this explicitly allowed synthetic range after validation.
        final requestClient =
            systemFallbacks.contains(current) ||
                resolvedAddresses.any(
                  BookSourceNetworkPolicy.isSyntheticDnsAddress,
                )
            ? _systemDio
            : _dio;
        final cancelToken = CancelToken();
        activeCancelToken = cancelToken;
        String? redirectState;
        try {
          final requestHeaders = Map<String, String>.from(headers);
          final storedCookieHeader = SourceCookieJar.mergeHeaders(
            _cookieJar.header(request.cookieJarKey, current),
            _cookieJar.headerFromJar(redirectCookies, current),
          );
          String? configuredCookie;
          requestHeaders.removeWhere((name, value) {
            if (name.toLowerCase() != HttpHeaders.cookieHeader) return false;
            configuredCookie = value;
            return true;
          });
          final mergedCookies = SourceCookieJar.mergeHeaders(
            configuredCookie,
            storedCookieHeader,
          );
          if (mergedCookies != null) {
            requestHeaders[HttpHeaders.cookieHeader] = mergedCookies;
          }
          redirectState =
              '${method.name}\u0000$current\u0000${mergedCookies ?? ''}';
          if (!redirectStates.add(redirectState)) {
            final sameUrlThroughout =
                redirectHops.isNotEmpty &&
                redirectHops.every((hop) => hop.contains(' $current -> '));
            final explanation = sameUrlThroughout
                ? ' This source keeps redirecting back to the exact same '
                      'address without ever completing — typically an '
                      'anti-bot/challenge response this app cannot solve. '
                      'Try switching this source to a different line/host.'
                : '';
            throw BookSourceProtocolException(
              'reading source source entered a redirect loop:$explanation '
              '${redirectHops.join(' -> ')} -> '
              '${method.name.toUpperCase()} $current (repeats).',
            );
          }
          final response = await requestClient.requestUri<List<int>>(
            current,
            data: method == SourceRequestMethod.post
                ? Uint8List.fromList(
                    SourceResponseCodec.encode(body ?? '', request.charset),
                  )
                : null,
            options: Options(
              method: switch (method) {
                SourceRequestMethod.get => 'GET',
                SourceRequestMethod.head => 'HEAD',
                SourceRequestMethod.post => 'POST',
              },
              headers: requestHeaders,
              responseType: ResponseType.bytes,
              followRedirects: false,
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 400,
            ),
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > maxResponseBytes || total > maxResponseBytes) {
                cancelToken.cancel('Response exceeds $maxResponseBytes bytes.');
              }
            },
          );
          final status = response.statusCode ?? 0;
          _cookieJar.storeInJar(redirectCookies, current, response.headers);
          _cookieJar.store(request.cookieJarKey, current, response.headers);
          if (status < 300) {
            final bytes = response.data ?? const <int>[];
            if (bytes.length > maxResponseBytes) {
              throw BookSourceProtocolException(
                'reading source response exceeds $maxResponseBytes bytes.',
              );
            }
            return SourceResponse(
              body: SourceResponseCodec.decode(
                bytes,
                request.charset,
                response.headers,
              ),
              finalUri: current,
              statusCode: status,
              headers: SourceResponseCodec.responseHeaders(response.headers),
              cookies: SourceResponseCodec.responseCookies(response.headers),
            );
          }
          const redirectStatuses = {
            HttpStatus.movedPermanently,
            HttpStatus.found,
            HttpStatus.seeOther,
            HttpStatus.temporaryRedirect,
            HttpStatus.permanentRedirect,
          };
          if (!redirectStatuses.contains(status)) {
            throw BookSourceProtocolException(
              'Reading source returned HTTP $status.',
            );
          }
          if (redirects == maxRedirects) {
            throw BookSourceProtocolException(
              'reading source source redirected too many times: '
              '${redirectHops.join(' -> ')}.',
            );
          }
          final next = BookSourceNetworkPolicy.redirectTarget(
            current,
            response.headers.value(HttpHeaders.locationHeader),
          );
          redirectHops.add('${method.name.toUpperCase()} $current -> $status');
          if (current.authority != next.authority) {
            headers.removeWhere(
              (name, _) =>
                  name.toLowerCase() == 'host' ||
                  name.toLowerCase() == 'authorization' ||
                  name.toLowerCase() == HttpHeaders.cookieHeader,
            );
          }
          if (status == HttpStatus.seeOther ||
              ((status == HttpStatus.movedPermanently ||
                      status == HttpStatus.found) &&
                  method == SourceRequestMethod.post)) {
            method = SourceRequestMethod.get;
            body = null;
            headers.removeWhere(
              (name, _) => name.toLowerCase() == HttpHeaders.contentTypeHeader,
            );
          }
          current = next;
        } on DioException catch (error) {
          if (CancelToken.isCancel(error)) {
            cancellation?.throwIfCancelled();
            throw BookSourceProtocolException(
              error.message ?? 'reading source request was cancelled.',
            );
          }
          final retries = connectionRetries[current] ?? 0;
          if (error.response?.statusCode == HttpStatus.badRequest &&
              identical(requestClient, _dio) &&
              method != SourceRequestMethod.post &&
              systemFallbacks.add(current)) {
            if (redirectState != null) redirectStates.remove(redirectState);
            redirects--;
            continue;
          }
          // Unlike the HTTP 400 case above, no response at all means the
          // server never confirmed it saw the request, so replaying it
          // (including POST) is not a duplicate-submission risk the way
          // replaying a request that already got a real response would be.
          if (error.response == null && retries < 2) {
            connectionRetries[current] = retries + 1;
            if (redirectState != null) {
              redirectStates.remove(redirectState);
            }
            redirects--;
            await Future<void>.delayed(
              Duration(milliseconds: 150 * (retries + 1)),
            );
            continue;
          }
          throw BookSourceProtocolException(
            error.response?.statusCode == null
                ? 'Could not connect to this reading source.'
                : 'Reading source returned HTTP ${error.response!.statusCode}.',
          );
        }
      }
    } finally {
      cancellation?.removeListener(cancelRequest);
    }
    throw const BookSourceProtocolException(
      'reading source source request failed.',
    );
  }
}
