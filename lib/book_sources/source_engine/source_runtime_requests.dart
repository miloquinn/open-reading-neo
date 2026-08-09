import 'dart:convert';

import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_concurrency_limiter.dart';
import 'source_config.dart';
import 'source_interaction_coordinator.dart';
import 'source_request_template.dart';
import 'source_response.dart';
import 'source_rule_engine.dart';
import 'source_runtime_dependencies.dart';
import 'source_runtime_login.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';
import 'source_script_contract.dart';
import 'source_transport.dart';

abstract interface class SourceRuntimeRequestPort {
  Future<SourceResponse> request(
    ReadingSourceConfig source,
    String template, {
    Map<String, String> variables,
    BookDownloadCancellation? cancellation,
  });
  Future<SourceResponse> requestReusingBookInfo(
    ReadingSourceConfig source,
    String bookId,
    String target, {
    required Map<String, String> variables,
  });
  SourceRuleDocument document(
    ReadingSourceConfig source,
    SourceResponse response, {
    Map<String, String> variables,
    Map<String, Object?> book,
    Map<String, Object?> chapter,
    Map<String, Object?>? ruleState,
  });
  Future<Map<String, String>> sourceHeaders(ReadingSourceConfig source);
  Future<String> expandScriptTemplate(
    ReadingSourceConfig source,
    String template,
    Map<String, String> variables,
  );
  String cookieHeader(ReadingSourceConfig source, Uri uri);
}

