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
import 'source_cookie_utils.dart';
import 'source_rule_engine.dart';
import 'source_script_contract.dart';

export 'source_script_contract.dart';

class QuickJsSourceScriptEvaluator implements SourceScriptEvaluator {
  QuickJsSourceScriptEvaluator({JavascriptRuntime? runtime})
    : _runtime = runtime ?? getJavascriptRuntime(xhr: false) {
    _runtime.onMessage(_hostChannel, _handleHostCall);
  }

  static const _hostChannel = 'OpenReadingSourceHost';

  final JavascriptRuntime _runtime;
  final SourceRuleEngine _declarativeRules = const SourceRuleEngine();
  final Map<String, _SourceScriptState> _sourceStates = {};
  SourceScriptContext? _activeContext;
  Map<String, SourceScriptNetworkResult> _activeNetworkResponses = const {};
  Map<String, SourceScriptInteractionResult> _activeInteractionResponses =
      const {};
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
    final networkResponses = <String, SourceScriptNetworkResult>{};
    final interactionResponses = <String, SourceScriptInteractionResult>{};
    var networkCount = 0;
    var interactionCount = 0;
    for (var replayCount = 0; replayCount < 24; replayCount++) {
      try {
        return _evaluateAttempt(
          script,
          context,
          networkResponses,
          interactionResponses,
        );
      } on _SourceNetworkNeeded catch (pending) {
        if (++networkCount > 12) {
          throw const BookSourceProtocolException(
            'Source script exceeded the network request limit.',
          );
        }
        final handler = context.networkHandler;
        if (handler == null) {
          throw const BookSourceProtocolException(
            'This source script requested network access outside a source operation.',
          );
        }
        networkResponses[pending.request.signature] = await handler(
          pending.request,
        );
      } on _SourceInteractionNeeded catch (pending) {
        if (++interactionCount > 4) {
          throw const BookSourceProtocolException(
            'Source script exceeded the user interaction limit.',
          );
        }
        final handler = context.interactionHandler;
        if (handler == null) {
          throw const BookSourceProtocolException(
            'This source requires an interactive verification screen.',
          );
        }
        final result = await handler(pending.request);
        if (result.cancelled) {
          throw const BookSourceProtocolException(
            'Reading source verification was cancelled.',
          );
        }
        if (result.error?.isNotEmpty == true) {
          throw BookSourceProtocolException(result.error!);
        }
        interactionResponses[pending.request.signature] = result;
      }
    }
    throw const BookSourceProtocolException(
      'Source script exceeded the replay limit.',
    );
  }

  Object? _evaluateAttempt(
    String script,
    SourceScriptContext context,
    Map<String, SourceScriptNetworkResult> networkResponses, [
    Map<String, SourceScriptInteractionResult> interactionResponses = const {},
  ]) {
    _activeContext = context;
    _activeNetworkResponses = networkResponses;
    _activeInteractionResponses = interactionResponses;
    final sourceId = context.source.stableId;
    final sourceState = _sourceStates.putIfAbsent(
      sourceId,
      _SourceScriptState.new,
    );
    final loginInfo = context.loginInfo.isEmpty
        ? sourceState.loginInfo
        : context.loginInfo;
    final loginHeaders = context.loginHeaders.isEmpty
        ? sourceState.loginHeaders
        : context.loginHeaders;
    final payload = <String, Object?>{
      'script': script,
      'sourceId': sourceId,
      'sourceKey': context.source.url,
      'sourceUrl': context.source.url,
      'sourceComment': context.source.comment,
      'sourceName': context.source.name,
      'sourceType': context.source.type,
      'sourceHeader': _sourceHeader(context.source.raw['header']),
      'sourceGroup': context.source.group,
      'sourceExploreUrl': context.source.exploreUrl,
      'sourceLoginUrl': '${context.source.raw['loginUrl'] ?? ''}',
      'sourceRules': {
        'ruleSearch': context.source.rule('ruleSearch'),
        'ruleExplore': context.source.rule('ruleExplore'),
        'ruleBookInfo': context.source.rule('ruleBookInfo'),
        'ruleToc': context.source.rule('ruleToc'),
        'ruleContent': context.source.rule('ruleContent'),
      },
      'sourceLastUpdateTime': context.source.lastUpdateTime,
      'sourceVariable': sourceState.variable,
      'sourceValues': sourceState.values,
      'loginInfo': loginInfo,
      'loginHeaders': loginHeaders,
      'sharedScript': context.source.jsLib,
      'state': sourceState.javaState,
      'result': context.result is SourceScriptNetworkResult
          ? {
              '__networkResponse': true,
              ...(context.result as SourceScriptNetworkResult).toJson(),
            }
          : _jsonSafe(context.result),
      'baseUrl':
          context.baseUrl?.toString() ?? context.source.baseUri.toString(),
      'variables': context.variables,
      'book': context.book,
      'chapter': context.chapter,
    };
    final encoded = jsonEncode(payload);
    final evaluated = _runtime.evaluate('''
(() => {
  const __payload = $encoded;
  const __state = Object.assign({}, __payload.state || {});
  const __sourceValues = Object.assign({}, __payload.sourceValues || {});
  let __loginInfo = Object.assign({}, __payload.loginInfo || {});
  let __loginHeaders = Object.assign({}, __payload.loginHeaders || {});
  let __sourceVariable = __payload.sourceVariable || '';
  globalThis.result = __payload.result;
  globalThis.baseUrl = __payload.baseUrl;
  globalThis.key = (__payload.variables || {}).key || '';
  globalThis.page = Number((__payload.variables || {}).page || 1);
  globalThis.source = {
    bookSourceName: __payload.sourceName || '',
    bookSourceType: Number(__payload.sourceType || 0),
    bookSourceUrl: __payload.sourceUrl,
    bookSourceComment: __payload.sourceComment || '',
    bookSourceGroup: __payload.sourceGroup || '',
    lastUpdateTime: Number(__payload.sourceLastUpdateTime || 0),
    exploreUrl: __payload.sourceExploreUrl || '',
    loginUrl: __payload.sourceLoginUrl || '',
    ruleSearch: __payload.sourceRules.ruleSearch || {},
    ruleExplore: __payload.sourceRules.ruleExplore || {},
    ruleBookInfo: __payload.sourceRules.ruleBookInfo || {},
    ruleToc: __payload.sourceRules.ruleToc || {},
    ruleContent: __payload.sourceRules.ruleContent || {},
    header: __javaMap(__payload.sourceHeader || {}),
    key: __payload.sourceKey,
    getKey: () => __payload.sourceKey,
    getVariable: () => __sourceVariable,
    setVariable: (value) => {
      __sourceVariable = value == null ? '' : String(value);
      return value;
    },
    put: (name, value) => {
      __sourceValues[String(name)] = value == null ? '' : String(value);
      return value;
    },
    get: (name) => __sourceValues[String(name)] || '',
    getHeaderMap: () => __javaMap(__payload.sourceHeader || {}),
    getLoginHeader: () => Object.keys(__loginHeaders).length
      ? JSON.stringify(__loginHeaders)
      : '',
    getLoginHeaderMap: () => __javaMap(__loginHeaders),
    putLoginHeader: (value) => {
      if (typeof value === 'string') {
        try { __loginHeaders = Object.assign({}, JSON.parse(value) || {}); }
        catch (_) { __loginHeaders = {}; }
      } else {
        __loginHeaders = Object.assign({}, value || {});
      }
      return value;
    },
    removeLoginHeader: () => { __loginHeaders = {}; return null; },
    getLoginInfo: () => JSON.stringify(__loginInfo),
    getLoginInfoMap: () => __javaMap(__loginInfo),
    putLoginInfo: (value) => {
      if (typeof value === 'string') {
        try { __loginInfo = Object.assign({}, JSON.parse(value) || {}); }
        catch (_) { __loginInfo = {}; }
      } else {
        __loginInfo = Object.assign({}, value || {});
      }
      return value;
    }
  };
  Object.defineProperty(globalThis.source, 'variable', {
    get: () => __sourceVariable,
    set: (value) => { __sourceVariable = value == null ? '' : String(value); }
  });
  globalThis.cache = {
    put: (name, value, seconds) => __host('cachePut', [String(name), value, Number(seconds || 0)]),
    get: (name) => __host('cacheGet', [String(name)]) ?? null,
    delete: (name) => __host('cacheDelete', [String(name)]),
    putMemory: (name, value) => __host('cachePutMemory', [String(name), value]),
    getFromMemory: (name) => __host('cacheGetMemory', [String(name)]) ?? null,
    deleteMemory: (name) => __host('cacheDeleteMemory', [String(name)]),
    putFile: (name, value, seconds) => __host('cachePut', [String(name), value, Number(seconds || 0)]),
    getFile: (name) => __host('cacheGet', [String(name)]) ?? null
  };
  const __host = (op, args) => sendMessage(
    '$_hostChannel',
    JSON.stringify({ sourceId: __payload.sourceId, op, args: args || [] })
  );
  const __pad2 = (value) => String(value).padStart(2, '0');
  function __javaMap(value) {
    const map = Object.assign({}, value || {});
    Object.defineProperties(map, {
      get: { value: (key) => map[String(key)], enumerable: false },
      put: { value: (key, item) => {
        const previous = map[String(key)];
        map[String(key)] = item;
        return previous;
      }, enumerable: false },
      remove: { value: (key) => {
        const previous = map[String(key)];
        delete map[String(key)];
        return previous;
      }, enumerable: false },
      containsKey: { value: (key) => Object.prototype.hasOwnProperty.call(map, String(key)), enumerable: false },
      isEmpty: { value: () => Object.keys(map).length === 0, enumerable: false },
      size: { value: () => Object.keys(map).length, enumerable: false },
      toString: { value: () => JSON.stringify(map), enumerable: false }
    });
    return map;
  }
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
    let currentText = data.text || '';
    let currentHtml = data.html || '';
    let currentOuterHtml = data.outerHtml || '';
    const element = {
      text: () => currentText,
      html: () => currentHtml,
      outerHtml: () => currentOuterHtml,
      attr: (name) => (data.attributes || {})[String(name)] || '',
      select: (rule) => __elements(rule, currentOuterHtml, () => {
        const updated = __host('removeElements', [currentOuterHtml, String(rule)]);
        if (updated) {
          currentText = updated.text || '';
          currentHtml = updated.html || '';
          currentOuterHtml = updated.outerHtml || '';
        }
      }),
      remove: () => element,
      toArray: () => [element],
      toString: () => currentOuterHtml || currentText
    };
    return element;
  };
  const __javaList = (values, onRemove) => {
    const list = Array.from(values || []);
    Object.defineProperties(list, {
      size: { value: () => list.length, enumerable: false },
      get: { value: (index) => list[Number(index)], enumerable: false },
      isEmpty: { value: () => list.length === 0, enumerable: false },
      toArray: { value: () => Array.from(list), enumerable: false },
      first: { value: () => list.length ? list[0] : null, enumerable: false },
      last: { value: () => list.length ? list[list.length - 1] : null, enumerable: false },
      text: { value: () => list.map((item) => item && typeof item.text === 'function' ? item.text() : String(item || '')).join(''), enumerable: false },
      html: { value: () => list.map((item) => item && typeof item.html === 'function' ? item.html() : String(item || '')).join(''), enumerable: false },
      outerHtml: { value: () => list.map((item) => item && typeof item.outerHtml === 'function' ? item.outerHtml() : String(item || '')).join(''), enumerable: false },
      attr: { value: (name) => list.length && list[0] && typeof list[0].attr === 'function' ? list[0].attr(name) : '', enumerable: false },
      select: { value: (rule) => {
        const selected = list
          .filter((item) => item && typeof item.select === 'function')
          .map((item) => item.select(rule));
        return __javaList(
          selected.flatMap((items) => items.toArray()),
          () => selected.forEach((items) => items.remove())
        );
      }, enumerable: false },
      remove: { value: () => {
        if (typeof onRemove === 'function') onRemove();
        list.splice(0, list.length);
        return list;
      }, enumerable: false }
    });
    return list;
  };
  const __elements = (rule, content, onRemove) => {
    const values = __host('getElements', [String(rule), content === undefined ? result : content]) || [];
    return __javaList(Array.from(values).map(__wrapElement), onRemove);
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
    entity.putCustomVariable = (value) => {
      __state[prefix + 'customVariable'] = value;
      return value;
    };
    entity.getCustomVariable = () => __state[prefix + 'customVariable'];
    entity.setUseReplaceRule = (value) => {
      __state[prefix + 'useReplaceRule'] = value;
      return value;
    };
    Object.defineProperty(entity, 'variable', {
      get: () => __state[prefix + 'variable'],
      set: (value) => { __state[prefix + 'variable'] = value; }
    });
    return entity;
  };
  globalThis.book = __entity('book:', __payload.book || {});
  globalThis.chapter = __entity('chapter:', __payload.chapter || {});
  globalThis.title = globalThis.chapter.title || '';
  globalThis.src = typeof result === 'string' ? result : '';
  globalThis.cookie = {
    getKey: (url, key) => __host('cookieGetKey', [String(url), String(key)]),
    removeCookie: (url) => __host('cookieRemove', [String(url)]),
    getCookie: (url) => __host('cookieGet', [String(url)]),
    setCookie: (url, value) => __host('cookieSet', [String(url), String(value)])
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
    const responseHeaders = Object.assign({}, data.headers || {});
    const responseCookies = Object.assign({}, data.cookies || {});
    return {
      body: () => bodyText,
      code: () => Number(data.statusCode || 200),
      statusCode: () => Number(data.statusCode || 200),
      url: () => finalUrl,
      headers: (name) => name === undefined
        ? responseHeaders
        : (responseHeaders[String(name)] || responseHeaders[String(name).toLowerCase()] || ''),
      cookies: () => responseCookies,
      raw: () => ({ request: () => ({ url: () => finalUrl }) }),
      toJSON: () => ({
        body: bodyText,
        finalUrl: finalUrl,
        statusCode: Number(data.statusCode || 200),
        headers: responseHeaders,
        cookies: responseCookies
      }),
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
    getString: (rule, content) => __host('getString', [String(rule), content === undefined ? globalThis.result : content, globalThis.baseUrl]),
    getStringList: (rule, content) => __javaList(__host('getStringList', [String(rule), content === undefined ? globalThis.result : content, globalThis.baseUrl])),
    getElements: (rule, content) => __elements(rule, content === undefined ? globalThis.result : content),
    getElement: (rule, content) => {
      const values = __elements(rule, content === undefined ? globalThis.result : content);
      return values.length ? values[0] : null;
    },
    md5Encode: (value) => __host('md5', [String(value)]),
    md5Encode16: (value) => __host('md5', [String(value)]).substring(8, 24),
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
    androidId: () => __host('androidId', []),
    digestHex: (value, algorithm) => __host(
      'digestHex', [String(value), String(algorithm)]
    ),
    toNumChapter: (value) => __host('toNumChapter', [String(value)]),
    strToBytes: (value) => Array.from(__host('utf8Bytes', [String(value)]) || []),
    htmlFormat: (value) => __host('htmlFormat', [String(value)]),
    t2s: (value) => __host('traditionalToSimplified', [String(value)]),
    s2t: (value) => __host('simplifiedToTraditional', [String(value)]),
    bytesToStr: (value) => __host('bytesToUtf8', [value]),
    getWebViewUA: () => (__payload.sourceHeader || {})['User-Agent'] ||
      (__payload.sourceHeader || {})['user-agent'] ||
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
    desEncodeToBase64String: (data, keyValue, transformation, ivValue) =>
      __symmetricCrypto(String(transformation), keyValue, ivValue)
        .encryptBase64(String(data)),
    getCookie: (url, key) => key === undefined
      ? __host('cookieGet', [String(url)])
      : __host('cookieGetKey', [String(url), String(key)]),
    setContent: (value, url) => {
      globalThis.result = value;
      if (url != null && String(url).trim()) globalThis.baseUrl = String(url);
      return value;
    },
    refreshExplore: () => null,
    refreshBookInfo: () => null,
    refreshContent: () => null,
    refreshTocUrl: () => null,
    refreshBookUrl: () => null,
    initUrl: () => null,
    getStrResponse: () => result,
    webView: (html, url, js) => {
      let target = url == null ? '' : String(url);
      if (html != null && /^\\s*</.test(String(html)) &&
          target && !/^(?:https?:)?\\/\\//i.test(target) && !target.startsWith('/')) {
        target = String(globalThis.baseUrl || __payload.sourceUrl || '');
      }
      if (!target) target = String(globalThis.baseUrl || __payload.sourceUrl || '');
      return __sourceNetwork('WEBVIEW', target, html, null, js).body || '';
    },
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
    ),
    head: (url, headers) => __responseObject(
      __sourceNetwork('HEAD', url, null, headers), url
    ),
    startBrowser: (url, title, html) => {
      const value = __sourceInteraction(
        'browser', url, title, false, html
      );
      return value.finalUrl || '';
    },
    startBrowserAwait: (url, title, refetchAfterSuccess, html) => {
      let shouldRefetch = refetchAfterSuccess;
      let pageHtml = html;
      if (typeof refetchAfterSuccess === 'string' && html === undefined) {
        pageHtml = refetchAfterSuccess;
        shouldRefetch = false;
      }
      const value = __sourceInteraction(
        'browserAwait', url, title, Boolean(shouldRefetch), pageHtml
      );
      return __responseObject({
        body: value.body || '',
        finalUrl: value.finalUrl || String(url || ''),
        statusCode: 200,
        headers: {},
        cookies: value.cookies || {}
      }, url);
    },
    getVerificationCode: (imageUrl) => __sourceInteraction(
      'verificationCode', imageUrl, '', false, null
    ).value || ''
  };
  globalThis.sleep = () => null;
  const __jsoupParse = (value) => {
    let outer = String(value == null ? '' : value);
    return {
      select: (rule) => __elements(rule, outer, () => {
        const updated = __host('removeElements', [outer, String(rule)]);
        if (updated && updated.outerHtml) outer = updated.outerHtml;
      }),
      html: () => outer,
      outerHtml: () => outer,
      text: () => java.htmlFormat(outer),
      toString: () => outer
    };
  };
  globalThis.org = {
    jsoup: { Jsoup: { parse: __jsoupParse, parseBodyFragment: __jsoupParse } }
  };
  globalThis.traditionalToSimplified = (value) => java.t2s(value);
  globalThis.simplifiedToTraditional = (value) => java.s2t(value);
  function __sourceInteraction(kind, url, title, refetchAfterSuccess, html) {
    let targetUrl = String(url == null ? '' : url);
    let pageHtml = html == null ? null : String(html);
    if (!pageHtml && /^\\s*</.test(targetUrl)) {
      pageHtml = targetUrl;
      targetUrl = String(globalThis.baseUrl || __payload.sourceUrl || '');
    }
    const reply = __host('interaction', [
      kind,
      targetUrl,
      title == null ? '' : String(title),
      Boolean(refetchAfterSuccess),
      pageHtml
    ]);
    if (!reply || reply.cached !== true) {
      const request = reply && reply.request ? reply.request : {
        signature: JSON.stringify([
          kind,
          targetUrl,
          title == null ? '' : String(title),
          Boolean(refetchAfterSuccess),
          pageHtml
        ]),
        kind: kind,
        url: targetUrl,
        title: title == null ? '' : String(title),
        refetchAfterSuccess: Boolean(refetchAfterSuccess),
        html: pageHtml
      };
      throw new Error('__OPEN_READING_INTERACTION__' +
        encodeURIComponent(JSON.stringify(request)));
    }
    return reply.value || {};
  }
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
  if (__payload.result && __payload.result.__networkResponse === true) {
    globalThis.result = __responseObject(__payload.result, __payload.result.finalUrl);
  }
  const __program = '(function(){\\n' +
    (__payload.sharedScript || '') +
    '\\nreturn eval(' + JSON.stringify(__payload.script) + ');\\n})()';
  let __value = (0, eval)(__program);
  if (__value === undefined || typeof __value === 'function') __value = '';
  return JSON.stringify({
    value: __value,
    book: globalThis.book,
    chapter: globalThis.chapter,
    sourceVariable: __sourceVariable,
    sourceValues: __sourceValues,
    loginInfo: __loginInfo,
    loginHeaders: __loginHeaders,
    state: __state
  });
})()
''');
    if (evaluated.isError) {
      final pending = _networkRequestFromError(evaluated.stringResult);
      if (pending != null) throw _SourceNetworkNeeded(pending);
      final interaction = _interactionRequestFromError(evaluated.stringResult);
      if (interaction != null) throw _SourceInteractionNeeded(interaction);
      throw BookSourceProtocolException(
        'Reading source JavaScript failed: ${evaluated.stringResult}',
      );
    }
    try {
      final envelope = jsonDecode(evaluated.stringResult);
      if (envelope is! Map) {
        throw const FormatException('Script result envelope is not an object.');
      }
      sourceState.variable = '${envelope['sourceVariable'] ?? ''}';
      final sourceValues = envelope['sourceValues'];
      if (sourceValues is Map) {
        sourceState.values = sourceValues.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
      }
      final loginInfo = envelope['loginInfo'];
      if (loginInfo is Map) {
        final normalized = loginInfo.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
        if (context.loginInfoWriter != null) {
          context.loginInfoWriter!(normalized);
        } else {
          sourceState.loginInfo = normalized;
        }
      }
      final loginHeaders = envelope['loginHeaders'];
      if (loginHeaders is Map) {
        final normalized = loginHeaders.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        );
        if (context.loginHeaderWriter != null) {
          context.loginHeaderWriter!(normalized);
        } else {
          sourceState.loginHeaders = normalized;
        }
      }
      final state = envelope['state'];
      if (state is Map) {
        sourceState.javaState = state.map(
          (key, value) => MapEntry('$key', value),
        );
      }
      final book = envelope['book'];
      if (book is Map && context.bookWriter != null) {
        context.bookWriter!(book.map((key, value) => MapEntry('$key', value)));
      }
      final chapter = envelope['chapter'];
      if (chapter is Map && context.chapterWriter != null) {
        context.chapterWriter!(
          chapter.map((key, value) => MapEntry('$key', value)),
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
      'androidId' => _androidId(),
      'digestHex' => _digestHex(arguments),
      'digestBytes' => _digestBytes(arguments),
      'hmacBytes' => _hmacBytes(arguments),
      'toNumChapter' => _toNumChapter(value),
      'utf8Bytes' => List<int>.from(utf8.encode(value)),
      'htmlFormat' => html_parser.parseFragment(value).text ?? '',
      'traditionalToSimplified' => _traditionalToSimplified(value),
      'simplifiedToTraditional' => _simplifiedToTraditional(value),
      'getString' => _selectWithRule(arguments, listMode: false),
      'getStringList' => _selectWithRule(arguments, listMode: true),
      'getElements' => _selectElements(arguments),
      'removeElements' => _removeElements(arguments),
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
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.length < 2) return null;
    final key = '${arguments[0] ?? ''}';
    if (key.isEmpty) return null;
    final seconds = arguments.length > 2 ? _number(arguments[2]) : 0;
    sourceState.cache[key] = _ScriptCacheEntry(
      value: arguments[1],
      expiresAt: seconds <= 0
          ? null
          : DateTime.now().add(Duration(seconds: seconds.round())),
    );
    return null;
  }

  Object? _cacheGet(List arguments) {
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.isEmpty) return null;
    final key = '${arguments.first ?? ''}';
    final entry = sourceState.cache[key];
    if (entry == null) return null;
    if (entry.expiresAt?.isBefore(DateTime.now()) ?? false) {
      sourceState.cache.remove(key);
      return null;
    }
    return _jsonSafe(entry.value);
  }

  Object? _cacheDelete(List arguments) {
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.isEmpty) return null;
    final key = '${arguments.first ?? ''}';
    sourceState.cache.remove(key);
    sourceState.memoryCache.remove(key);
    return null;
  }

  Object? _cachePutMemory(List arguments) {
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.length < 2) return null;
    sourceState.memoryCache['${arguments[0]}'] = arguments[1];
    return null;
  }

  Object? _cacheGetMemory(List arguments) {
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.isEmpty) return null;
    return _jsonSafe(sourceState.memoryCache['${arguments.first}']);
  }

  Object? _cacheDeleteMemory(List arguments) {
    final sourceState = _activeSourceState;
    if (sourceState == null || arguments.isEmpty) return null;
    sourceState.memoryCache.remove('${arguments.first}');
    return null;
  }

  _SourceScriptState? get _activeSourceState {
    final sourceId = _activeContext?.source.stableId;
    if (sourceId == null) return null;
    return _sourceStates.putIfAbsent(sourceId, _SourceScriptState.new);
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

  Object _interactionResult(List arguments) {
    final kind = arguments.isEmpty ? '' : '${arguments[0] ?? ''}';
    final url = arguments.length > 1 ? '${arguments[1] ?? ''}' : '';
    final title = arguments.length > 2 ? '${arguments[2] ?? ''}' : '';
    final refetch = arguments.length > 3 && arguments[3] == true;
    final html = arguments.length > 4 && arguments[4] != null
        ? '${arguments[4]}'
        : null;
    final signature = jsonEncode([kind, url, title, refetch, html]);
    final cached = _activeInteractionResponses[signature];
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

  Map<String, String> _removeElements(List arguments) {
    if (arguments.length < 2) return const {};
    final body = '${arguments.first ?? ''}';
    final selector = '${arguments[1] ?? ''}'.trim();
    if (body.isEmpty || selector.isEmpty) return const {};
    final document = html_parser.parse(body);
    for (final element in document.querySelectorAll(selector)) {
      element.remove();
    }
    final root = document.documentElement;
    return {
      'text': document.body?.text ?? document.text ?? '',
      'html': document.body?.innerHtml ?? root?.innerHtml ?? '',
      'outerHtml': root?.outerHtml ?? '',
    };
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

SourceScriptInteractionRequest? _interactionRequestFromError(String message) {
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

class _SourceNetworkNeeded implements Exception {
  const _SourceNetworkNeeded(this.request);

  final SourceScriptNetworkRequest request;
}

class _SourceInteractionNeeded implements Exception {
  const _SourceInteractionNeeded(this.request);

  final SourceScriptInteractionRequest request;
}

class _ScriptCacheEntry {
  const _ScriptCacheEntry({required this.value, this.expiresAt});

  final Object? value;
  final DateTime? expiresAt;
}

class _SourceScriptState {
  String variable = '';
  Map<String, String> values = {};
  Map<String, String> loginInfo = {};
  Map<String, String> loginHeaders = {};
  Map<String, Object?> javaState = {};
  final Map<String, _ScriptCacheEntry> cache = {};
  final Map<String, Object?> memoryCache = {};
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

String _traditionalToSimplified(String value) =>
    _translateCharacters(value, _traditionalSimplifiedMap);

String _simplifiedToTraditional(String value) =>
    _translateCharacters(value, _simplifiedTraditionalMap);

String _translateCharacters(String value, Map<int, int> mapping) {
  if (value.isEmpty) return value;
  final output = StringBuffer();
  for (final rune in value.runes) {
    output.writeCharCode(mapping[rune] ?? rune);
  }
  return output.toString();
}

// Keep the built-in conversion deliberately small and deterministic. Sources
// mainly use it for labels and category names; content parsing must not depend
// on a locale-specific system service.
const _traditionalSimplifiedPairs = <String>[
  '萬万',
  '與与',
  '專专',
  '業业',
  '東东',
  '絲丝',
  '兩两',
  '為为',
  '這这',
  '個个',
  '們们',
  '來来',
  '國国',
  '學学',
  '習习',
  '書书',
  '體体',
  '發发',
  '現现',
  '會会',
  '應应',
  '該该',
  '號号',
  '處处',
  '門门',
  '開开',
  '關关',
  '問问',
  '題题',
  '說说',
  '話话',
  '讀读',
  '寫写',
  '進进',
  '過过',
  '還还',
  '選选',
  '擇择',
  '頁页',
  '類类',
  '別别',
  '圖图',
  '標标',
  '籤签',
  '網网',
  '頁页',
  '線线',
  '經经',
  '驗验',
  '證证',
  '碼码',
  '樂乐',
  '歡欢',
  '愛爱',
  '戀恋',
  '廣广',
  '東东',
  '臺台',
  '灣湾',
  '門门',
  '漢汉',
  '語语',
  '簡简',
  '繁繁',
  '轉转',
  '換换',
  '優优',
  '劣劣',
  '機机',
  '動动',
  '靜静',
  '訊讯',
  '息息',
  '時时',
  '間间',
  '長长',
  '短短',
  '頭头',
  '聽听',
  '見见',
  '覺觉',
  '點点',
  '擊击',
  '標标',
  '題题',
  '數数',
  '據据',
  '從从',
  '無无',
  '與与',
  '將将',
  '後后',
  '裡里',
  '別别',
  '麼么',
  '們们',
  '創创',
  '建建',
  '導导',
  '覽览',
  '級级',
  '線线',
  '線线',
  '畫画',
  '報报',
  '導导',
  '權权',
  '限限',
  '錯错',
  '誤误',
  '載载',
  '入入',
  '輸输',
  '出出',
  '實实',
  '際际',
  '聯联',
  '絡络',
  '標标',
  '準准',
  '體体',
  '驗验',
  '認认',
  '識识',
  '獲获',
  '取取',
  '細细',
  '節节',
  '點点',
  '擊击',
  '後后',
  '臺台',
  '館馆',
  '專专',
  '區区',
  '頁页',
  '冊册',
  '冊册',
  '乾干',
  '兒儿',
  '畫画',
  '麗丽',
  '潔洁',
  '壓压',
  '縮缩',
  '慾欲',
  '與与',
  '將将',
  '製制',
  '作作',
  '廣广',
  '場场',
  '夢梦',
  '韓韩',
  '熱热',
  '劇剧',
  '誘诱',
  '亂乱',
  '倫伦',
  '學学',
  '姊姐',
  '師师',
  '護护',
  '醫医',
  '辦办',
  '強强',
  '獄狱',
  '勵励',
  '靈灵',
  '懸悬',
  '慾欲',
  '戲戏',
  '職职',
  '恢恢',
  '聲声',
  '雙双',
  '分分',
  '類类',
  '篩筛',
  '條条',
];

final Map<int, int> _traditionalSimplifiedMap = {
  for (final pair in _traditionalSimplifiedPairs)
    pair.runes.first: pair.runes.last,
};

final Map<int, int> _simplifiedTraditionalMap = {
  for (final entry in _traditionalSimplifiedMap.entries) entry.value: entry.key,
};

double _number(Object? value) => switch (value) {
  num number => number.toDouble(),
  _ => double.tryParse('${value ?? ''}') ?? 0,
};

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

String _androidId() => sha256
    .convert(utf8.encode('open-reading-source-runtime'))
    .toString()
    .substring(0, 16);

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
