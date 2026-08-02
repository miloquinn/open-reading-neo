import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/export.dart' hide Digest;

import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_rule_engine.dart';

class SourceScriptContext {
  const SourceScriptContext({
    required this.source,
    this.result,
    this.baseUrl,
    this.variables = const {},
    this.networkHandler,
  });

  final ReadingSourceConfig source;
  final Object? result;
  final Uri? baseUrl;
  final Map<String, String> variables;
  final Future<SourceScriptNetworkResult> Function(
    SourceScriptNetworkRequest request,
  )?
  networkHandler;
}

class SourceScriptNetworkResult {
  const SourceScriptNetworkResult({required this.body, required this.finalUrl});

  final String body;
  final String finalUrl;

  Map<String, Object?> toJson() => {'body': body, 'finalUrl': finalUrl};
}

class SourceScriptNetworkRequest {
  const SourceScriptNetworkRequest({
    required this.signature,
    required this.method,
    required this.url,
    this.body,
    this.headers = const {},
    this.webJs,
  });

  final String signature;
  final String method;
  final String url;
  final String? body;
  final Map<String, String> headers;
  final String? webJs;
}

abstract class SourceScriptEvaluator {
  Object? evaluate(String script, SourceScriptContext context);

  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  void dispose();
}

class QuickJsSourceScriptEvaluator implements SourceScriptEvaluator {
  QuickJsSourceScriptEvaluator({JavascriptRuntime? runtime})
    : _runtime = runtime ?? getJavascriptRuntime(xhr: false) {
    _runtime.onMessage(_hostChannel, _handleHostCall);
  }

  static const _hostChannel = 'OpenReadingSourceHost';

  final JavascriptRuntime _runtime;
  final SourceRuleEngine _declarativeRules = const SourceRuleEngine();
  final Map<String, String> _sourceVariables = {};
  final Map<String, Map<String, Object?>> _sourceState = {};
  SourceScriptContext? _activeContext;
  Map<String, SourceScriptNetworkResult> _activeNetworkResponses = const {};
  Future<void> _evaluationTail = Future<void>.value();

  @override
  Object? evaluate(String script, SourceScriptContext context) {
    return _evaluateAttempt(script, context, const {});
  }

