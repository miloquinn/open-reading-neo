import 'dart:convert';

import 'source_cookie_utils.dart';
import 'source_rule_engine.dart';
import 'source_script_contract.dart';
import 'source_script_crypto_api.dart';
import 'source_script_dom_api.dart';
import 'source_script_state.dart';
import 'source_script_text_api.dart';

class SourceScriptHostApi {
  SourceScriptHostApi({SourceRuleSelectorPort? selectors})
    : _dom = SourceScriptDomApi(selectors ?? const SourceRuleEngine());

  final SourceScriptDomApi _dom;
  final SourceScriptCryptoApi _crypto = const SourceScriptCryptoApi();
  final SourceScriptTextApi _text = const SourceScriptTextApi();
  final Map<String, SourceScriptState> _sourceStates = {};

  SourceScriptContext? _activeContext;
  Map<String, SourceScriptNetworkResult> _networkResponses = const {};
  Map<String, SourceScriptInteractionResult> _interactionResponses = const {};

  SourceScriptState beginInvocation(
    SourceScriptContext context,
    Map<String, SourceScriptNetworkResult> networkResponses,
    Map<String, SourceScriptInteractionResult> interactionResponses,
  ) {
    _activeContext = context;
    _networkResponses = networkResponses;
    _interactionResponses = interactionResponses;
    return stateFor(context.source.stableId);
  }

  void endInvocation() {
    _activeContext = null;
    _networkResponses = const {};
    _interactionResponses = const {};
  }

  SourceScriptState stateFor(String sourceId) =>
      _sourceStates.putIfAbsent(sourceId, SourceScriptState.new);

  dynamic handle(dynamic message) {
    if (message is! Map) return null;
    final operation = '${message['op'] ?? ''}';
    final arguments = message['args'] is List
        ? message['args'] as List
        : const [];
    return switch (operation) {
      'md5' ||
      'base64Encode' ||
      'base64Decode' ||
      'base64DecodeBytes' ||
      'base64EncodeBytes' ||
      'bytesToUtf8' ||
      'hexDecodeToString' ||
      'aesBase64DecodeToString' ||
      'hmacBase64' ||
      'hmacHex' ||
      'symmetricCrypto' ||
      'randomUUID' ||
      'androidId' ||
      'digestHex' ||
      'digestBytes' ||
      'hmacBytes' => _crypto.handle(operation, arguments),
      'toNumChapter' ||
      'utf8Bytes' ||
      'htmlFormat' ||
      'traditionalToSimplified' ||
      'simplifiedToTraditional' => _text.handle(operation, arguments),
      'getString' ||
      'getStringList' ||
      'getElements' ||
      'removeElements' => _dom.handle(operation, arguments, _activeContext),
      'cookieGet' => _cookieGet(arguments),
      'cookieGetKey' => _cookieGetKey(arguments),
      'cookieSet' => _cookieSet(arguments),
      'cookieRemove' => _cookieRemove(arguments),
      'cachePut' => _cachePut(arguments),
      'cacheGet' => _cacheGet(arguments),
      'cacheDelete' => _cacheDelete(arguments),
      'cachePutMemory' => _cachePutMemory(arguments),
      'cacheGetMemory' => _cacheGetMemory(arguments),
      'cacheDeleteMemory' => _cacheDeleteMemory(arguments),
      'network' => _networkResult(arguments),
      'interaction' => _interactionResult(arguments),
      _ => null,
    };
  }

  String _cookieGet(List arguments) {
    final context = _activeContext;
    if (context?.cookieReader == null || arguments.isEmpty) return '';
    final uri = _cookieUri('${arguments.first ?? ''}', context!);
    return uri == null ? '' : context.cookieReader!(uri);
  }

  String _cookieGetKey(List arguments) {
    if (arguments.length < 2) return '';
    final key = '${arguments[1] ?? ''}'.trim();
    if (key.isEmpty) return '';
    return parseSourceCookieHeader(_cookieGet(arguments))[key] ?? '';
  }

  Object? _cookieSet(List arguments) {
    final context = _activeContext;
    if (context?.cookieWriter == null || arguments.length < 2) return null;
    final uri = _cookieUri('${arguments.first ?? ''}', context!);
    if (uri != null) context.cookieWriter!(uri, '${arguments[1] ?? ''}');
    return null;
  }

  Object? _cookieRemove(List arguments) {
    final context = _activeContext;
    if (context?.cookieRemover == null || arguments.isEmpty) return null;
    final uri = _cookieUri('${arguments.first ?? ''}', context!);
    if (uri != null) context.cookieRemover!(uri);
    return null;
  }

  Object? _cachePut(List arguments) {
    final state = _activeState;
    if (state == null || arguments.length < 2) return null;
    final key = '${arguments[0] ?? ''}';
    if (key.isEmpty) return null;
    final seconds = arguments.length > 2 ? _number(arguments[2]) : 0;
    state.cache[key] = SourceScriptCacheEntry(
      value: arguments[1],
      expiresAt: seconds <= 0
          ? null
          : DateTime.now().add(Duration(seconds: seconds.round())),
    );
    return null;
  }

  Object? _cacheGet(List arguments) {
    final state = _activeState;
    if (state == null || arguments.isEmpty) return null;
    return state.readCache('${arguments.first ?? ''}', DateTime.now());
  }