class SourceRuntimeRequests
    implements SourceRuntimeRequestPort, SourceRuntimeScriptContextPort {
  SourceRuntimeRequests({
    required SourceTransport transport,
    required SourceConcurrencyLimiter limiter,
    required SourceRuntimeSessionPort sessions,
    required SourceRuntimeRulePort rules,
    required SourceRuntimeState state,
    required SourceRuntimeTrace trace,
    required SourceScriptEvaluator Function() scripts,
    required SourceInteractionCoordinatorPort interactionCoordinator,
    SourceInteractionTransport? interactionTransport,
  }) : this._(
         transport,
         limiter,
         sessions,
         rules,
         state,
         trace,
         scripts,
         interactionCoordinator,
         interactionTransport,
       );

  SourceRuntimeRequests._(
    this._transport,
    this._limiter,
    this._sessions,
    this._rules,
    this._state,
    this._trace,
    this._scripts,
    this._interactionCoordinator,
    this._interactionTransport,
  );

  final SourceTransport _transport;
  final SourceConcurrencyLimiter _limiter;
  final SourceRuntimeSessionPort _sessions;
  final SourceRuntimeRulePort _rules;
  final SourceRuntimeState _state;
  final SourceRuntimeTrace _trace;
  final SourceScriptEvaluator Function() _scripts;
  final SourceInteractionCoordinatorPort _interactionCoordinator;
  final SourceInteractionTransport? _interactionTransport;

  @override
  Future<SourceResponse> request(
    ReadingSourceConfig source,
    String template, {
    Map<String, String> variables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    await _sessions.ensure(source);
    final expandedTemplate = await expandScriptTemplate(
      source,
      template,
      variables,
    );
    final outgoing = SourceRequestTemplate.parse(
      expandedTemplate,
      baseUri: source.baseUri,
      variables: variables,
      sourceHeaders: await sourceHeaders(source),
      cookieJarKey: source.enabledCookieJar ? source.stableId : null,
    );
    await _limiter.acquire(
      source.stableId,
      source.concurrentRate,
      cancellation: cancellation,
    );
    final stopwatch = _trace.startNetwork();
    try {
      final response = await _transport.send(
        outgoing,
        cancellation: cancellation,
      );
      _trace.networkSuccess(outgoing, response, stopwatch);
      return _applyLoginCheck(source, response);
    } catch (error) {
      _trace.networkFailure(outgoing, error, stopwatch);
      rethrow;
    }
  }

  @override
  Future<SourceResponse> requestReusingBookInfo(
    ReadingSourceConfig source,
    String bookId,
    String target, {
    required Map<String, String> variables,
  }) async {
    if (target == (decodeSourceDataTarget(bookId) ?? bookId)) {
      final cached = _state.takeBookInfoResponse(source, bookId);
      if (cached != null) return cached;
    }
    return request(source, target, variables: variables);
  }

  @override
  SourceRuleDocument document(
    ReadingSourceConfig source,
    SourceResponse response, {
    Map<String, String> variables = const {},
    Map<String, Object?> book = const {},
    Map<String, Object?> chapter = const {},
    Map<String, Object?>? ruleState,
  }) {
    final state = ruleState ?? <String, Object?>{};
    return _rules.document(
      response.body,
      response.finalUri,
      ruleState: state,
      scriptContext: scriptContext(
        source,
        baseUrl: response.finalUri,
        variables: requestVariables(state, variables),
        book: book,
        chapter: chapter,
      ),
    );
  }

  @override
  SourceScriptContext scriptContext(
    ReadingSourceConfig source, {
    Object? result,
    Uri? baseUrl,
    Map<String, String> variables = const {},
    Map<String, Object?> book = const {},
    Map<String, Object?> chapter = const {},
    bool includeSourceHeaders = true,
  }) {
    final loginSession = _sessions.current(source);
    return SourceScriptContext(
      source: source,
      result: result,
      baseUrl: baseUrl,
      variables: variables,
      book: book,
      chapter: chapter,
      networkHandler: (request) => _sendScriptNetwork(
        source,
        request,
        includeSourceHeaders: includeSourceHeaders,
      ),
      cookieReader: (uri) => _sessions.cookieHeader(source, uri),
      cookieWriter: (uri, cookie) => _sessions.setCookies(source, uri, cookie),
      cookieRemover: (uri) => _sessions.removeCookies(source, uri),
      loginInfo: loginSession.loginInfo,
      loginHeaders: loginSession.loginHeaders,
      loginInfoWriter: (value) => _sessions.updateInfo(source, value),
      loginHeaderWriter: (value) => _sessions.updateHeaders(source, value),
      interactionHandler: (request) =>
          _handleScriptInteraction(source, request),
    );
  }

  Future<SourceScriptInteractionResult> _handleScriptInteraction(
    ReadingSourceConfig source,
    SourceScriptInteractionRequest request,
  ) async {
    var target = source.baseUri.resolve(request.url);
    var interaction = request;
    if (request.kind != SourceScriptInteractionKind.verificationCode &&
        request.url.startsWith('data:text/html')) {
      final decoded = _decodeInteractionHtml(request.url);
      if (decoded != null) {
        target = source.baseUri;
        interaction = SourceScriptInteractionRequest(
          signature: request.signature,
          kind: request.kind,
          url: target.toString(),
          title: request.title,
          html: decoded,
          refetchAfterSuccess: request.refetchAfterSuccess,
        );
      }
    }
    final headers = await _interactionHeaders(source, target);
    var prepared = interaction.copyWith(headers: headers);
    await _interactionTransport?.validateInteractionUri(target);
    if (request.kind == SourceScriptInteractionKind.verificationCode) {
      final interactionTransport = _interactionTransport;
      if (interactionTransport == null) {
        return const SourceScriptInteractionResult(
          error:
              'Verification images require the reading source network transport.',
        );
      }
      final bytes = await interactionTransport.fetchInteractionBytes(
        uri: target,
        headers: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      );
      prepared = prepared.copyWith(imageBytes: bytes);
    }
    final result = await _interactionCoordinator.request(
      sourceId: source.stableId,
      sourceName: source.name,
      interaction: prepared,
    );
    final finalUri = Uri.tryParse(result.finalUrl);
    if (finalUri != null) {
      await _interactionTransport?.validateInteractionUri(finalUri);
    }
    if (result.cookieHeader?.trim().isNotEmpty == true &&
        source.enabledCookieJar) {
      if (finalUri != null) {
        _sessions.setCookies(source, finalUri, result.cookieHeader!);
      }
      _sessions.updateHeaders(source, {
        ..._sessions.current(source).loginHeaders,
        'Cookie': result.cookieHeader!,
      });
      await _sessions.flush(source);
    }
    if (request.refetchAfterSuccess &&
        request.kind == SourceScriptInteractionKind.browserAwait &&
        !result.cancelled &&
        result.error == null) {
      final response = await _sendScriptNetwork(
        source,
        SourceScriptNetworkRequest(
          signature: '',
          method: 'GET',
          url: result.finalUrl.isEmpty ? request.url : result.finalUrl,
        ),
      );
      return SourceScriptInteractionResult(
        body: response.body,
        finalUrl: response.finalUrl,
        cookieHeader: result.cookieHeader,
      );
    }
    return result;
  }

  Future<Map<String, String>> _interactionHeaders(
    ReadingSourceConfig source,
    Uri uri,
  ) async {
    await _sessions.ensure(source);
    final headers = <String, String>{..._sessions.current(source).loginHeaders};
    final raw = source.raw['header'];
    Object? decoded = raw;
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = null;
      }
    }
    if (decoded is Map) {
      for (final entry in decoded.entries) {
        if (entry.value is String) {
          headers['${entry.key}'] = _expandSourceHeaderValue(
            entry.value as String,
            source,
          );
        }
      }
    }
    final cookie = _sessions.cookieHeader(source, uri);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return headers;
  }

  Future<SourceResponse> _applyLoginCheck(
    ReadingSourceConfig source,
    SourceResponse response,
  ) async {
    final script = sourceScriptBody(source.loginCheckJs) ?? source.loginCheckJs;
    if (script.isEmpty) return response;
    final result = SourceScriptNetworkResult(
      body: response.body,
      finalUrl: response.finalUri.toString(),
      statusCode: response.statusCode,
      headers: response.headers,
      cookies: response.cookies,
    );
    final checked = await _scripts().evaluateAsync(
      script,
      scriptContext(source, result: result, baseUrl: response.finalUri),
    );
    await _sessions.flush(source);
    if (checked is! Map) return response;
    return SourceResponse(
      body: '${checked['body'] ?? response.body}',
      finalUri:
          Uri.tryParse('${checked['finalUrl'] ?? ''}') ?? response.finalUri,
      statusCode: checked['statusCode'] is num
          ? (checked['statusCode'] as num).toInt()
          : response.statusCode,
      headers: _responseStringMap(checked['headers'], response.headers),
      cookies: _responseStringMap(checked['cookies'], response.cookies),
    );
  }

  @override
  Future<Map<String, String>> sourceHeaders(ReadingSourceConfig source) async {
    await _sessions.ensure(source);
    final raw = source.raw['header'];
    final loginHeaders = _sessions.current(source).loginHeaders;
    if (raw == null || '$raw'.trim().isEmpty) return loginHeaders;
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        final script = sourceScriptBody(raw) ?? 'JSON.stringify(($raw))';
        decoded = await _scripts().evaluateAsync(
          script,
          scriptContext(
            source,
            baseUrl: source.baseUri,
            includeSourceHeaders: false,
          ),
        );
        if (decoded is String) {
          try {
            decoded = jsonDecode(decoded);
          } on FormatException {
            throw const BookSourceProtocolException(
              'Reading source header script must return a JSON object.',
            );
          }
        }
      }
    }
    if (decoded is! Map) {
      throw const BookSourceProtocolException(
        'Compatible source headers must be an object.',
      );
    }
    final headers = <String, String>{};
    for (final entry in decoded.entries) {
      final name = '${entry.key}'.trim();
      if (name.isEmpty || entry.value is! String) {
        throw const BookSourceProtocolException(
          'Compatible source headers must contain text values.',
        );
      }
      headers[name] = _expandSourceHeaderValue(entry.value as String, source);
    }
    headers.addAll(loginHeaders);
    return headers;
  }

  String _expandSourceHeaderValue(String value, ReadingSourceConfig source) {
    final key = source.url;
    final baseKey = key.split('#').first;
    return value
        .replaceAll('{{source.getKey()}}', key)
        .replaceAll('{{source.bookSourceUrl}}', key)
        .replaceAll('{{bookSourceUrl}}', key)
        .replaceAllMapped(
          RegExp(r'\{\{source\.getKey\(\)\.match\([^}]+\}\}'),
          (_) => baseKey,
        )
        .replaceAllMapped(
          RegExp(r'\{\{source\.getVariable\(\).*?\}\}', dotAll: true),
          (_) => key,
        );
  }

  @override
  Future<String> expandScriptTemplate(
    ReadingSourceConfig source,
    String template,
    Map<String, String> variables,
  ) async {
    await _sessions.ensure(source);
    SourceScriptContext context() =>
        scriptContext(source, baseUrl: source.baseUri, variables: variables);
    final trimmed = template.trimLeft();
    final directScript = sourceScriptBody(template);
    if (directScript != null &&
        (trimmed.startsWith('@js:') || trimmed.startsWith('<js>'))) {
      return _scriptText(
        await _scripts().evaluateAsync(directScript, context()),
      );
    }
    var expanded = await _replaceAsync(
      template,
      RegExp(r'<js>(.*?)</js>', caseSensitive: false, dotAll: true),
      (match) async => _scriptText(
        await _scripts().evaluateAsync(match.group(1)!, context()),
      ),
    );
    expanded = await _replaceAsync(
      expanded,
      RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
      (match) async {
        final expression = match.group(1)!.trim();
        if (_isDeclarativeVariable(expression, variables)) {
          return match.group(0)!;
        }
        return _scriptText(
          await _scripts().evaluateAsync(expression, context()),
        );
      },
    );
    return expanded;
  }

  @override
  String cookieHeader(ReadingSourceConfig source, Uri uri) =>
      _sessions.cookieHeader(source, uri);

  Future<SourceScriptNetworkResult> _sendScriptNetwork(
    ReadingSourceConfig source,
    SourceScriptNetworkRequest request, {
    bool includeSourceHeaders = true,
  }) async {
    final method = request.method.toUpperCase();
    if (!const {'GET', 'HEAD', 'POST', 'WEBVIEW'}.contains(method)) {
      throw BookSourceProtocolException(
        'Source script requested unsupported HTTP method $method.',
      );
    }
    final headers = <String, String>{
      if (includeSourceHeaders) ...await sourceHeaders(source),
      ...request.headers,
    };
    await _limiter.acquire(source.stableId, source.concurrentRate);
    final SourceRequestTemplate outgoing;
    if (method == 'WEBVIEW') {
      final baseRequest = SourceRequestTemplate.parse(
        request.url,
        baseUri: source.baseUri,
        sourceHeaders: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      );
      outgoing = SourceRequestTemplate(
        url: baseRequest.url,
        method: SourceRequestMethod.get,
        headers: baseRequest.headers,
        charset: baseRequest.charset,
        useWebView: true,
        webJs: request.webJs,
        webViewHtml: request.body,
        cookieJarKey: baseRequest.cookieJarKey,
      );
    } else {
      var template = request.url;
      if (method == 'POST' || method == 'HEAD') {
        template =
            '$template,${jsonEncode({'method': method, if (method == 'POST') 'body': request.body ?? '', if (headers.isNotEmpty) 'headers': headers})}';
        headers.clear();
      }
      outgoing = SourceRequestTemplate.parse(
        template,
        baseUri: source.baseUri,
        sourceHeaders: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      );
    }
    final stopwatch = _trace.startNetwork();
    try {
      final response = await _transport.send(outgoing);
      _trace.networkSuccess(outgoing, response, stopwatch);
      return SourceScriptNetworkResult(
        body: response.body,
        finalUrl: response.finalUri.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
        cookies: response.cookies,
      );
    } catch (error) {
      _trace.networkFailure(outgoing, error, stopwatch);
      rethrow;
    }
  }
}