  @override
  Future<Object?> evaluateAsync(String script, SourceScriptContext context) {
    final previous = _evaluationTail;
    final operation = () async {
      try {
        await previous;
      } on Object {
        // A failed script must not poison the queue for later sources.
      }
      return _evaluateAsyncLocked(script, context);
    }();
    _evaluationTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<Object?> _evaluateAsyncLocked(
    String script,
    SourceScriptContext context,
  ) async {
    final responses = <String, SourceScriptNetworkResult>{};
    for (var requestCount = 0; requestCount < 12; requestCount++) {
      try {
        return _evaluateAttempt(script, context, responses);
      } on _SourceNetworkNeeded catch (pending) {
        final handler = context.networkHandler;
        if (handler == null) {
          throw const BookSourceProtocolException(
            'This source script requested network access outside a source operation.',
          );
        }
        responses[pending.request.signature] = await handler(pending.request);
      }
    }
    throw const BookSourceProtocolException(
      'Source script exceeded the network request limit.',
    );
  }

  Object? _evaluateAttempt(
    String script,
    SourceScriptContext context,
    Map<String, SourceScriptNetworkResult> networkResponses,
  ) {
    _activeContext = context;
    _activeNetworkResponses = networkResponses;
    final sourceId = context.source.stableId;
    final payload = <String, Object?>{
      'script': script,
      'sourceId': sourceId,
      'sourceKey': context.source.url,
      'sourceUrl': context.source.url,
      'sourceComment': context.source.comment,
      'sourceHeader': _sourceHeader(context.source.raw['header']),
      'sourceVariable': _sourceVariables[sourceId] ?? '',
      'state': _sourceState[sourceId] ?? const <String, Object?>{},
      'result': _jsonSafe(context.result),
      'baseUrl':
          context.baseUrl?.toString() ?? context.source.baseUri.toString(),
      'variables': context.variables,
    };
    final encoded = jsonEncode(payload);
    final evaluated = _runtime.evaluate('''
(() => {
  const __payload = $encoded;
  const __state = Object.assign({}, __payload.state || {});
  let __sourceVariable = __payload.sourceVariable || '';
  globalThis.result = __payload.result;
  globalThis.baseUrl = __payload.baseUrl;
  globalThis.key = (__payload.variables || {}).key || '';
  globalThis.page = Number((__payload.variables || {}).page || 1);
  globalThis.source = {
    bookSourceUrl: __payload.sourceUrl,
    bookSourceComment: __payload.sourceComment || '',
    header: __payload.sourceHeader || {},
    key: __payload.sourceKey,
    getKey: () => __payload.sourceKey,
    getVariable: () => __sourceVariable,
    setVariable: (value) => {
      __sourceVariable = value == null ? '' : String(value);
      return value;
    },
    getHeaderMap: () => __payload.sourceHeader || {},
    getLoginHeader: () => '',
    getLoginHeaderMap: () => ({}),
    putLoginHeader: () => null,
    removeLoginHeader: () => null,
    getLoginInfoMap: () => ({})
  };
  Object.defineProperty(globalThis.source, 'variable', {
    get: () => __sourceVariable,
    set: (value) => { __sourceVariable = value == null ? '' : String(value); }
  });
  const __host = (op, args) => sendMessage(
    '$_hostChannel',
    JSON.stringify({ sourceId: __payload.sourceId, op, args: args || [] })
  );
  const __pad2 = (value) => String(value).padStart(2, '0');
  const __formatDate = (time, format, offset) => {
    const date = new Date(Number(time) + Number(offset || 0));
    const utc = offset !== undefined;
    const parts = {
      yyyy: utc ? date.getUTCFullYear() : date.getFullYear(),
      MM: __pad2((utc ? date.getUTCMonth() : date.getMonth()) + 1),
      dd: __pad2(utc ? date.getUTCDate() : date.getDate()),
      HH: __pad2(utc ? date.getUTCHours() : date.getHours()),
      mm: __pad2(utc ? date.getUTCMinutes() : date.getMinutes()),
      ss: __pad2(utc ? date.getUTCSeconds() : date.getSeconds())
    };
    return String(format || 'yyyy/MM/dd HH:mm').replace(
      /yyyy|MM|dd|HH|mm|ss/g,
      (token) => parts[token]
    );
  };
  const __wrapElement = (data) => {
    if (!data || data.__element !== true) return data;
    const element = {
      text: () => data.text || '',
      html: () => data.html || '',
      outerHtml: () => data.outerHtml || '',
      attr: (name) => (data.attributes || {})[String(name)] || '',
      select: (rule) => __elements(rule, data.outerHtml || ''),
      toArray: () => [element],
      toString: () => data.outerHtml || data.text || ''
    };
    return element;
  };
  const __elements = (rule, content) => {
    const values = __host('getElements', [String(rule), content === undefined ? result : content]) || [];
    return Array.from(values).map(__wrapElement);
  };
  const __entity = (prefix, seed) => {
    const entity = Object.assign({}, seed || {});
    entity.putVariable = (name, value) => {
      __state[prefix + String(name)] = value;
      return value;
    };
    entity.getVariable = (name) => __state[prefix + String(name)];
    entity.setReverseToc = (value) => {
      __state[prefix + 'reverseToc'] = value;
      return value;
    };
    Object.defineProperty(entity, 'variable', {
      get: () => __state[prefix + 'variable'],
      set: (value) => { __state[prefix + 'variable'] = value; }
    });
    return entity;
  };
  globalThis.book = __entity('book:', __payload.variables || {});
  globalThis.chapter = __entity('chapter:', __payload.variables || {});
  globalThis.cookie = {
    getKey: () => __payload.sourceKey,
    removeCookie: () => null,
    getCookie: () => '',
    setCookie: () => null
  };
  const __symmetricCrypto = (transformation, keyValue, ivValue) => ({
    decrypt: (data) => Array.from(__host('symmetricCrypto', [
      'decryptBytes', transformation, keyValue, ivValue, data
    ]) || []),
    decryptStr: (data) => __host('symmetricCrypto', [
      'decryptString', transformation, keyValue, ivValue, data
    ]),
    encrypt: (data) => Array.from(__host('symmetricCrypto', [
      'encryptBytes', transformation, keyValue, ivValue, data
    ]) || []),
    encryptBase64: (data) => __host('symmetricCrypto', [
      'encryptBase64', transformation, keyValue, ivValue, data
    ]),
    encryptHex: (data) => __host('symmetricCrypto', [
      'encryptHex', transformation, keyValue, ivValue, data
    ])
  });
  if (!String.prototype.getBytes) {
    Object.defineProperty(String.prototype, 'getBytes', {
      value: function() { return Array.from(__host('utf8Bytes', [String(this)]) || []); },
      enumerable: false
    });
  }
  const __Base64 = {
    NO_WRAP: 2,
    DEFAULT: 0,
    decode: (value) => Array.from(__host('base64DecodeBytes', [String(value)]) || []),
    encodeToString: (value) => __host('base64EncodeBytes', [value]),
    getDecoder: () => ({
      decode: (value) => Array.from(__host('base64DecodeBytes', [String(value)]) || [])
    }),
    getEncoder: () => ({
      encodeToString: (value) => __host('base64EncodeBytes', [value])
    })
  };
  const __SecretKeySpec = function(bytes, algorithm) {
    return { bytes: Array.from(bytes || []), algorithm: String(algorithm || '') };
  };
  const __IvParameterSpec = function(bytes) {
    return { bytes: Array.from(bytes || []) };
  };
  const __Cipher = {
    ENCRYPT_MODE: 1,
    DECRYPT_MODE: 2,
    getInstance: (transformation) => {
      let mode = 2;
      let keySpec = { bytes: [] };
      let ivSpec = { bytes: [] };
      return {
        init: (nextMode, nextKey, nextIv) => {
          mode = Number(nextMode);
          keySpec = nextKey || keySpec;
          ivSpec = nextIv || ivSpec;
        },
        doFinal: (data) => {
          const operation = mode === 1 ? 'encryptBytes' : 'decryptBytes';
          return Array.from(__host('symmetricCrypto', [
            operation,
            String(transformation),
            keySpec.bytes || keySpec,
            ivSpec.bytes || ivSpec,
            data
          ]) || []);
        }
      };
    }
  };
  const __Mac = {
    getInstance: (algorithm) => {
      let keySpec = { bytes: [] };
      return {
        init: (nextKey) => { keySpec = nextKey || keySpec; },
        doFinal: (data) => Array.from(__host('hmacBytes', [
          data, String(algorithm), keySpec.bytes || keySpec
        ]) || [])
      };
    }
  };
  const __MessageDigest = {
    getInstance: (algorithm) => ({
      digest: (data) => Array.from(__host('digestBytes', [data, String(algorithm)]) || [])
    })
  };
  const __JavaString = (value) => Array.isArray(value)
    ? __host('bytesToUtf8', [value])
    : String(value == null ? '' : value);
  const __javaImports = {
    String: __JavaString,
    Base64: __Base64,
    SecretKeySpec: __SecretKeySpec,
    IvParameterSpec: __IvParameterSpec,
    Cipher: __Cipher,
    Mac: __Mac,
    MessageDigest: __MessageDigest
  };
  globalThis.JavaImporter = function() {
    return Object.assign({ importPackage: () => null }, __javaImports);
  };
  const __packageProxy = new Proxy({}, {
    get: (target, name) => name in __javaImports ? __javaImports[name] : __packageProxy
  });
  globalThis.Packages = __packageProxy;
  if (!Array.prototype.toArray) {
    Object.defineProperty(Array.prototype, 'toArray', {
      value: function() { return Array.from(this); }, enumerable: false
    });
  }
  const __responseObject = (response, requestedUrl) => {
    const data = response || {};
    const bodyText = data.body == null ? '' : String(data.body);
    const finalUrl = data.finalUrl || String(requestedUrl || '');
    return {
      body: () => bodyText,
      code: () => 200,
      url: () => finalUrl,
      headers: () => ({}),
      cookies: () => ({}),
      raw: () => ({ request: () => ({ url: () => finalUrl }) }),
      valueOf: () => bodyText,
      toString: () => bodyText
    };
  };
  globalThis.java = {
    log: () => null,
    toast: () => null,
    longToast: () => null,
    put: (name, value) => { __state[String(name)] = value; return value; },
    get: function(name, headers) {
      if (arguments.length > 1) {
        return __responseObject(
          __sourceNetwork('GET', name, null, headers), name
        );
      }
      return __state[String(name)];
    },
    getString: (rule, content) => __host('getString', [String(rule), content === undefined ? result : content]),
    getStringList: (rule, content) => __host('getStringList', [String(rule), content === undefined ? result : content]),
    getElements: (rule, content) => __elements(rule, content),
    getElement: (rule, content) => {
      const values = __elements(rule, content);
      return values.length ? values[0] : null;
    },
    md5Encode: (value) => __host('md5', [String(value)]),
    base64Encode: (value) => __host('base64Encode', [String(value)]),
    base64Decode: (value) => __host('base64Decode', [String(value)]),
    base64DecodeToByteArray: (value) => Array.from(__host('base64DecodeBytes', [String(value)]) || []),
    hexDecodeToString: (value) => __host('hexDecodeToString', [String(value)]),
    aesBase64DecodeToString: (data, key, transformation, iv) => __host(
      'aesBase64DecodeToString',
      [String(data), String(key), String(transformation), iv == null ? '' : String(iv)]
    ),
    HMacBase64: (data, algorithm, key) => __host(
      'hmacBase64', [String(data), String(algorithm), String(key)]
    ),
    HMacHex: (data, algorithm, key) => __host(
      'hmacHex', [String(data), String(algorithm), String(key)]
    ),
    createSymmetricCrypto: (transformation, keyValue, ivValue) =>
      __symmetricCrypto(String(transformation), keyValue, ivValue),
    timeFormat: (time) => __formatDate(time, 'yyyy/MM/dd HH:mm'),
    timeFormatUTC: (time, format, offset) => __formatDate(time, format, offset),
    randomUUID: () => __host('randomUUID', []),
    digestHex: (value, algorithm) => __host(
      'digestHex', [String(value), String(algorithm)]
    ),
    toNumChapter: (value) => __host('toNumChapter', [String(value)]),
    strToBytes: (value) => Array.from(__host('utf8Bytes', [String(value)]) || []),
    htmlFormat: (value) => __host('htmlFormat', [String(value)]),
    desEncodeToBase64String: (data, keyValue, transformation, ivValue) =>
      __symmetricCrypto(String(transformation), keyValue, ivValue)
        .encryptBase64(String(data)),
    getCookie: () => '',
    setContent: (value) => { globalThis.result = value; return value; },
    refreshTocUrl: () => null,
    refreshBookUrl: () => null,
    initUrl: () => null,
    getStrResponse: () => String(result == null ? '' : result),
    webView: (html, url, js) => (__sourceNetwork(
      'WEBVIEW', url, html, null, js
    ).body || ''),
    encodeURI: (value) => encodeURIComponent(String(value)),
    decodeURI: (value) => decodeURIComponent(String(value)),
    ajax: (url) => (__sourceNetwork('GET', url, null, null).body || ''),
    ajaxAll: (urls) => Array.from(urls || []).map(
      (url) => __responseObject(__sourceNetwork('GET', url, null, null), url)
    ),
    connect: (url) => __responseObject(
      __sourceNetwork('GET', url, null, null), url
    ),
    post: (url, body, headers) => __responseObject(
      __sourceNetwork('POST', url, body, headers), url
    )
  };
  function __sourceNetwork(method, url, body, headers, webJs) {
    const reply = __host('network', [method, String(url), body, headers, webJs]);
    if (!reply || reply.cached !== true) {
      const request = reply && reply.request ? reply.request : {
        method: method,
        url: String(url),
        body: body == null ? null : String(body),
        headers: headers || {},
        webJs: webJs == null ? null : String(webJs)
      };
      throw new Error('__OPEN_READING_NETWORK__' +
        encodeURIComponent(JSON.stringify(request)));
    }
    return reply.value || { body: '', finalUrl: String(url) };
  }
  let __value = (0, eval)(__payload.script);
  if (__value === undefined || typeof __value === 'function') __value = '';
  return JSON.stringify({
    value: __value,
    sourceVariable: __sourceVariable,
    state: __state
  });
})()
''');
    if (evaluated.isError) {
      final pending = _networkRequestFromError(evaluated.stringResult);
      if (pending != null) throw _SourceNetworkNeeded(pending);
      throw BookSourceProtocolException(
        'Reading source JavaScript failed: ${evaluated.stringResult}',
      );
    }
    try {
      final envelope = jsonDecode(evaluated.stringResult);
      if (envelope is! Map) {
        throw const FormatException('Script result envelope is not an object.');
      }
      _sourceVariables[sourceId] = '${envelope['sourceVariable'] ?? ''}';
      final state = envelope['state'];
      if (state is Map) {
        _sourceState[sourceId] = state.map(
          (key, value) => MapEntry('$key', value),
        );
      }
      return envelope['value'];
    } on FormatException catch (error) {
      throw BookSourceProtocolException(
        'Reading source JavaScript returned invalid data: ${error.message}',
      );
    }
  }

  dynamic _handleHostCall(dynamic message) {
    if (message is! Map) return null;
    final operation = '${message['op'] ?? ''}';
    final arguments = message['args'] is List
        ? message['args'] as List
        : const [];
    final value = arguments.isEmpty ? '' : '${arguments.first ?? ''}';
    return switch (operation) {
      'md5' => md5.convert(utf8.encode(value)).toString(),
      'base64Encode' => base64Encode(utf8.encode(value)),
      'base64Decode' => utf8.decode(base64Decode(value), allowMalformed: true),
      'base64DecodeBytes' => List<int>.from(base64Decode(value)),
      'base64EncodeBytes' => base64Encode(_argumentBytes(arguments)),
      'bytesToUtf8' => utf8.decode(
        _argumentBytes(arguments),
        allowMalformed: true,
      ),
      'hexDecodeToString' => _hexDecode(value),
      'aesBase64DecodeToString' => _aesBase64Decode(arguments),
      'hmacBase64' => _hmac(arguments, base64Output: true),
      'hmacHex' => _hmac(arguments, base64Output: false),
      'symmetricCrypto' => _symmetricCrypto(arguments),
      'randomUUID' => _randomUuid(),
      'digestHex' => _digestHex(arguments),
      'digestBytes' => _digestBytes(arguments),
      'hmacBytes' => _hmacBytes(arguments),
      'toNumChapter' => _toNumChapter(value),
      'utf8Bytes' => List<int>.from(utf8.encode(value)),
      'htmlFormat' => html_parser.parseFragment(value).text ?? '',
      'getString' => _selectWithRule(arguments, listMode: false),
      'getStringList' => _selectWithRule(arguments, listMode: true),
      'getElements' => _selectElements(arguments),
      'network' => _networkResult(arguments),
      _ => null,
    };
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
    final cached = _activeNetworkResponses[signature];
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

  Object? _selectWithRule(List arguments, {required bool listMode}) {
    final context = _activeContext;
    if (context == null || arguments.isEmpty) return listMode ? const [] : '';
    final rule = '${arguments.first ?? ''}';
    final content = arguments.length > 1 ? arguments[1] : context.result;
    final body = switch (content) {
      String text => text,
      Map _ || List _ => jsonEncode(content),
      null => '',
      _ => '$content',
    };
    final document = SourceRuleDocument.parse(
      body,
      context.baseUrl ?? context.source.baseUri,
    );
    if (!listMode) {
      return _declarativeRules.evaluateString(document, document.value, rule);
    }
    return _declarativeRules
        .evaluateList(document, document.value, rule)
        .map((item) {
          if (item is String || item is num || item is bool) return '$item';
          if (item is Map || item is List) return jsonEncode(item);
          return '$item';
        })
        .toList(growable: false);
  }

  List<Object?> _selectElements(List arguments) {
    final context = _activeContext;
    if (context == null || arguments.isEmpty) return const [];
    final rule = '${arguments.first ?? ''}';
    final content = arguments.length > 1 ? arguments[1] : context.result;
    final body = switch (content) {
      String text => text,
      Map _ || List _ => jsonEncode(content),
      null => '',
      _ => '$content',
    };
    final document = SourceRuleDocument.parse(
      body,
      context.baseUrl ?? context.source.baseUri,
    );
    return _declarativeRules
        .evaluateList(document, document.value, rule)
        .map((item) {
          if (item is Element) {
            return <String, Object?>{
              '__element': true,
              'text': item.text,
              'html': item.innerHtml,
              'outerHtml': item.outerHtml,
              'attributes': item.attributes.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            };
          }
          return _jsonSafe(item);
        })
        .toList(growable: false);
  }

  @override
  void dispose() => _runtime.dispose();
}

SourceScriptNetworkRequest? _networkRequestFromError(String message) {
  final match = RegExp(r'__OPEN_READING_NETWORK__([^\s]+)').firstMatch(message);
  if (match == null) return null;
  try {
    final decoded = jsonDecode(Uri.decodeComponent(match.group(1)!));
    if (decoded is! Map) return null;
    final rawHeaders = decoded['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
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

class _SourceNetworkNeeded implements Exception {
  const _SourceNetworkNeeded(this.request);

  final SourceScriptNetworkRequest request;
}

Object? _jsonSafe(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', _jsonSafe(item)));
  }
  if (value is Iterable) return value.map(_jsonSafe).toList(growable: false);
  return '$value';
}

Object _sourceHeader(Object? raw) {
  if (raw is Map) {
    return raw.map((key, value) => MapEntry('$key', '$value'));
  }
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', '$value'));
      }
    } on FormatException {
      return const <String, String>{};
    }
  }
  return const <String, String>{};
}

String _hexDecode(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), '');
  if (normalized.length.isOdd) return '';
  try {
    final bytes = <int>[
      for (var index = 0; index < normalized.length; index += 2)
        int.parse(normalized.substring(index, index + 2), radix: 16),
    ];
    return utf8.decode(bytes, allowMalformed: true);
  } on FormatException {
    return '';
  }
}