  Object? _cacheDelete(List arguments) {
    final state = _activeState;
    if (state == null || arguments.isEmpty) return null;
    state.deleteCache('${arguments.first ?? ''}');
    return null;
  }

  Object? _cachePutMemory(List arguments) {
    final state = _activeState;
    if (state == null || arguments.length < 2) return null;
    state.memoryCache['${arguments[0]}'] = arguments[1];
    return null;
  }

  Object? _cacheGetMemory(List arguments) {
    final state = _activeState;
    if (state == null || arguments.isEmpty) return null;
    return sourceScriptJsonSafe(state.memoryCache['${arguments.first}']);
  }

  Object? _cacheDeleteMemory(List arguments) {
    final state = _activeState;
    if (state == null || arguments.isEmpty) return null;
    state.memoryCache.remove('${arguments.first}');
    return null;
  }

  SourceScriptState? get _activeState {
    final sourceId = _activeContext?.source.stableId;
    return sourceId == null ? null : stateFor(sourceId);
  }

  Uri? _cookieUri(String value, SourceScriptContext context) {
    final base = context.baseUrl ?? context.source.baseUri;
    final uri = base.resolve(value.trim().isEmpty ? base.toString() : value);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  Object _networkResult(List arguments) {
    final method = arguments.isEmpty
        ? 'GET'
        : '${arguments[0] ?? 'GET'}'.toUpperCase();
    final url = arguments.length > 1 ? '${arguments[1] ?? ''}' : '';
    final body = arguments.length > 2 && arguments[2] != null
        ? '${arguments[2]}'
        : null;
    final rawHeaders = arguments.length > 3 ? arguments[3] : null;
    final webJs = arguments.length > 4 && arguments[4] != null
        ? '${arguments[4]}'
        : null;
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers['${entry.key}'] = '${entry.value ?? ''}';
      }
    }
    final signature = jsonEncode([method, url, body, headers, webJs]);
    final cached = _networkResponses[signature];
    if (cached != null) return {'cached': true, 'value': cached.toJson()};
    return {
      'cached': false,
      'request': {
        'signature': signature,
        'method': method,
        'url': url,
        'body': body,
        'headers': headers,
        'webJs': webJs,
      },
    };
  }

  Object _interactionResult(List arguments) {
    final kind = arguments.isEmpty ? '' : '${arguments[0] ?? ''}';
    final url = arguments.length > 1 ? '${arguments[1] ?? ''}' : '';
    final title = arguments.length > 2 ? '${arguments[2] ?? ''}' : '';
    final refetch = arguments.length > 3 && arguments[3] == true;
    final html = arguments.length > 4 && arguments[4] != null
        ? '${arguments[4]}'
        : null;
    final signature = jsonEncode([kind, url, title, refetch, html]);
    final cached = _interactionResponses[signature];
    if (cached != null) {
      final value = cached.toJson();
      value['cookies'] = parseSourceCookieHeader(cached.cookieHeader);
      return {'cached': true, 'value': value};
    }
    return {
      'cached': false,
      'request': {
        'signature': signature,
        'kind': kind,
        'url': url,
        'title': title,
        'refetchAfterSuccess': refetch,
        'html': html,
      },
    };
  }
}

SourceScriptNetworkRequest? sourceScriptNetworkRequestFromError(
  String message,
) {
  final match = RegExp(r'__OPEN_READING_NETWORK__([^\s]+)').firstMatch(message);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(Uri.decodeComponent(match.group(1)!));
    if (decoded is! Map) return null;
    final headers = <String, String>{};
    if (decoded['headers'] case final Map rawHeaders) {
      for (final entry in rawHeaders.entries) {
        headers['${entry.key}'] = '${entry.value ?? ''}';
      }
    }
    return SourceScriptNetworkRequest(
      signature: '${decoded['signature'] ?? ''}',
      method: '${decoded['method'] ?? 'GET'}'.toUpperCase(),
      url: '${decoded['url'] ?? ''}',
      body: decoded['body'] == null ? null : '${decoded['body']}',
      headers: headers,
      webJs: decoded['webJs'] == null ? null : '${decoded['webJs']}',
    );
  } on Object {
    return null;
  }
}

SourceScriptInteractionRequest? sourceScriptInteractionRequestFromError(
  String message,
) {
  final match = RegExp(
    r'__OPEN_READING_INTERACTION__([^\s]+)',
  ).firstMatch(message);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(Uri.decodeComponent(match.group(1)!));
    if (decoded is! Map) return null;
    final kind = switch ('${decoded['kind'] ?? ''}') {
      'browser' => SourceScriptInteractionKind.browser,
      'browserAwait' => SourceScriptInteractionKind.browserAwait,
      'verificationCode' => SourceScriptInteractionKind.verificationCode,
      _ => null,
    };
    if (kind == null) return null;
    return SourceScriptInteractionRequest(
      signature: '${decoded['signature'] ?? ''}',
      kind: kind,
      url: '${decoded['url'] ?? ''}',
      title: '${decoded['title'] ?? ''}',
      html: decoded['html'] == null ? null : '${decoded['html']}',
      refetchAfterSuccess: decoded['refetchAfterSuccess'] == true,
    );
  } on Object {
    return null;
  }
}

double _number(Object? value) => switch (value) {
  num number => number.toDouble(),
  _ => double.tryParse('${value ?? ''}') ?? 0,
};
