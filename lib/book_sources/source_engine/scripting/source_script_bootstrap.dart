import 'dart:convert';

import 'source_script_contract.dart';
import 'source_script_java_compatibility.dart';
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
      'browserLocalStorage': context.browserLocalStorage,
      'storageOrigin': (context.baseUrl ?? context.source.baseUri).origin,
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
      'hasBook': context.book.isNotEmpty,
      'hasChapter': context.chapter.isNotEmpty,
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
  const __ruleValues = Object.assign({}, __payload.variables || {});
  let __loginInfo = Object.assign({}, __payload.loginInfo || {});
  let __loginHeaders = Object.assign({}, __payload.loginHeaders || {});
  const __browserLocalStorage = Object.assign(Object.create(null), __payload.browserLocalStorage || {});
  const __storageOrigin = __payload.storageOrigin;
  const __clearedStorageOrigins = new Set();
  function __storage(origin) {
    const key = origin == null ? __storageOrigin : String(origin);
    if (!Object.prototype.hasOwnProperty.call(__browserLocalStorage, key)) {
      __browserLocalStorage[key] = Object.create(null);
    }
    return __browserLocalStorage[key];
  }
  globalThis.localStorage = {
    getItem: (key) => Object.prototype.hasOwnProperty.call(__storage(), String(key))
      ? String(__storage()[String(key)]) : null,
    setItem: (key, value) => { Object.defineProperty(__storage(), String(key), {
      value: String(value), writable: true, enumerable: true, configurable: true
    }); },
    removeItem: (key) => { delete __storage()[String(key)]; },
    clear: () => { __browserLocalStorage[__storageOrigin] = Object.create(null); __clearedStorageOrigins.add(__storageOrigin); },
    key: (index) => Object.keys(__storage())[Number(index)] ?? null,
    get length() { return Object.keys(__storage()).length; }
  };
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
    getLocalStorage: (origin) => __javaMap(__storage(origin)),
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
  const __entity = (prefix, seed, active) => {
    const entity = Object.assign({}, seed || {});
    let variableMap = {};
    if (active && entity.variable != null) {
      if (typeof entity.variable === 'string') {
        try { variableMap = Object.assign({}, JSON.parse(entity.variable) || {}); }
        catch (_) { variableMap = {}; }
      } else {
        variableMap = Object.assign({}, entity.variable || {});
      }
    }
    entity.putVariable = (name, value) => {
      const key = String(name);
      if (active) {
        if (value == null || String(value) === '') delete variableMap[key];
        else variableMap[key] = String(value);
      } else {
        __state[prefix + key] = value;
      }
      return value;
    };
    // The compatible RuleDataInterface.getVariable() contract returns a
    // non-null String,
    // falling back to "" when the key was never set (see
    // RuleDataInterface.kt: `variableMap[key] ?: getBigVariable(key) ?:
    // ""`). Source scripts commonly do `String(book.getVariable(x))` and
    // guard only against the literal "null" a real null would stringify to
    // — never against "undefined", since the compatible contract never
    // produces that. Preserve that behavior so those guards keep working.
    entity.getVariable = (name) => {
      const value = active
        ? variableMap[String(name)]
        : __state[prefix + String(name)];
      return value == null ? '' : String(value);
    };
    entity.setReverseToc = (value) => {
      if (active) entity.reverseToc = value;
      else __state[prefix + 'reverseToc'] = value;
      return value;
    };
    entity.putCustomVariable = (value) => {
      if (active) entity.customVariable = value;
      else __state[prefix + 'customVariable'] = value;
      return value;
    };
    entity.getCustomVariable = () => active
      ? entity.customVariable ?? ''
      : __state[prefix + 'customVariable'] ?? '';
    entity.setUseReplaceRule = (value) => {
      if (active) entity.useReplaceRule = value;
      else __state[prefix + 'useReplaceRule'] = value;
      return value;
    };
    Object.defineProperty(entity, 'variable', {
      get: () => active
        ? JSON.stringify(variableMap)
        : __state[prefix + 'variable'],
      set: (value) => {
        if (!active) {
          __state[prefix + 'variable'] = value;
          return;
        }
        if (typeof value === 'string') {
          try { variableMap = Object.assign({}, JSON.parse(value) || {}); }
          catch (_) { variableMap = {}; }
        } else {
          variableMap = Object.assign({}, value || {});
        }
      },
      enumerable: active
    });
    return entity;
  };
  globalThis.book = __entity('book:', __payload.book || {}, __payload.hasBook);
  globalThis.chapter = __entity('chapter:', __payload.chapter || {}, __payload.hasChapter);
  globalThis.title = globalThis.chapter.title || '';
  globalThis.src = typeof result === 'string' ? result : '';
  globalThis.cookie = {
    getKey: (url, key) => __host('cookieGetKey', [String(url), String(key)]),
    removeCookie: (url) => __host('cookieRemove', [String(url)]),
    getCookie: (url) => __host('cookieGet', [String(url)]),
    setCookie: (url, value) => __host('cookieSet', [String(url), String(value)])
  };
  $sourceScriptJavaCompatibility
  const __responseObject = (response, requestedUrl) => {
    const data = response || {};
    const bodyText = data.body == null ? '' : String(data.body);
    const finalUrl = data.finalUrl || String(requestedUrl || '');
    const responseHeaders = Object.assign({}, data.headers || {});
    const headerValues = Object.fromEntries(Object.entries(responseHeaders).map(([name, value]) => [name.toLowerCase(), value]));
    const header = (name) => headerValues[String(name).toLowerCase()] || '';
    const responseCookies = Object.assign({}, data.cookies || {});
    return {
      body: () => bodyText,
      code: () => Number(data.statusCode || 200),
      statusCode: () => Number(data.statusCode || 200),
      url: () => finalUrl,
      header,
      contentType: () => header('content-type'),
      charset: () => {
        const match = /charset\\s*=\\s*["']?([^;"'\\s]+)/i.exec(header('content-type'));
        return match ? match[1] : null;
      },
      headers: (name) => name === undefined
        ? __javaMap(responseHeaders)
        : header(name),
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
    log: (value) => value,
    toast: () => null,
    longToast: () => null,
    put: (name, value) => {
      const key = String(name);
      if (__payload.hasChapter) globalThis.chapter.putVariable(key, value);
      else if (__payload.hasBook) globalThis.book.putVariable(key, value);
      else {
        __ruleValues[key] = value == null ? '' : String(value);
        __state['rule:' + key] = value;
      }
      return value;
    },
    get: function(name, headers) {
      if (arguments.length > 1) {
        return __responseObject(
          __sourceNetwork('GET', name, null, headers), name
        );
      }
      const key = String(name);
      if (key === 'bookName' && __payload.hasBook) {
        return globalThis.book.name == null ? '' : String(globalThis.book.name);
      }
      if (key === 'title' && __payload.hasChapter) {
        return globalThis.chapter.title == null ? '' : String(globalThis.chapter.title);
      }
      const chapterValue = globalThis.chapter.getVariable(key);
      if (chapterValue !== '') return chapterValue;
      const bookValue = globalThis.book.getVariable(key);
      if (bookValue !== '') return bookValue;
      const ruleValue = Object.prototype.hasOwnProperty.call(__ruleValues, key)
        ? __ruleValues[key]
        : __state['rule:' + key];
      if (ruleValue != null && String(ruleValue) !== '') return String(ruleValue);
      const sourceValue = __sourceValues[key];
      return sourceValue == null ? '' : String(sourceValue);
    },
    getString: (rule, content, isUrl) => {
      const decodeOverload = typeof content === 'boolean' && isUrl === undefined;
      return __host('getString', [
        String(rule == null ? '' : rule),
        content == null || decodeOverload ? globalThis.result : content,
        globalThis.baseUrl,
        Boolean(isUrl),
        decodeOverload ? content : true
      ]);
    },
    getStringList: (rule, content, isUrl) => {
      const values = __host('getStringList', [
        String(rule == null ? '' : rule),
        content == null ? globalThis.result : content,
        globalThis.baseUrl,
        Boolean(isUrl)
      ]);
      return values == null ? null : __javaList(values);
    },
    getElements: (rule, content) => __elements(rule, content === undefined ? globalThis.result : content),
    getElement: (rule, content) => {
      const values = __elements(rule, content === undefined ? globalThis.result : content);
      return values.length ? values[0] : null;
    },
    md5Encode: (value) => __host('md5', [String(value)]),
    md5Encode16: (value) => __host('md5', [String(value)]).substring(8, 24),
    base64Encode: (value, flags) => __host('base64Encode', [String(value), flags]),
    base64Decode: (value, charsetOrFlags) => __host('base64Decode', [String(value), charsetOrFlags]),
    base64DecodeToByteArray: (value, flags) => Array.from(__host('base64DecodeBytes', [String(value), flags]) || []),
    hexDecodeToByteArray: (value) => __host('hexDecodeToBytes', [String(value)]),
    hexEncodeToString: (value) => __host('hexEncodeToString', [String(value)]),
    hexDecodeToString: (value) => __host('hexDecodeToString', [String(value)]),
    aesBase64DecodeToString: (data, key, transformation, iv) => __host(
      'aesBase64DecodeToString',
      [String(data), String(key), String(transformation), iv == null ? '' : String(iv)]
    ),
    aesBase64DecodeToByteArray: (data, keyValue, transformation, ivValue) =>
      __symmetricCrypto(String(transformation), keyValue, ivValue)
        .decrypt(data),
    aesEncodeToBase64String: (data, keyValue, transformation, ivValue) =>
      __symmetricCrypto(String(transformation), keyValue, ivValue)
        .encryptBase64(String(data)),
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
    strToBytes: (value, charset) => Array.from(__host('strToBytes', [String(value), charset || 'UTF-8']) || []),
    htmlFormat: (value) => __host('htmlFormat', [String(value)]),
    t2s: (value) => __host('traditionalToSimplified', [String(value)]),
    s2t: (value) => __host('simplifiedToTraditional', [String(value)]),
    bytesToStr: (value, charset) => __host('bytesToStr', [value, charset || 'UTF-8']),
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
    encodeURI: __urlEncoder.encode,
    decodeURI: __urlDecoder.decode,
    ajax: (url) => {
      const target = Array.isArray(url) ? url[0] : url;
      return __sourceNetwork('GET', target == null ? '' : target, null, null).body || '';
    },
    ajaxAll: (urls) => Array.from(urls || []).map(
      (url) => __responseObject(__sourceNetwork('GET', url, null, null), url)
    ),
    connect: (url, headers) => __responseObject(
      __sourceNetwork('GET', url, null, headers), url
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
  globalThis.java.lang = __package('java.lang');
  globalThis.java.util = __package('java.util');
  globalThis.java.net = __package('java.net');
  globalThis.java.security = __package('java.security');
  globalThis.javax = __package('javax');
  globalThis.android = __package('android');
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
      text: () => __host('htmlText', [outer]),
      toString: () => outer
    };
  };
  globalThis.org = {
    jsoup: { Jsoup: { parse: __jsoupParse, parseBodyFragment: __jsoupParse } }
  };
  __javaClasses['org.jsoup.Jsoup'] = globalThis.org.jsoup.Jsoup;
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
    const value = reply.value || {};
    if (value.browserLocalStorage && !value.cancelled && !value.error) {
      Object.keys(value.browserLocalStorage).forEach(origin => {
        __browserLocalStorage[origin] = Object.assign(Object.create(null), value.browserLocalStorage[origin]);
      });
    }
    return value;
  }
  function __sourceNetwork(method, url, body, headers, webJs) {
    if (typeof headers === 'string') headers = JSON.parse(headers);
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
  const __globals = globalThis;
  const __globalNames = Object.getOwnPropertyNames;
  const __defineGlobal = Object.defineProperty;
  const __globalDescriptors = new Map(__globalNames(__globals).map(
    name => [name, Object.getOwnPropertyDescriptor(__globals, name)]
  ));
  const __program = '(function(__exportShared){\\n' +
    (__payload.sharedScript || '') +
    '\\n' + ${jsonEncode(sharedFunctionExports)} +
    '\\nreturn eval(' + JSON.stringify(__payload.script) + ');\\n})';
  try {
  const __run = (0, eval)(__program);
  let __value = __run((name, value) => {
    __globals[name] = value;
  });
  if (__value === undefined || typeof __value === 'function') __value = '';
  return JSON.stringify({
    value: __value,
    book: globalThis.book,
    chapter: globalThis.chapter,
    sourceVariable: __sourceVariable,
    sourceValues: __sourceValues,
    loginInfo: __loginInfo,
    loginHeaders: __loginHeaders,
    browserLocalStorage: __browserLocalStorage,
    clearedStorageOrigins: Array.from(__clearedStorageOrigins),
    state: __state
  });
  } finally {
    for (const [name, descriptor] of __importedGlobals) {
      if (descriptor) __defineGlobal(__globals, name, descriptor);
      else delete __globals[name];
    }
    for (const name of __globalNames(__globals)) {
      if (!__globalDescriptors.has(name)) delete __globals[name];
    }
    for (const [name, descriptor] of __globalDescriptors) {
      __defineGlobal(__globals, name, descriptor);
    }
  }
})()
''';
  }

  // Compatible source scripts expose shared jsLib functions on the script
  // context object. Keep the library lexically scoped to avoid `let`/`const`
  // collisions between
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
  __exportShared(${jsonEncode(name)}, $name);
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
