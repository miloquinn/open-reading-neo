import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gbk_codec/gbk_codec.dart';

import '../../utils/fast_gbk_decoder.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import '../services/book_source_network_policy.dart';
import 'source_webview_loader.dart';

enum SourceRequestMethod { get, post }

const sourceDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/124.0.0.0 Safari/537.36';

class SourceRequestTemplate {
  const SourceRequestTemplate({
    required this.url,
    required this.method,
    required this.headers,
    required this.charset,
    this.useWebView = false,
    this.webJs,
    this.webViewHtml,
    this.body,
    this.cookieJarKey,
  });

  final Uri url;
  final SourceRequestMethod method;
  final Map<String, String> headers;
  final String charset;
  final bool useWebView;
  final String? webJs;
  final String? webViewHtml;
  final String? body;
  final String? cookieJarKey;

  static SourceRequestTemplate parse(
    String template, {
    required Uri baseUri,
    Map<String, String> variables = const {},
    Map<String, String> sourceHeaders = const {},
    String? cookieJarKey,
  }) {
    final expanded = _expandVariables(template.trim(), variables);
    if (_unresolvedVariables.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'reading source request contains an unsupported template expression.',
      );
    }
    if (_unsupportedRequestSyntax.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'reading source request uses scripting, which is not supported.',
      );
    }
    if (expanded.isEmpty) {
      throw const BookSourceProtocolException(
        'reading source request URL is empty.',
      );
    }

    var urlText = expanded;
    var options = const <String, dynamic>{};
    final optionsStart = _requestOptionsStart(expanded);
    if (optionsStart >= 0) {
      final candidate = expanded.substring(optionsStart + 1).trim();
      try {
        final decoded = _decodeOptions(candidate);
        if (decoded is! Map) throw const FormatException();
        options = decoded.map((key, value) => MapEntry('$key', value));
        urlText = expanded.substring(0, optionsStart).trim();
      } on FormatException {
        throw const BookSourceProtocolException(
          'reading source request options must be a JSON object.',
        );
      }
    }

    final uri = baseUri.resolve(urlText);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'reading source request targets must use HTTP or HTTPS.',
      );
    }

    final methodText = '${options['method'] ?? 'GET'}'.trim().toUpperCase();
    final method = switch (methodText) {
      'GET' => SourceRequestMethod.get,
      'POST' => SourceRequestMethod.post,
      _ => throw BookSourceProtocolException(
        'Unsupported reading source request method: $methodText.',
      ),
    };
    final body = options['body'];
    if (body != null && body is! String) {
      throw const BookSourceProtocolException(
        'reading source request body must be text.',
      );
    }
    if (method == SourceRequestMethod.get &&
        body is String &&
        body.isNotEmpty) {
      throw const BookSourceProtocolException(
        'GET reading source requests cannot contain a body.',
      );
    }

    final headers = <String, String>{};
    for (final entry in sourceHeaders.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || _forbiddenHeaders.contains(name.toLowerCase())) {
        throw BookSourceProtocolException(
          'reading source request header is not allowed: $name.',
        );
      }
      headers[name] = entry.value;
    }
    final optionHeaders = options['headers'];
    if (optionHeaders != null) {
      Object? normalizedHeaders = optionHeaders;
      if (normalizedHeaders is String) {
        final headerText = normalizedHeaders.trim();
        if (headerText.startsWith('{')) {
          try {
            normalizedHeaders = _decodeOptions(headerText);
          } on FormatException {
            throw const BookSourceProtocolException(
              'Reading source request headers must be valid JSON.',
            );
          }
        } else {
          // Older source exports sometimes put a bare browser identifier in
          // `headers` instead of an object. The reference runtime treats this
          // shorthand as the request User-Agent.
          normalizedHeaders = {'User-Agent': headerText};
        }
      }
      if (normalizedHeaders is! Map) {
        throw const BookSourceProtocolException(
          'reading source request headers must be an object.',
        );
      }
      for (final entry in normalizedHeaders.entries) {
        final name = '${entry.key}'.trim();
        final value = entry.value;
        if (name.isEmpty || value is! String) {
          throw const BookSourceProtocolException(
            'reading source request headers must contain text values.',
          );
        }
        if (_forbiddenHeaders.contains(name.toLowerCase())) {
          throw BookSourceProtocolException(
            'reading source request header is not allowed: $name.',
          );
        }
        headers[name] = value;
      }
    }
    if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent')) {
      // reading source always supplies a browser User-Agent. Dart's default agent is
      // rejected by many book sites before their HTML rules can run.
      headers['User-Agent'] = sourceDefaultUserAgent;
    }
    for (final entry in headers.entries) {
      if (entry.key.contains(RegExp(r'[\r\n]')) ||
          entry.value.contains(RegExp(r'[\r\n]'))) {
        throw const BookSourceProtocolException(
          'reading source request headers cannot contain line breaks.',
        );
      }
      if (entry.key.toLowerCase() == 'host' &&
          !_staticHostHeader.hasMatch(entry.value.trim())) {
        throw const BookSourceProtocolException(
          'reading source Host headers must contain a static host name.',
        );
      }
    }
    final charset = '${options['charset'] ?? 'utf-8'}'.trim().toLowerCase();
    if (!_supportedCharsets.contains(charset)) {
      throw BookSourceProtocolException(
        'Unsupported reading source request charset: $charset.',
      );
    }
    if (method == SourceRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=$charset';
    }
    return SourceRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: charset,
      useWebView:
          options['webView'] == true ||
          '${options['webView']}'.toLowerCase() == 'true',
      webJs: options['webJs'] is String
          ? options['webJs'] as String
          : options['webjs'] is String
          ? options['webjs'] as String
          : null,
      body: body as String?,
      cookieJarKey: cookieJarKey,
    );
  }
}