String _randomUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

String _digestHex(List arguments) {
  if (arguments.isEmpty) return '';
  final value = utf8.encode('${arguments[0] ?? ''}');
  final algorithm = arguments.length > 1
      ? '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '')
      : 'sha256';
  return _digestFor(algorithm, value)?.toString() ?? '';
}

List<int> _digestBytes(List arguments) {
  if (arguments.isEmpty) return const [];
  final value = _scriptBytes(arguments[0]);
  final algorithm = arguments.length > 1
      ? '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '')
      : 'sha256';
  return _digestFor(algorithm, value)?.bytes ?? const [];
}

Digest? _digestFor(String algorithm, List<int> value) => switch (algorithm) {
  'md5' => md5.convert(value),
  'sha1' => sha1.convert(value),
  'sha224' => sha224.convert(value),
  'sha256' => sha256.convert(value),
  'sha384' => sha384.convert(value),
  'sha512' => sha512.convert(value),
  _ => null,
};

List<int> _hmacBytes(List arguments) {
  if (arguments.length < 3) return const [];
  final data = _scriptBytes(arguments[0]);
  final algorithm = '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '');
  final key = _scriptBytes(arguments[2]);
  final digest = switch (algorithm) {
    'hmacmd5' || 'md5' => Hmac(md5, key).convert(data),
    'hmacsha1' || 'sha1' => Hmac(sha1, key).convert(data),
    'hmacsha256' || 'sha256' => Hmac(sha256, key).convert(data),
    'hmacsha512' || 'sha512' => Hmac(sha512, key).convert(data),
    _ => null,
  };
  return digest?.bytes ?? const [];
}

