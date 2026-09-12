import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import '../networking/book_source_network_policy.dart';
import 'source_cookie_jar.dart';
import 'source_browser_session.dart';
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
        SourceBrowserSessionTransport,
        SourceClosableTransport {
  SourceHttpTransport({
    Dio? dio,
    Dio? systemDio,
    this._webViewLoader = const SourceWebViewLoader(),
    SourceBrowserSessionClient browserClient =
        const SourceBrowserSessionClient(),
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 8),
    // Keep the public injection name usable by integration tests.
    // ignore: prefer_initializing_formals
  }) : _browserClient = browserClient,
       _networkPolicy = networkPolicy,
       _dio = dio ?? _createDio(networkPolicy, requestTimeout),
       _systemDio = systemDio ?? dio ?? _createDio(null, requestTimeout);

  final Dio _dio;
  final Dio _systemDio;
  final SourceWebViewLoaderPort _webViewLoader;
  final SourceBrowserSessionClient _browserClient;
  final Map<String, SourceBrowserSession> _browserSessions = {};
  final Map<String, int> _browserRevisions = {};

  @override
  SourceBrowserSession browserSession(String sourceId) =>
      (_browserSessions[sourceId] ?? const SourceBrowserSession()).copyWith(
        cookies: _cookieJar.exportCookies(sourceId),
      );

  @override
  void restoreBrowserSession(String sourceId, SourceBrowserSession session) {
    _browserRevisions[sourceId] = (_browserRevisions[sourceId] ?? 0) + 1;
    _browserSessions[sourceId] = session;
    _cookieJar.restoreCookies(sourceId, session.cookies);
  }

  @override
  void clearBrowserSession(String sourceId) {
    _browserRevisions[sourceId] = (_browserRevisions[sourceId] ?? 0) + 1;
    _browserSessions.remove(sourceId);
    _cookieJar.clearSource(sourceId);
  }

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
    _browserSessions.clear();
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
    final sessionId = request.cookieJarKey;
    final sessionRevision = _browserRevisions[sessionId] ?? 0;
    void checkSession() {
      if (sessionId != null &&
          (_browserRevisions[sessionId] ?? 0) != sessionRevision) {
        throw const BookSourceProtocolException(
          'The website session changed during this request.',
        );
      }
    }

    final syntheticBody = request.syntheticBody;
    if (syntheticBody != null) {
      return SourceResponse(body: syntheticBody, finalUri: request.url);
    }
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
      final sourceId = request.cookieJarKey;
      if (sourceId != null && _browserSessions[sourceId]?.active == true) {
        final revision = _browserRevisions[sourceId] ?? 0;
        final loaded = await _browserClient.load(
          sourceId: sourceId,
          url: request.url,
          headers: browserHeaders,
          session: browserSession(sourceId),
          method: request.method.name.toUpperCase(),
          body: request.body,
          webJs: request.webJs,
          html: request.webViewHtml,
          cancellation: cancellation,
        );
        cancellation?.throwIfCancelled();
        await _networkPolicy.validate(loaded.finalUri);
        if (utf8.encode(loaded.body).length > maxResponseBytes) {
          throw BookSourceProtocolException(
            'Reading source response exceeds $maxResponseBytes bytes.',
          );
        }
        if ((_browserRevisions[sourceId] ?? 0) != revision) {
          throw const BookSourceProtocolException(
            'The website session changed during this request.',
          );
        }
        restoreBrowserSession(sourceId, loaded.session);
        return SourceResponse(
          body: loaded.body,
          finalUri: loaded.finalUri,
          cookies: SourceResponseCodec.cookieMapFromHeader(
            _cookieJar.header(sourceId, loaded.finalUri),
          ),
        );
      }
      final loaded = await _webViewLoader.load(
        url: request.url,
        method: request.method.name.toUpperCase(),
        headers: browserHeaders,
        body: request.body,
        webJs: request.webJs,
        html: request.webViewHtml,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      await _networkPolicy.validate(loaded.finalUri);
      cancellation?.throwIfCancelled();
      if (utf8.encode(loaded.body).length > maxResponseBytes) {
        throw BookSourceProtocolException(
          'Reading source response exceeds $maxResponseBytes bytes.',
        );
      }
      checkSession();
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
    final browserFallbacks = <Uri>{};
    CancelToken? activeCancelToken;
    void cancelRequest() =>
        activeCancelToken?.cancel('reading source request cancelled.');
    cancellation?.throwIfCancelled();
    cancellation?.addListener(cancelRequest);
    try {
      for (var redirects = 0; redirects <= maxRedirects; redirects++) {
        cancellation?.throwIfCancelled();
        final resolvedAddresses = await _networkPolicy.resolve(current);
        // Virtual-DNS clients reserve 198.18.0.0/15 for addresses owned by the
        // platform tunnel. Let the system client keep ownership of that route
        // after the target has passed the explicit synthetic-DNS policy.
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
          final storedCookieHeader = request.cookieJarKey == null
              ? _cookieJar.headerFromJar(redirectCookies, current)
              : _cookieJar.header(request.cookieJarKey, current);
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
          checkSession();
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
          checkSession();
          if (error.response case final Response response) {
            _cookieJar.store(request.cookieJarKey, current, response.headers);
            if (response.statusCode == 401 &&
                sessionId != null &&
                _browserSessions[sessionId]?.active == true) {
              throw const BookSourceProtocolException(
                'The website requires login. Open this source’s login page to sign in again.',
              );
            }
          }
          if (CancelToken.isCancel(error)) {
            cancellation?.throwIfCancelled();
            throw BookSourceProtocolException(
              error.message ?? 'reading source request was cancelled.',
            );
          }
          final retries = connectionRetries[current] ?? 0;
          // A validated pinned address can still be unreachable on a mobile
          // route while Android's system resolver/client can reach another
          // CDN address. Fall back once for idempotent requests when the
          // pinned channel produced no HTTP response at all. Never replay a
          // POST across channels because the remote side may have received it.
          if (error.response == null &&
              identical(requestClient, _dio) &&
              method != SourceRequestMethod.post &&
              systemFallbacks.add(current)) {
            if (redirectState != null) redirectStates.remove(redirectState);
            redirects--;
            continue;
          }
          if (error.response == null &&
              identical(requestClient, _systemDio) &&
              method == SourceRequestMethod.get &&
              browserFallbacks.add(current)) {
            cancellation?.throwIfCancelled();
            await _networkPolicy.validate(current);
            final browserHeaders = Map<String, String>.from(headers);
            final storedCookieHeader = request.cookieJarKey == null
                ? _cookieJar.headerFromJar(redirectCookies, current)
                : _cookieJar.header(request.cookieJarKey, current);
            if (storedCookieHeader != null) {
              browserHeaders[HttpHeaders.cookieHeader] = storedCookieHeader;
            }
            try {
              checkSession();
              if (sessionId != null &&
                  _browserSessions[sessionId]?.active == true) {
                return await send(
                  SourceRequestTemplate(
                    url: current,
                    method: SourceRequestMethod.get,
                    headers: browserHeaders,
                    charset: request.charset,
                    useWebView: true,
                    cookieJarKey: sessionId,
                  ),
                  cancellation: cancellation,
                );
              }
              final loaded = await _webViewLoader.load(
                url: current,
                method: 'GET',
                headers: browserHeaders,
                cancellation: cancellation,
              );
              cancellation?.throwIfCancelled();
              await _networkPolicy.validate(loaded.finalUri);
              cancellation?.throwIfCancelled();
              if (utf8.encode(loaded.body).length > maxResponseBytes) {
                throw BookSourceProtocolException(
                  'Reading source response exceeds $maxResponseBytes bytes.',
                );
              }
              checkSession();
              _cookieJar.storeBrowserCookies(
                request.cookieJarKey,
                loaded.finalUri,
                loaded.cookieHeader,
              );
              return SourceResponse(
                body: loaded.body,
                finalUri: loaded.finalUri,
                cookies: SourceResponseCodec.cookieMapFromHeader(
                  loaded.cookieHeader,
                ),
              );
            } on BookSourceProtocolException {
              // Preserve the normal bounded retry/error path below when the
              // Android browser bridge is unavailable or also cannot load.
            }
          }
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