Map<String, String> requestVariables(
  Map<String, Object?> state,
  Map<String, String> variables,
) => <String, String>{
  for (final entry in state.entries)
    if (entry.value != null) entry.key: '${entry.value}',
  ...variables,
};

String? decodeSourceDataTarget(String value) {
  final optionsStart = value.lastIndexOf(RegExp(r',\s*\{'));
  final dataPart = optionsStart < 0 ? value : value.substring(0, optionsStart);
  if (!dataPart.startsWith('data:')) return null;
  final comma = dataPart.indexOf(',');
  if (comma < 0) return null;
  final metadata = dataPart.substring(0, comma).toLowerCase();
  final payload = dataPart.substring(comma + 1);
  try {
    final decoded = metadata.contains(';base64')
        ? utf8.decode(base64Decode(payload), allowMalformed: true)
        : Uri.decodeComponent(payload);
    final uri = Uri.tryParse(decoded.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return optionsStart < 0
        ? decoded.trim()
        : '$decoded${value.substring(optionsStart)}';
  } on Object {
    return null;
  }
}

String? _decodeInteractionHtml(String value) {
  final comma = value.indexOf(',');
  if (comma < 0) return null;
  final metadata = value.substring(0, comma).toLowerCase();
  final payload = value.substring(comma + 1);
  try {
    return metadata.contains(';base64')
        ? utf8.decode(base64Decode(payload), allowMalformed: true)
        : Uri.decodeComponent(payload);
  } on Object {
    return null;
  }
}

Map<String, String> _responseStringMap(
  Object? value,
  Map<String, String> fallback,
) {
  if (value is! Map) return fallback;
  return {
    for (final entry in value.entries) '${entry.key}': '${entry.value ?? ''}',
  };
}

Future<String> _replaceAsync(
  String input,
  RegExp pattern,
  Future<String> Function(RegExpMatch match) replacement,
) async {
  final output = StringBuffer();
  var offset = 0;
  for (final match in pattern.allMatches(input)) {
    output.write(input.substring(offset, match.start));
    output.write(await replacement(match));
    offset = match.end;
  }
  output.write(input.substring(offset));
  return output.toString();
}

bool _isDeclarativeVariable(String expression, Map<String, String> variables) {
  if (variables.containsKey(expression)) return true;
  final arithmetic = RegExp(
    r'^([A-Za-z_]\w*)\s*[+-]\s*\d+$',
  ).firstMatch(expression);
  return arithmetic != null && variables.containsKey(arithmetic.group(1));
}

String _scriptText(Object? value) => switch (value) {
  null => '',
  String text => text,
  Map _ || List _ => jsonEncode(value),
  _ => '$value',
};