String resolveSourceRequestUrl(Uri baseUri, String value) {
  final optionsStart = _requestOptionsStart(value);
  final urlText = (optionsStart < 0 ? value : value.substring(0, optionsStart))
      .trim();
  final resolved = baseUri.resolve(urlText).toString();
  if (optionsStart < 0) return resolved;
  return '$resolved${value.substring(optionsStart)}';
}

int _requestOptionsStart(String value) {
  RegExpMatch? last;
  for (final match in RegExp(r',\s*\{').allMatches(value)) {
    last = match;
  }
  return last?.start ?? -1;
}

Object? _decodeOptions(String input) {
  try {
    return jsonDecode(input);
  } on FormatException {
    // Historical source files often use JavaScript-style single-quoted object
    // literals. Normalize only quoted strings and object keys; expressions,
    // functions, comments and other executable syntax remain invalid.
    if (input.contains('`') ||
        input.contains(RegExp(r'\b(function|return|new)\b')) ||
        input.contains('//') ||
        input.contains('/*')) {
      rethrow;
    }
    final buffer = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (escaped) {
        buffer.write(char == '"' && inSingle ? r'\"' : char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        buffer.write(char);
        escaped = true;
        continue;
      }
      if (char == '"' && !inSingle) {
        inDouble = !inDouble;
        buffer.write(char);
        continue;
      }
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
        buffer.write('"');
        continue;
      }
      if (inSingle && char == '"') {
        buffer.write(r'\"');
      } else {
        buffer.write(char);
      }
    }
    if (inSingle) throw const FormatException('Unterminated quoted string.');
    return jsonDecode(buffer.toString());
  }
}

class SourceResponse {
  const SourceResponse({required this.body, required this.finalUri});

  final String body;
  final Uri finalUri;
}

abstract interface class SourceTransport {
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  });
}

