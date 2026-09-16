# 书源网页登录与设备会话

## 通用登录与在线导入

登录逻辑来自导入的书源配置。`loginUi` 的 JSON（也支持返回 JSON 的脚本）生成表单，`loginUrl` 中的 JavaScript 和按钮 `action` 决定如何请求接口、保存 Cookie 或登录头。HTTP(S) `loginUrl` 则打开内置网页登录。应用不需要为每个站点编写登录接口。

对照本地 Legado-E：`SourceLoginActivity` 按是否存在 `loginUi` 选择表单或 WebView；`SourceLoginDialog` 执行书源脚本；`WebViewLoginFragment` 将网页 Cookie 同步至 CookieStore。WebView 开启 DOM Storage，但这条链路没有将 Local Storage 自动转换为 HTTP 请求头。本站已有的按 origin 保存、恢复 Local Storage 能力继续保留。

URL 导入需要书源 JSON、订阅文档或 ORSP 服务地址。原网站的 `/login` 页面是 HTML，并不包含搜索、目录和正文规则，不能代替书源文件；遇到这类地址，导入页会明确提示复制网站的书源下载或订阅链接。

2026-09-15 通用兼容修复：

- 关闭 `enabledCookieJar` 仅禁用自动 HTTP Cookie 管理，不再禁用脚本显式读写；脚本保存的 Cookie 仍通过安全存储恢复。
- `cookie.setCookie` 保留整组替换语义；带 Path/Max-Age 等属性的单条 Cookie 可以更新、过期，不会误删其他登录 Cookie。
- 登录页恢复已保存的字段；执行设置按钮保留已有登录头。
- `data:` 书籍与章节上下文使用书源的 Local Storage origin；小说中的评论图片不会单凭 `<img>` 字符串被判成漫画。
- 网络等待后重跑脚本时，已经读取过的时间、随机数和 UUID 按调用顺序复用；新的调用仍取新值。这样带时间戳的原书源请求能命中该次执行的响应，不会重复请求至次数超限。网络次数限制保留。

手动在线验收工具为 `tool/verify_source_login.dart`。通过环境变量传入 `SOURCE_URL`（或本地 `SOURCE_FILE`）、`SOURCE_LOGIN_VALUES`、`SOURCE_LOGIN_ACTION`、`SOURCE_LOGIN_ORIGIN`、`SOURCE_QUERY`，可选 `SOURCE_EXPECT_TEXT` 校验正文片段。工具调用实际导入器与书源运行时，检查 Cookie 会话、搜索、详情、目录及前三章；不把账号、密码和会话写进仓库。此测试在普通 CI 之外手动运行。

本次实测使用站点提供的原版大灰狼书源，经过在线导入、账号登录、搜索（9 条结果）、详情、目录（103 章）及前三章正文，并校验第一回的正文片段。14 个独立 Flutter 测试文件通过，改动文件静态检查通过。本次没有进行手机实机登录或重新构建安装包。

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

通用登录兼容约定（2026-09-15）：

Android 浏览器跨进程参数中的可选 HTML、JavaScript 和界面文案按字符串类型读取，JSON `null` 保持为空；不能用 `JSONObject.optString` 将其转换成正文 `"null"`。可见浏览器与后台加载服务共用此约定。2026-09-16 原生真机夹具验证了空值、缺失字段、合法字面文本 `"null"`、内联 HTML 和跨域 Local Storage；浏览器交互、运行时交互端口及会话回归共 18 项通过。普通网页按钮逐项实测尚未完成。

- 同一脚本操作内的请求头/响应脚本不排在等待它的父脚本之后；独立操作仍串行。回归覆盖嵌套完成、失败后恢复及其他书源的隔离。
- 脚本网络请求的协议错误在原始 JavaScript 调用点重放，让书源自己的 `try/catch` 能处理可选接口失败；取消操作不重放、不吞掉，必需接口的未捕获错误仍向用户报告。
- 根规则脚本接收原始 HTTP 文本（包括 JSON），而 JSONPath 与选中条目的脚本仍接收结构化数据；避免书源的 `JSON.parse(result)` 收到对象。
- 带 `type` 的本地 `data:` 请求支持书源自定义载荷标签，不要求标签是标准 MIME 类型；保持原始地址并返回十六进制正文，不能因 URI 解析失败静默丢弃书籍。
- `putLoginHeader` 支持原始字符串与 JSON 对象，原始值在安全存储中单独保存；只有解析出的对象才作为自动 HTTP 请求头。原始 Token 的编码和用途由书源脚本决定。
- 登录脚本的 `toast/longToast` 最终消息返回登录页完整展示；脚本反馈不再被无条件“会话已更新”覆盖。没有反馈时的会话保存提示不代表第三方认证结果。
- 封面占位图保留到解码首帧，再执行一次淡入；同步命中的解码缓存不重复淡入，并尊重减少动画设置。

相关回归文件：`source_browser_storage_test.dart`、`source_browser_session_runtime_test.dart`、`source_login_page_test.dart`。同时运行原有 Cookie、HTTP、脚本、交互协调及登录缓存失效回归；拥有全局状态的 Flutter 文件分别启动测试进程。

2026-09-16 Android 真机验证：覆盖安装保留数据后，原始书山规则使用已保存的登录会话加载个性推荐、书籍详情，并打开《北境猎王》第 1 章正文分页。大灰狼此前也已验证到正文。本轮没有书源名或域名特判；这不代表所有聚合平台、账号专属分类均已实测。封面首帧过渡已通过组件回归，尚未完成真机逐帧动画检查。

2026-09-12 验证：11 个独立 Flutter 测试文件共 123 项通过；本次涉及的 Dart 文件静态分析通过；包含 Flutter 编译的 Android `:app:assembleDebug` 通过。Cookie 回归也验证了不同路径的同名 Cookie 不会在生成请求头时被合并丢失。

Android 的 debug-only `SourceBrowserSessionFixtureActivity` 已在 Android 16 设备运行通过，覆盖登录页同步写 Local Storage 后立即跨 origin 跳转、没有等待 `onPageFinished` 安装回调的场景。安装调试包后可复验：

```sh
adb shell am start -W -n com.niki.xxread/.SourceBrowserSessionFixtureActivity
adb logcat -d -s SourceBrowserFixture:I '*:S'
```

iOS/macOS 新增桥分别通过对应 SDK 的 Swift 类型检查。macOS 真实 WKWebView 动态验证覆盖 HttpOnly Cookie、文档开始前恢复、跨 origin 隔离、网站同时清空两类 Storage 后跳转不会恢复旧 Token，以及取消清理。iOS 尚未进行真实账号设备登录测试；完整 Apple workspace 构建在本地 Pods/Xcode 第三方插件步骤受阻，不能将原生类型检查当作完整 Apple 产品构建通过。

可在 macOS 运行 `./tool/source_browser_wk_fixture/run.sh` 复验 WebKit 浏览器行为。它额外覆盖跨 origin iframe 的恢复与抓取、`__proto__` 键名；该夹具验证真实浏览器语义和 JavaScript 协议，产品桥代码另做 Swift 类型检查。

原生通道为 `com.niki.xxread/source_browser_session`，支持 `open`、`load`、`clear`、`cancel`。`open/load` 成功返回 `{body, finalUrl, session: {cookies, localStorage}}`；Cookie 有效期使用 UTC epoch 毫秒，Local Storage 以 HTTP(S) origin 为键。