List<int> _argumentBytes(List arguments) =>
    arguments.isEmpty ? const [] : _scriptBytes(arguments.first);

String _toNumChapter(String input) {
  final match = RegExp(r'[零〇一二两三四五六七八九十百千万亿]+').firstMatch(input);
  if (match == null) return input;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const smallUnits = {'十': 10, '百': 100, '千': 1000};
  const largeUnits = {'万': 10000, '亿': 100000000};
  var total = 0;
  var section = 0;
  var number = 0;
  for (final rune in match.group(0)!.runes) {
    final char = String.fromCharCode(rune);
    if (digits.containsKey(char)) {
      number = digits[char]!;
    } else if (smallUnits.containsKey(char)) {
      section += (number == 0 ? 1 : number) * smallUnits[char]!;
      number = 0;
    } else if (largeUnits.containsKey(char)) {
      total += (section + number) * largeUnits[char]!;
      section = 0;
      number = 0;
    }
  }
  final converted = total + section + number;
  return input.replaceRange(match.start, match.end, '$converted');
}

String _aesBase64Decode(List arguments) {
  if (arguments.length < 3) return '';
  try {
    final encrypted = Uint8List.fromList(base64Decode('${arguments[0] ?? ''}'));
    final key = Uint8List.fromList(utf8.encode('${arguments[1] ?? ''}'));
    final transformation = '${arguments[2] ?? 'AES/CBC/PKCS5Padding'}'
        .toUpperCase();
    final iv = arguments.length > 3
        ? Uint8List.fromList(utf8.encode('${arguments[3] ?? ''}'))
        : Uint8List(16);
    final ecb = transformation.contains('/ECB/');
    final padded =
        transformation.contains('PKCS5') || transformation.contains('PKCS7');
    Uint8List decrypted;
    if (padded) {
      final cipher = PaddedBlockCipher(ecb ? 'AES/ECB/PKCS7' : 'AES/CBC/PKCS7');
      final parameters = ecb
          ? KeyParameter(key)
          : ParametersWithIV<KeyParameter>(KeyParameter(key), iv);
      cipher.init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
          parameters,
          null,
        ),
      );
      decrypted = cipher.process(encrypted);
    } else {
      final cipher = BlockCipher(ecb ? 'AES/ECB' : 'AES/CBC');
      cipher.init(
        false,
        ecb
            ? KeyParameter(key)
            : ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
      );
      decrypted = Uint8List(encrypted.length);
      for (var offset = 0; offset < encrypted.length; offset += 16) {
        cipher.processBlock(encrypted, offset, decrypted, offset);
      }
      if (transformation.contains('ZEROPADDING')) {
        var length = decrypted.length;
        while (length > 0 && decrypted[length - 1] == 0) {
          length--;
        }
        decrypted = Uint8List.sublistView(decrypted, 0, length);
      }
    }
    return utf8.decode(decrypted, allowMalformed: true);
  } on Object {
    return '';
  }
}