class SourceHttpTransport implements SourceTransport {
  SourceHttpTransport({
    Dio? dio,
    this._webViewLoader = const SourceWebViewLoader(),
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _networkPolicy = networkPolicy,
       _dio = dio ?? _createDio(networkPolicy, requestTimeout),
       _systemDio = dio ?? _createDio(null, requestTimeout);

  final Dio _dio;
  final Dio _systemDio;
  final SourceWebViewLoader _webViewLoader;
  final BookSourceNetworkPolicy _networkPolicy;
  final int maxResponseBytes;
  final Duration requestTimeout;
  final Map<String, Map<String, _StoredCookie>> _cookieJars = {};

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

  void close({bool force = true}) {
    _cookieJars.clear();
    _dio.close(force: force);
    if (!identical(_systemDio, _dio)) {
      _systemDio.close(force: force);
    }
  }

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
      final mergedCookies = _mergeCookieHeaders(
        configuredCookie,
        _cookieHeader(request.cookieJarKey, request.url),
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
      _storeBrowserCookies(
        request.cookieJarKey,
        loaded.finalUri,
        loaded.cookieHeader,
      );
      return SourceResponse(body: loaded.body, finalUri: loaded.finalUri);
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
    final redirectCookies = <String, _StoredCookie>{};
    final redirectStates = <String>{};
    final connectionRetries = <Uri, int>{};
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
            resolvedAddresses.any(BookSourceNetworkPolicy.isSyntheticDnsAddress)
            ? _systemDio
            : _dio;
        final cancelToken = CancelToken();
        activeCancelToken = cancelToken;
        String? redirectState;
        try {
          final requestHeaders = Map<String, String>.from(headers);
          final storedCookieHeader = _mergeCookieHeaders(
            _cookieHeader(request.cookieJarKey, current),
            _cookieHeaderFromJar(redirectCookies, current),
          );
          String? configuredCookie;
          requestHeaders.removeWhere((name, value) {
            if (name.toLowerCase() != HttpHeaders.cookieHeader) return false;
            configuredCookie = value;
            return true;
          });
          final mergedCookies = _mergeCookieHeaders(
            configuredCookie,
            storedCookieHeader,
          );
          if (mergedCookies != null) {
            requestHeaders[HttpHeaders.cookieHeader] = mergedCookies;
          }
          redirectState =
              '${method.name}\u0000$current\u0000${mergedCookies ?? ''}';
          if (!redirectStates.add(redirectState)) {
            throw const BookSourceProtocolException(
              'reading source source entered a redirect loop.',
            );
          }
          final response = await requestClient.requestUri<List<int>>(
            current,
            data: method == SourceRequestMethod.post
                ? Uint8List.fromList(_encode(body ?? '', request.charset))
                : null,
            options: Options(
              method: method == SourceRequestMethod.post ? 'POST' : 'GET',
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
          _storeCookiesInJar(redirectCookies, current, response.headers);
          _storeCookies(request.cookieJarKey, current, response.headers);
          if (status < 300) {
            final bytes = response.data ?? const <int>[];
            if (bytes.length > maxResponseBytes) {
              throw BookSourceProtocolException(
                'reading source response exceeds $maxResponseBytes bytes.',
              );
            }
            return SourceResponse(
              body: _decode(bytes, request.charset, response.headers),
              finalUri: current,
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
            throw const BookSourceProtocolException(
              'reading source source redirected too many times.',
            );
          }
          final next = BookSourceNetworkPolicy.redirectTarget(
            current,
            response.headers.value(HttpHeaders.locationHeader),
          );
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
          if (error.response == null &&
              method == SourceRequestMethod.get &&
              retries < 2) {
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

  String? _cookieHeader(String? jarKey, Uri uri) {
    if (jarKey == null) return null;
    return _cookieHeaderFromJar(_cookieJars[jarKey], uri);
  }

  String? _cookieHeaderFromJar(Map<String, _StoredCookie>? jar, Uri uri) {
    if (jar == null || jar.isEmpty) return null;
    final now = DateTime.now().toUtc();
    jar.removeWhere((_, cookie) => cookie.expiresAt?.isBefore(now) ?? false);
    final matching =
        jar.values
            .where((cookie) => cookie.matches(uri))
            .toList(growable: false)
          ..sort(
            (left, right) => right.path.length.compareTo(left.path.length),
          );
    if (matching.isEmpty) return null;
    return matching
        .map((cookie) => '${cookie.cookie.name}=${cookie.cookie.value}')
        .join('; ');
  }

  void _storeCookies(String? jarKey, Uri uri, Headers headers) {
    if (jarKey == null) return;
    _storeCookiesInJar(_cookieJars.putIfAbsent(jarKey, () => {}), uri, headers);
  }

  void _storeCookiesInJar(
    Map<String, _StoredCookie> jar,
    Uri uri,
    Headers headers,
  ) {
    final values = headers[HttpHeaders.setCookieHeader];
    if (values == null || values.isEmpty) return;
    final now = DateTime.now().toUtc();
    for (final value in values) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        final configuredDomain = cookie.domain?.trim().toLowerCase();
        final domain = (configuredDomain == null || configuredDomain.isEmpty)
            ? uri.host.toLowerCase()
            : configuredDomain.replaceFirst(RegExp(r'^\.'), '');
        final hostOnly = configuredDomain == null || configuredDomain.isEmpty;
        if (!_cookieDomainMatches(uri.host, domain, hostOnly: hostOnly)) {
          continue;
        }
        final path = cookie.path?.isNotEmpty == true
            ? cookie.path!
            : _defaultCookiePath(uri.path);
        final id = '$domain\u0000$path\u0000${cookie.name}';
        final expiresAt = cookie.maxAge == null
            ? cookie.expires?.toUtc()
            : now.add(Duration(seconds: cookie.maxAge!));
        if ((cookie.maxAge != null && cookie.maxAge! <= 0) ||
            (expiresAt?.isBefore(now) ?? false)) {
          jar.remove(id);
          continue;
        }
        jar[id] = _StoredCookie(
          cookie: cookie,
          domain: domain,
          path: path,
          hostOnly: hostOnly,
          expiresAt: expiresAt,
        );
      } on FormatException {
        // Ignore one malformed Set-Cookie without discarding the response.
      }
    }
  }

  void _storeBrowserCookies(String? jarKey, Uri uri, String? cookieHeader) {
    if (jarKey == null || cookieHeader == null || cookieHeader.trim().isEmpty) {
      return;
    }
    final jar = _cookieJars.putIfAbsent(jarKey, () => {});
    final domain = uri.host.toLowerCase();
    for (final part in cookieHeader.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      if (name.isEmpty) continue;
      final cookie = Cookie(name, part.substring(separator + 1).trim());
      final id = '$domain\u0000/\u0000$name';
      jar[id] = _StoredCookie(
        cookie: cookie,
        domain: domain,
        path: '/',
        hostOnly: true,
        expiresAt: null,
      );
    }
  }
}

class _StoredCookie {
  const _StoredCookie({
    required this.cookie,
    required this.domain,
    required this.path,
    required this.hostOnly,
    required this.expiresAt,
  });

  final Cookie cookie;
  final String domain;
  final String path;
  final bool hostOnly;
  final DateTime? expiresAt;

  bool matches(Uri uri) {
    if (cookie.secure && uri.scheme != 'https') return false;
    if (!_cookieDomainMatches(uri.host, domain, hostOnly: hostOnly)) {
      return false;
    }
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath.startsWith(path);
  }
}

bool _cookieDomainMatches(
  String host,
  String domain, {
  required bool hostOnly,
}) {
  final normalizedHost = host.toLowerCase();
  if (normalizedHost == domain) return true;
  return !hostOnly && normalizedHost.endsWith('.$domain');
}

String _defaultCookiePath(String requestPath) {
  if (!requestPath.startsWith('/') || requestPath == '/') return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash + 1);
}

String? _mergeCookieHeaders(String? configured, String? stored) {
  final values = <String, String>{};
  for (final header in [configured, stored]) {
    if (header == null) continue;
    for (final part in header.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      if (name.isEmpty) continue;
      values[name] = part.substring(separator + 1).trim();
    }
  }
  if (values.isEmpty) return null;
  return values.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
}

const _supportedCharsets = {'utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030'};
final _unresolvedVariables = RegExp(r'\{\{[^{}]+\}\}');
final _unsupportedRequestSyntax = RegExp(
  r'@js:|<js>|@put:|@get:',
  caseSensitive: false,
);
final _staticHostHeader = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::\d{1,5})?$',
);
const _forbiddenHeaders = {'content-length', 'transfer-encoding'};

String _expandVariables(String input, Map<String, String> variables) {
  final normalized = input.replaceAllMapped(
    RegExp(r'\{\{\s*([^{}]+?)\s*\}([*/]\s*\d+)\}'),
    (match) {
      final value = _evaluateIntegerExpression(
        '(${match.group(1)})${match.group(2)}',
        variables,
      );
      return value == null ? match.group(0)! : '$value';
    },
  );
  final expanded = normalized.replaceAllMapped(
    RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
    (match) {
      final key = match.group(1)!;
      var value = variables[key];
      if (value == null) {
        final calculated = _evaluateIntegerExpression(key, variables);
        if (calculated != null) value = '$calculated';
      }
      if (value == null) return match.group(0)!;
      return Uri.encodeQueryComponent(value);
    },
  );
  final page = int.tryParse(variables['page'] ?? '');
  if (page == null || page < 1) return expanded;
  return expanded.replaceAllMapped(RegExp(r'<([^<>]*)>'), (match) {
    final alternatives = match.group(1)!.split(',');
    if (alternatives.isEmpty) return '';
    final index = page <= alternatives.length
        ? page - 1
        : alternatives.length - 1;
    return alternatives[index].trim();
  });
}

int? _evaluateIntegerExpression(
  String expression,
  Map<String, String> variables,
) {
  if (!RegExp(r'^[\w\s()+\-*/%]+$').hasMatch(expression)) return null;
  final parser = _IntegerExpressionParser(expression, variables);
  final value = parser.parseExpression();
  parser.skipSpaces();
  return parser.atEnd ? value : null;
}

class _IntegerExpressionParser {
  _IntegerExpressionParser(this.input, this.variables);

  final String input;
  final Map<String, String> variables;
  var index = 0;

  bool get atEnd => index >= input.length;

  void skipSpaces() {
    while (!atEnd && input.codeUnitAt(index) <= 32) {
      index++;
    }
  }

  int? parseExpression() {
    var value = _parseTerm();
    if (value == null) return null;
    while (true) {
      skipSpaces();
      if (atEnd || (input[index] != '+' && input[index] != '-')) return value;
      final operator = input[index++];
      final right = _parseTerm();
      if (right == null) return null;
      value = operator == '+' ? value! + right : value! - right;
    }
  }

  int? _parseTerm() {
    var value = _parseFactor();
    if (value == null) return null;
    while (true) {
      skipSpaces();
      if (atEnd || !'*/%'.contains(input[index])) return value;
      final operator = input[index++];
      final right = _parseFactor();
      if (right == null || right == 0 && operator != '*') return null;
      value = switch (operator) {
        '*' => value! * right,
        '/' => value! ~/ right,
        _ => value! % right,
      };
    }
  }

  int? _parseFactor() {
    skipSpaces();
    if (atEnd) return null;
    if (input[index] == '(') {
      index++;
      final value = parseExpression();
      skipSpaces();
      if (atEnd || input[index] != ')') return null;
      index++;
      return value;
    }
    var sign = 1;
    if (input[index] == '+' || input[index] == '-') {
      if (input[index++] == '-') sign = -1;
      skipSpaces();
    }
    final start = index;
    while (!atEnd && RegExp(r'[A-Za-z0-9_]').hasMatch(input[index])) {
      index++;
    }
    if (start == index) return null;
    final token = input.substring(start, index);
    final value = int.tryParse(token) ?? int.tryParse(variables[token] ?? '');
    return value == null ? null : sign * value;
  }
}

List<int> _encode(String value, String charset) {
  if (charset == 'gbk' || charset == 'gb2312') {
    return gbk_bytes.encode(value);
  }
  return utf8.encode(value);
}

String _decode(List<int> bytes, String configured, Headers headers) {
  final contentType = headers
      .value(HttpHeaders.contentTypeHeader)
      ?.toLowerCase();
  final headerCharset = contentType == null
      ? null
      : RegExp(
          r'''charset\s*=\s*["']?([^;"'\s]+)''',
        ).firstMatch(contentType)?.group(1);
  final normalizedHeader = headerCharset?.toLowerCase();
  final charset =
      normalizedHeader != null &&
          (_supportedCharsets.contains(normalizedHeader) ||
              normalizedHeader == 'gb18030')
      ? normalizedHeader
      : configured;
  if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
    final encoded = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return decodeGbkFast(
      encoded,
      lenient: !isLikelyValidGbkByteStream(encoded),
    );
  }
  return utf8.decode(bytes, allowMalformed: true);
}
