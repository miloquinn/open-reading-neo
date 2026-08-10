import 'dart:convert';

import 'source_script_contract.dart';
import 'source_script_network_guard.dart';
import 'source_script_state.dart';

const sourceScriptHostChannel = 'OpenReadingSourceHost';

class SourceScriptBootstrap {
  const SourceScriptBootstrap._();

  static Map<String, Object?> payload(
    String script,
    SourceScriptContext context,
    SourceScriptState state,
  ) {
    final loginInfo = context.loginInfo.isEmpty
        ? state.loginInfo
        : context.loginInfo;
    final loginHeaders = context.loginHeaders.isEmpty
        ? state.loginHeaders
        : context.loginHeaders;
    return <String, Object?>{
      'script': script,
      'sourceId': context.source.stableId,
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
      'sourceVariable': state.variable,
      'sourceValues': state.values,
      'loginInfo': loginInfo,
      'loginHeaders': loginHeaders,
      'sharedScript': context.source.jsLib,
      'state': state.javaState,
      'result': context.result is SourceScriptNetworkResult
          ? {
              '__networkResponse': true,
              ...(context.result as SourceScriptNetworkResult).toJson(),
            }
          : sourceScriptJsonSafe(context.result),
      'baseUrl':
          context.baseUrl?.toString() ?? context.source.baseUri.toString(),
      'variables': context.variables,
      'book': context.book,
      'chapter': context.chapter,
    };
  }

  static String build(Map<String, Object?> payload) {
    // A source's own defensive `try { java.ajax(...) } catch (e) {...}`
    // would otherwise silently swallow the internal marker error this
    // engine throws to request a real (async) network/interaction round
    // trip — see source_script_network_guard.dart.
    final guardedPayload = Map<String, Object?>.from(payload)
      ..['script'] = guardNetworkCatchBlocks('${payload['script'] ?? ''}')
      ..['sharedScript'] = guardNetworkCatchBlocks(
        '${payload['sharedScript'] ?? ''}',
      );
    final encoded = jsonEncode(guardedPayload);
    final sharedFunctionExports = _sharedFunctionExports(
      guardedPayload['sharedScript'],
    );
    return '''
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
    '$sourceScriptHostChannel',
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
    '\\n' + ${jsonEncode(sharedFunctionExports)} +
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
''';
  }

  // Legado exposes shared jsLib functions on the script context object. Keep
  // the library lexically scoped to avoid `let`/`const` collisions between
  // invocations, then export its top-level functions so source code using
  // `this.getToken()` or `this.getVariable()` keeps working.
  static String _sharedFunctionExports(Object? sharedScript) {
    final script = sharedScript is String ? sharedScript : '';
    final names = RegExp(
      r'\bfunction\s+([A-Za-z_$][\w$]*)',
    ).allMatches(script).map((match) => match.group(1)!).toSet();
    return names
        .map(
          (name) =>
              '''
if (typeof $name === "function") {
  var __openReadingOriginal_$name = $name;
  $name = function() {
    return __openReadingOriginal_$name.apply(globalThis, arguments);
  };
  globalThis[${jsonEncode(name)}] = $name;
}''',
        )
        .join('\n');
  }
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