String _hmac(List arguments, {required bool base64Output}) {
  if (arguments.length < 3) return '';
  final data = utf8.encode('${arguments[0] ?? ''}');
  final algorithm = '${arguments[1] ?? ''}'.toLowerCase();
  final key = utf8.encode('${arguments[2] ?? ''}');
  final digest = switch (algorithm.replaceAll('-', '')) {
    'hmacmd5' || 'md5' => Hmac(md5, key).convert(data),
    'hmacsha1' || 'sha1' => Hmac(sha1, key).convert(data),
    'hmacsha256' || 'sha256' => Hmac(sha256, key).convert(data),
    'hmacsha512' || 'sha512' => Hmac(sha512, key).convert(data),
    _ => null,
  };
  if (digest == null) return '';
  return base64Output ? base64Encode(digest.bytes) : digest.toString();
}

Object _symmetricCrypto(List arguments) {
  if (arguments.length < 5) return '';
  final operation = '${arguments[0] ?? ''}';
  final transformation = '${arguments[1] ?? ''}';
  final key = _scriptBytes(arguments[2]);
  final iv = _scriptBytes(arguments[3]);
  final encrypting = operation.startsWith('encrypt');
  final input = encrypting
      ? _scriptBytes(arguments[4])
      : _encryptedScriptBytes(arguments[4]);
  try {
    final output = _processSymmetric(
      input,
      key: key,
      iv: iv,
      transformation: transformation,
      encrypting: encrypting,
    );
    return switch (operation) {
      'decryptBytes' || 'encryptBytes' => output.toList(growable: false),
      'decryptString' => utf8.decode(output, allowMalformed: true),
      'encryptBase64' => base64Encode(output),
      'encryptHex' =>
        output.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      _ => '',
    };
  } on Object {
    return operation.endsWith('Bytes') ? const <int>[] : '';
  }
}

