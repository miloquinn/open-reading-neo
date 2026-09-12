# 书源网页登录与设备会话

书源的 `loginUrl` 可以填写原网站的 HTTP(S) 地址或相对地址。用户在书源登录页打开内置浏览器，登录原站后点击“完成”，应用才保存会话；取消保留此前的会话。网页的账号密码由原网站处理，应用不会额外提取密码输入框。

```json
{
  "bookSourceUrl": "https://books.example",
  "loginUrl": "/signin",
  "enabledCookieJar": true
}
```

网页登录与原有 `loginUi` / `loginUrl` JavaScript 表单登录共存。网页登录后的会话即使原书源未显式启用 `enabledCookieJar`，也会参与该书源的后续请求。

## 保存、使用和清除

- 会话按书源 stable ID 存入现有系统安全存储，包含 Cookie 列表和按 origin 分组的 Local Storage。旧版本只含 `loginInfo` / `loginHeaders` 的数据仍能读取。
- 普通 HTTP 请求按 Cookie 域名、host-only、路径、Secure 和有效期选择 Cookie；服务器刷新或删除 Cookie 后持久化最新结果。
- 后台 WebView 和再次打开的登录浏览器使用同一份快照，并在网站脚本运行前恢复 Local Storage。不同 origin 的同名键独立保存。
- “清除登录会话”清除当前书源的输入信息、登录头、Cookie 和 Local Storage。清除期间晚到的浏览器或请求结果不会恢复旧账号。
- 保存失败会报告错误；网页登录不会在安全存储写入失败时替换原来的有效会话。

## Local Storage Token 与请求头

Local Storage 不是 HTTP 请求头，网站对 Token 的键名、格式和发送方式没有统一约定。应用不会猜测任意 `token` 值并发送给其他地址。

浏览器请求由网站自身脚本读取已恢复的 Local Storage。需要直接调用 API 的书源，可以通过 `header` 规则明确选择网站要求的 Token，例如：

```js
@js:
JSON.stringify({
  Authorization: "Bearer " + localStorage.getItem("access_token")
})
```

脚本中的 `localStorage.getItem/setItem/removeItem/clear/key/length` 对当前规则上下文的 origin 生效。若账号站点和书源域名不同，可使用：

```js
source.getLocalStorage("https://accounts.example").get("access_token")
```

脚本变更按键合并到最新会话，避免验证码或浏览器交互刷新 Token 后，被脚本的旧快照覆盖。

## 平台实现与边界

- iOS、macOS：使用独立的非持久 WKWebsiteDataStore，恢复 Cookie（包括 HttpOnly）及各 origin 的 Local Storage。成功时导出到应用安全存储，取消时销毁临时浏览器。
- Android 9 及以上：使用独立的 `:sourceBrowser` 进程和 WebView 数据目录，串行恢复、使用并清理临时会话，避免影响主进程中的其他浏览器。
- Android 系统 CookieManager 可以读取 Cookie 值，包括 HttpOnly Cookie，但不能导出新 Cookie 的完整 Domain/Path/Expires/SameSite 等原始属性。已知属性保留；无法读取的属性标记为 `attributesKnown: false`，域名与路径按已观察 URL 保守限制。因此不能承诺所有 Android 网站的 Cookie 属性与服务器原始属性完全一致。
- Android 9 以下、Windows、Linux、Web 没有此原生会话实现，返回明确的不支持信息，不把外部浏览器打开成功当作会话保存成功。

会话不包含 IndexedDB、Service Worker、设备绑定密钥或 Passkey 凭证；需要这些状态或拒绝嵌入式浏览器的网站，仍受原站登录机制限制。

## 验证

相关回归文件：`source_browser_storage_test.dart`、`source_browser_session_runtime_test.dart`、`source_login_page_test.dart`。同时运行原有 Cookie、HTTP、脚本、交互协调及登录缓存失效回归；拥有全局状态的 Flutter 文件分别启动测试进程。

2026-09-12 验证：11 个独立 Flutter 测试文件共 123 项通过；本次涉及的 Dart 文件静态分析通过；包含 Flutter 编译的 Android `:app:assembleDebug` 通过。Cookie 回归也验证了不同路径的同名 Cookie 不会在生成请求头时被合并丢失。

Android 的 debug-only `SourceBrowserSessionFixtureActivity` 已在 Android 16 设备运行通过，覆盖登录页同步写 Local Storage 后立即跨 origin 跳转、没有等待 `onPageFinished` 安装回调的场景。安装调试包后可复验：

```sh
adb shell am start -W -n com.niki.xxread/.SourceBrowserSessionFixtureActivity
adb logcat -d -s SourceBrowserFixture:I '*:S'
```

iOS/macOS 新增桥分别通过对应 SDK 的 Swift 类型检查。macOS 真实 WKWebView 动态验证覆盖 HttpOnly Cookie、文档开始前恢复、跨 origin 隔离、网站同时清空两类 Storage 后跳转不会恢复旧 Token，以及取消清理。iOS 尚未进行真实账号设备登录测试；完整 Apple workspace 构建在本地 Pods/Xcode 第三方插件步骤受阻，不能将原生类型检查当作完整 Apple 产品构建通过。

可在 macOS 运行 `./tool/source_browser_wk_fixture/run.sh` 复验 WebKit 浏览器行为。它额外覆盖跨 origin iframe 的恢复与抓取、`__proto__` 键名；该夹具验证真实浏览器语义和 JavaScript 协议，产品桥代码另做 Swift 类型检查。

原生通道为 `com.niki.xxread/source_browser_session`，支持 `open`、`load`、`clear`、`cancel`。`open/load` 成功返回 `{body, finalUrl, session: {cookies, localStorage}}`；Cookie 有效期使用 UTC epoch 毫秒，Local Storage 以 HTTP(S) origin 为键。
