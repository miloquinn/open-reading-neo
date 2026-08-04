# Reading source compatibility audit

> Offline structural audit. It does not execute scripts, contact sites, or expose auth values.

Parsed **4139** sources from **3** files; duplicates: **12**; parse errors: **1**; invalid/empty URLs: **65**.

## Files

| File | Sources | Invalid URLs | Supported | Partial | Unsupported |
|---|---:|---:|---:|---:|---:|
| (5月10日更新）小合集141个.json | 141 | 4 | 54 | 74 | 13 |
| (6月4日更新）特殊书源小合集.json | 62 | 4 | 16 | 21 | 25 |
| shareBookSource.json | 3936 | 57 | 2273 | 1378 | 285 |

## Core reading chain

**3547 / 4139 (85.7%)** sources have a text type, valid HTTP(S) URL, search entry, catalog rules, and content rules. This is an offline structural readiness rate, not a live-site success rate.

## Feature dependency totals

| Feature | Sources | Open Reading status |
|---|---:|---|
| `regex` | 3312 | supported |
| `css` | 2936 | supported |
| `javascript` | 2126 | supported-native |
| `cookie` | 1622 | supported-session |
| `post` | 1206 | supported |
| `jsonpath` | 820 | supported |
| `state` | 628 | supported-subset |
| `login` | 600 | partial |
| `xpath` | 418 | supported-subset |
| `java_dom` | 339 | supported-subset |
| `webview` | 276 | supported-android |
| `crypto` | 224 | supported-subset |
| `browser_interaction` | 86 | unsupported |
| `shared_script` | 30 | supported-inline |
| `cache_api` | 22 | supported-session |
| `head` | 13 | supported |
| `interleave` | 11 | supported |

## Script API occurrences

| API | Occurrences |
|---|---:|
| `java.get` | 1035 |
| `java.md5Encode` | 929 |
| `java.ajax` | 858 |
| `java.getString` | 838 |
| `java.log` | 655 |
| `java.put` | 617 |
| `cookie.getKey` | 354 |
| `source.getKey` | 297 |
| `java.timeFormat` | 262 |
| `java.base64DecodeToByteArray` | 213 |
| `java.lang` | 178 |
| `java.toast` | 175 |
| `source.getVariable` | 155 |
| `cookie.removeCookie` | 141 |
| `java.longToast` | 130 |
| `java.getElements` | 129 |
| `source.bookSourceComment` | 119 |
| `java.base64Decode` | 109 |
| `java.base64Encode` | 105 |
| `java.encodeURI` | 105 |
| `source.getLoginInfoMap` | 85 |
| `java.aesBase64DecodeToString` | 81 |
| `java.getElement` | 67 |
| `source.get` | 59 |
| `java.startBrowser` | 53 |
| `java.getStringList` | 50 |
| `cookie.getCookie` | 48 |
| `java.post` | 47 |
| `source.bookSourceUrl` | 47 |
| `java.security` | 46 |
| `java.startBrowserAwait` | 44 |
| `java.createSymmetricCrypto` | 39 |
| `source.setVariable` | 34 |
| `source.put` | 33 |
| `java.connect` | 29 |
| `java.toNumChapter` | 29 |
| `java.util` | 29 |
| `source.key` | 29 |
| `java.hexDecodeToString` | 28 |
| `java.timeFormatUTC` | 28 |
| `java.getStrResponse` | 27 |
| `java.getCookie` | 25 |
| `source.loginUrl` | 24 |
| `java.getWebViewUA` | 22 |
| `java.io` | 22 |
| `source.getLoginHeader` | 21 |
| `java.setContent` | 20 |
| `source.bookSourceName` | 20 |
| `cookie.setCookie` | 18 |
| `java.webView` | 16 |
| `source.refreshExplore` | 16 |
| `source.header` | 15 |
| `java.head` | 13 |
| `java.refreshTocUrl` | 13 |
| `source.putLoginInfo` | 13 |
| `java.ajaxAll` | 12 |
| `java.desEncodeToBase64String` | 12 |
| `source.getLoginInfo` | 10 |
| `source.putLoginHeader` | 10 |
| `java.androidId` | 8 |
| `java.refreshExplore` | 8 |
| `java.t2s` | 8 |
| `java.randomUUID` | 7 |
| `java.refreshContent` | 7 |
| `source.getSource` | 7 |
| `source.ruleExplore` | 7 |
| `java.ajaxTestAll` | 6 |
| `java.getUserAgent` | 6 |
| `source.lastUpdateTime` | 6 |
| `java.htmlFormat` | 5 |
| `java.net` | 5 |
| `java.redirectUrl` | 5 |
| `source.variableComment` | 5 |
| `java.base64Decoder` | 4 |
| `java.deviceID` | 4 |
| `java.openVideoPlayer` | 4 |
| `java.qread` | 4 |
| `java.ruleUrl` | 4 |
| `java.s2t` | 4 |
| `cookie.setWebCookie` | 3 |
| `java.digestHex` | 3 |
| `java.getVerificationCode` | 3 |
| `java.md5Encode16` | 3 |
| `java.openUrl` | 3 |
| `java.showBrowser` | 3 |
| `java.startBrowserAwaitAwait` | 3 |
| `java.strToBytes` | 3 |
| `java.upLoginData` | 3 |
| `java.webview` | 3 |
| `source.loginUi` | 3 |
| `source.refreshJSLib` | 3 |
| `java.HMacHex` | 2 |
| `java.initUrl` | 2 |
| `java.key` | 2 |
| `java.queryTTF` | 2 |
| `java.refreshBookInfo` | 2 |
| `java.refreshBookUrl` | 2 |
| `java.startBrowserDp` | 2 |
| `java.webViewGetOverrideUrl` | 2 |
| `source.concat` | 2 |
| `source.exploreUrl` | 2 |
| `source.getHeaderMap` | 2 |
| `source.variable` | 2 |
| `cookie.mapToCookie` | 1 |
| `java.HMacBase64` | 1 |
| `java.bytesToStr` | 1 |
| `java.cacheFile` | 1 |
| `java.getBook` | 1 |
| `java.ocr` | 1 |
| `java.readBookConfig` | 1 |
| `java.replaceFont` | 1 |
| `java.searchBook` | 1 |
| `java.setBaseUrl` | 1 |
| `java.showPhoto` | 1 |
| `java.showReadingBrowser` | 1 |
| `source.getLoginHeaderMap` | 1 |
| `source.getLoginUi` | 1 |
| `source.putVariable` | 1 |

## Java collection compatibility occurrences

| Method | Occurrences |
|---|---:|
| `get()` | 1337 |
| `size()` | 290 |
| `toArray()` | 117 |
| `isEmpty()` | 4 |