Uint8List _processSymmetric(
  Uint8List input, {
  required Uint8List key,
  required Uint8List iv,
  required String transformation,
  required bool encrypting,
}) {
  final normalized = transformation.toUpperCase();
  late final BlockCipher engine;
  var effectiveKey = key;
  if (normalized.startsWith('DESEDE') || normalized.startsWith('TRIPLEDES')) {
    engine = DESedeEngine();
  } else if (normalized.startsWith('DES')) {
    // A single DES key is equivalent to 3DES with K1=K2=K3.
    engine = DESedeEngine();
    effectiveKey = Uint8List.fromList([...key, ...key, ...key]);
  } else {
    engine = AESEngine();
  }
  final blockSize = engine.blockSize;
  final blockCipher = normalized.contains('/ECB/')
      ? engine
      : CBCBlockCipher(engine);
  final baseParameters = KeyParameter(effectiveKey);
  final parameters = normalized.contains('/ECB/')
      ? baseParameters
      : ParametersWithIV<KeyParameter>(
          baseParameters,
          iv.isEmpty ? Uint8List(blockSize) : iv,
        );
  if (normalized.contains('PKCS5') || normalized.contains('PKCS7')) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), blockCipher);
    cipher.init(
      encrypting,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
        parameters,
        null,
      ),
    );
    return cipher.process(input);
  }
  var data = input;
  if (encrypting && data.length % blockSize != 0) {
    final paddedLength =
        ((data.length + blockSize - 1) ~/ blockSize) * blockSize;
    final padded = Uint8List(paddedLength)..setAll(0, data);
    data = padded;
  }
  if (data.length % blockSize != 0) {
    throw const FormatException('Encrypted data is not block aligned.');
  }
  blockCipher.init(encrypting, parameters);
  var output = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += blockSize) {
    blockCipher.processBlock(data, offset, output, offset);
  }
  if (!encrypting && normalized.contains('ZEROPADDING')) {
    var length = output.length;
    while (length > 0 && output[length - 1] == 0) {
      length--;
    }
    output = Uint8List.sublistView(output, 0, length);
  }
  return output;
}

Uint8List _scriptBytes(Object? value) {
  if (value is List) {
    return Uint8List.fromList(
      value.whereType<num>().map((item) => item.toInt() & 0xff).toList(),
    );
  }
  return Uint8List.fromList(utf8.encode('${value ?? ''}'));
}

Uint8List _encryptedScriptBytes(Object? value) {
  if (value is List) return _scriptBytes(value);
  final text = '${value ?? ''}'.trim();
  try {
    return Uint8List.fromList(base64Decode(text));
  } on FormatException {
    if (text.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
      return Uint8List.fromList([
        for (var index = 0; index < text.length; index += 2)
          int.parse(text.substring(index, index + 2), radix: 16),
      ]);
    }
    return _scriptBytes(text);
  }
}
