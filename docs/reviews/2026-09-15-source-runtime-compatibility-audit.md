# 书源运行时与登录兼容性审计

日期：2026-09-15。对照 `/Users/origo/code/legado-E` 与 Open Reading 当前工作区。

结论：当前主要缺口已经超出选择器语法。同步脚本执行、宿主对象行为、状态生效时机、登录 UI 事件和错误恢复仍存在成组差异。继续按单个书源补函数，难以稳定提升整条阅读链的兼容性。

## 范围和证据等级

- 参考项目 HEAD：`8b87c5aba4df91c39a3a0939a68a1180b9f2ee1c`。
- Open Reading HEAD：`3f0f0317feab88677ea9ac3c58dea7e11a71f482`；分析使用当前工作区文件。
- 本次在 macOS 的真实 JavaScriptCore 桥上运行 12 个离线观测，使用假网络传输和内存登录存储；未访问真实账号或书源网站。
- 参考行为来自本地 Kotlin 源码审阅，未启动 Legado Android 应用。因此表中的参考预期不是双引擎运行结果。
- 没有修改应用代码；新增诊断程序、观测结果和本文。工作区原有及其他任务的修改不属于本次审计。

[诊断程序](/Users/origo/code/open-reading/tool/source_compatibility_audit_probe.dart) · [原始观测](/Users/origo/code/open-reading/docs/reviews/2026-09-15-source-runtime-observations.json)

复验：

```sh
flutter test --no-pub tool/source_compatibility_audit_probe.dart --reporter expanded
```

可用 `SOURCE_AUDIT_OUTPUT=/absolute/path/result.json` 保存结果。该程序放在 `tool/`，不会混入默认回归套件。运行器显示成功只代表收集完观测，不代表这些兼容性问题通过验收；修复时应另加断言参考行为的回归测试。

## 1. 参考项目的书源到底是什么

JSON 承载的是程序入口、规则和界面描述，运行时提供以下协作机制：

1. **请求程序**：`AnalyzeUrl` 处理 URL 脚本、插值、页码、请求 options、编码、请求头、请求体以及 WebView。它不仅把字符串转成 URL。
2. **提取程序**：`AnalyzeRule` 将选择器、脚本、变量读写、替换组合成流水线。JSoup、Jayway JSONPath、JXDocument 和 Java 正则是具体执行器；`&&`、`||`、`%%` 及单值/列表返回语义也属于契约。
3. **脚本宿主**：Rhino 绑定真正的 Kotlin/Java 对象。`java` 随上下文变化：提取时是 `AnalyzeRule`，URL/登录检查时是 `AnalyzeUrl`，来源方法中是 `BaseSource`，登录窗口中是 `SourceLoginJsExtensions`。相同名称下可用的方法和状态并不完全相同。
4. **状态**：规则、书、章节、来源、缓存、登录信息、登录头、Cookie 有不同作用域和寿命。`source.put/get` 经 `CacheManager` 保存；`jsLib` 则拥有缓存的共享脚本 scope。
5. **完整流程**：搜索 → 详情 → 目录 → 正文，每一步还可能做登录检查、刷新地址、分页、解密或浏览器交互。

因此，能导入 JSON、能执行 ECMAScript，甚至能解析首页，都不足以证明这个源可用。

参考入口：[AnalyzeUrl](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt)、[AnalyzeRule 绑定](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt:828)、[JsExtensions](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/help/JsExtensions.kt:100)、[WebBook](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/model/webBook/WebBook.kt:45)。

## 2. 已复现的差异

所有数值都来自本次离线观测。风险描述说明这类差异会影响什么，不能据此推算有多少真实书源失效。

| 场景 | 参考行为/契约 | 当前观测 | 影响 |
|---|---|---|---|
| 连续两次 `java.ajax('/counter')` | 两次宿主请求，响应可不同 | 只调用网络一次，返回 `['1','1']` | 同 URL 轮询、登录前后重取被错误复用 |
| URL 使用 `java.randomUUID()` | 生成一次 nonce 后完成一次请求 | 发出 12 次不同请求，最终触发次数限制 | 签名或随机参数源可能持续重试 |
| `cache` 自增后发一次请求 | 自增一次 | 结果为 2 | 重跑重复执行已发生的副作用 |
| `jsLib` 中闭包计数器 | 缓存 scope 存活期间连续递增 | 两次独立规则调用得到 `[1,1]` | 库初始化和共享状态不一致 |
| 写登录头后立即发请求 | 新头应对后续请求可见 | 请求不带 Authorization，脚本结束后存储中才有 | 多步骤登录/换 Token 失败 |
| 执行普通设置按钮 action | 不应无故删除已有登录头 | 原 Authorization 被清空 | 点设置或验证码按钮可能丢会话 |
| 没有 `login()` 的脚本走登录提交 | 参考显式抛错 | 无错误完成 | UI 可显示已保存，而登录函数根本没运行 |
| 重建 evaluator 后读 `source.put` 的值 | 来源持久值通过 CacheManager 保存 | 返回空字符串 | 重建运行时丢来源 Token/配置 |
| 未实现 API 的完整结构源 | 结构状态不能证明执行支持 | 静态级别仍为 `supported` | 标签与实际可运行程度脱节 |
| 登录脚本 ajax + 动态 header | 嵌套执行请求头后继续请求 | 2 秒超时、网络调用 0 次 | 执行队列循环等待 |
| 传输层抛错后检查登录 | 参考会给检查脚本错误响应以尝试恢复 | `loginCheckJs` 没有运行 | 错误后的自动重登/恢复路径缺失 |

第 12 个观测检查 API 形状：`source.login`、`source.removeLoginInfo`、`source.putVariable`、`java.upLoginData`、`java.reLoginView`、`java.refreshBookToc`、`isLongClick` 均为 `undefined`；`java.refreshTocUrl()` 返回 `null`，对应代码为空实现。API 形状不是完整 UI 回归，但足以证明这些入口当前没有接通。

### 2.1 同步网络调用的重跑模型是核心风险

[脚本 evaluator](/Users/origo/code/open-reading/lib/book_sources/source_engine/scripting/source_script_engine.dart:53) 遇到同步 `java.ajax()` 时，以特殊异常退出，Dart 异步获取响应，再从脚本开头重新执行。

[响应索引](/Users/origo/code/open-reading/lib/book_sources/source_engine/scripting/source_script_host_api.dart:187) 仅使用 method、URL、body、headers、webJs 作为签名，没有区分同一脚本中第几次调用；所以“重放第一次请求”和“真正的第二次同地址请求”混为一谈。

重跑还会重新生成随机值、读取时间、执行缓存/Cookie 等副作用。当前部分状态留在 JavaScript 局部变量，部分立即调用宿主，部分在最终 envelope 才写回，缺乏统一的执行顺序保证。这能解释为什么纯提取样例正常，稍复杂的认证或请求脚本就失效。

不能把请求上限从 12 调大当作解决方案：nonce 会继续变化，副作用也会继续重复。

### 2.2 动态请求头存在重入死锁

调用链如下：

```text
evaluateAsync(login脚本) 持有串行执行队列
  → java.ajax → 等待 _sendScriptNetwork
    → sourceHeaders → evaluateAsync(header脚本)
      → 等待上一个脚本结束
        → 上一个脚本仍在等待这个请求
```

证据：[串行队列](/Users/origo/code/open-reading/lib/book_sources/source_engine/scripting/source_script_engine.dart:39)、[请求内求值 header](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_runtime_requests.dart:598)、[header 脚本执行](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_runtime_requests.dart:473)。2 秒超时是诊断观察窗口；循环依赖的判断同时有代码依据，不是根据网站响应慢推测。

### 2.3 登录头存在“写入成功但请求看不见”

[putLoginHeader](/Users/origo/code/open-reading/lib/book_sources/source_engine/scripting/source_script_bootstrap.dart:148) 只修改当前 JS 的 `__loginHeaders`；真正写回 session 要等 [最终结果解包](/Users/origo/code/open-reading/lib/book_sources/source_engine/scripting/source_script_engine.dart:147)。脚本内的网络请求先读取 Dart session，因此读到旧头。

另一个独立问题是 [登录 action 路径](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_runtime_login.dart:453) 调用 `save(source, loginInfo: ...)`，而 [save 默认参数](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_runtime_login.dart:119) 将 `loginHeaders` 设为 `{}`。普通按钮 action 在执行前就可能清掉原来的头。

### 2.4 错误恢复发生得太晚

[当前请求入口](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_runtime_requests.dart:145) 只在传输成功后调用登录检查，catch 中直接重抛。[HTTP 层](/Users/origo/code/open-reading/lib/book_sources/source_engine/source_http_transport.dart:391) 会将非重定向的错误状态抛出，某些 401 还转换为重新登录提示。因此不能因为存在 `_applyLoginCheck` 就认为已实现参考项目的错误恢复契约。

[参考 WebBook](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/model/webBook/WebBook.kt:70) 在失败分支构造错误响应，再让检查脚本有一次恢复机会。复现采用传输异常；未在此次运行真实 HTTP 401 对照。

## 3. 登录那一套应当怎样理解

### 三条相关但不同的流程

**网页登录。** 参考 [SourceLoginActivity](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/ui/login/SourceLoginActivity.kt:31) 在没有 `loginUi` 时进入 WebView，加载登录 URL 和来源请求头，并回收 Cookie。Open Reading 已有原生浏览器、Cookie/Local Storage、安全存储与会话恢复，不能将它描述为“没有网页登录”。当前约束见 [网页登录文档](/Users/origo/code/open-reading/docs/source-website-login.md)。

**脚本表单/设置界面。** 有 `loginUi` 时，它是一个可编程界面：`text/password/button/toggle/select`、默认值、动态 `viewName`、字段变化 action、按钮点击/长按、界面数据更新和重建。`loginUrl` 此时可以承载 JS 函数集合。页面中也可能是 API Key、线路选择、签到、验证码等设置，并不总是账号密码表单。

**请求时的登录检查。** `loginCheckJs` 接收响应对象，可以判断登录态、调用来源登录逻辑、重新请求并返回替代响应。它依赖完整的 `source`、`java` 和响应对象能力，而非一个布尔“是否登录”。

### 当前登录 UI 的实质缺口

- 已有静态表单、下拉/开关和按钮 action；不能把这些已有能力重复列为待做。
- `java.upLoginData()` 和 `java.reLoginView()` 尚未接通；脚本无法按参考契约更新输入和重建表单。
- 当前输入框与选择变化只更新本地值，没有执行参考项目的字段 action；`viewName` 当文字显示，没有按参考实现求值。
- 缺少 `isLongClick`、登录入口的真实 book/chapter 上下文以及相应刷新事件。仅让同名函数返回 `null` 无法触发目录、详情或正文更新。
- 没有 `login()` 时默认提交静默完成，而参考实现明确报错。
- `source.login()` 缺失，导致某类自动重登脚本即使走到 `loginCheckJs` 也无法继续。

依据：[参考 UI 事件](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/ui/login/SourceLoginDialog.kt:697)、[参考宿主回调](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/ui/login/SourceLoginJsExtensions.kt:24)、[当前页面](/Users/origo/code/open-reading/lib/pages/book_sources/source_login_page.dart:302)。

### Cookie 与持久化不能只比函数名

参考 [CookieStore](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/help/http/CookieStore.kt:32) 按计算后的域名保存，并与 WebView/session Cookie 合并；Open Reading 使用来源隔离的 Cookie jar，按域名、路径、安全属性匹配。两者存在实质语义差别，特别是一个来源跨多个关联域名、多个来源共用账号的情况；本次未逐站验证这些影响。

应单独定义兼容脚本的 Cookie 视图和浏览器/HTTP 交换规则，不应为了追求兼容就无条件向其他域名发送 Cookie。

来源变量也不能和安全存储中的登录 session 混为一谈：当前 `source.put/get` 和 `cache` 保存在 evaluator 内存状态中；它们未因为网页登录会话持久化就自动获得相同寿命。[参考来源方法](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/data/entities/BaseSource.kt:275) 经 CacheManager 保存。

## 4. 其他结构性差异

- **Rhino/Java 与桥接对象不同。** Apple 使用 JavaScriptCore，其他原生平台走 flutter_js 路径，Web 显式不执行书源脚本。当前 Java 类适配表覆盖一部分 String、编码、集合、摘要和加密方法，不是 JVM。Java 方法重载、返回对象、异常和动态导入均需契约测试。
- **jsLib 生命周期不同。** [参考实现](/Users/origo/code/legado-E/app/src/main/java/io/legado/app/model/SharedJsScope.kt:30) 支持远程 JSON 库清单并缓存 scope；scope 使用弱引用/LRU，并非保证永久存活。当前把 `jsLib` 文本拼入每次调用重新执行，远程 JSON 清单也未形成对应加载链。隔离跨来源污染的测试不能证明共享 scope 语义兼容。
- **规则库不是相同实现。** 当前 XPath 是手写子集，JSONPath 使用 Dart 包，HTML 和正则也经过重新实现。已有选择器、分页、图片、编码、状态传播等修复是有效进展，但同名语法仍需与参考实现比结果、类型、空值及异常。
- **特定业务能力缺失。** 字体反爬的 `queryTTF/replaceFont`、部分 WebView 资源/跳转捕获方法以及目录预更新逻辑，不会由“支持 JavaScript”自动获得。当前 `refreshTocUrl/initUrl` 空操作尤其容易让源继续执行却产生错误结果。
- **平台能力不能合并计分。** Android、Apple、桌面及 Web 的脚本/浏览器能力有差别；macOS 离线探针通过运行不意味着 Android、iOS 实机登录已经验证。

## 5. 为什么一直感觉修了很多却提高有限

第一，修复常围绕某个样本的语法和函数形状；复杂源要求宿主方法、网络、状态、共享库、UI 和错误恢复同时成立。任何一环失配，整条链都会失败。

第二，现有回归多使用确定性输入和简单假请求。两次同地址请求、动态 header 嵌套、随机参数、立即可见的登录写入、失败后的恢复，这些关键组合此前没有形成统一执行契约。

第三，缺少同响应的参考对照。已有端到端测试和线上抽测很有价值，但不能自动区分“源过期”“网站拒绝访问”“需要登录”“引擎输出不同”。应同时保存参考输出和本项目输出。

第四，统计口径仍容易误导。[固定语料基线](/Users/origo/code/open-reading/tool/reading_source_lab/docs/corpus-baseline-2026-09-09.md) 明确写着：7,506 个唯一源、6,865 个结构齐全、91.46% 是结构准备率；该基线执行数为 0，执行率未知。这不代表项目历史上从没测试过书源，而是这份大样本报告没有提供执行兼容证明。其启发式统计检测到 3,669 个依赖 JavaScript、883 个含登录依赖、378 个含 WebView 依赖；这些数字说明运行时值得优先投入，不能算作失败数。

当前 `SourceCompatibilityScanner` 还会移除登录字段再作核心可用性扫描，且不检查每个宿主 API。允许尝试公开阅读合理，但 `supported` 不应被理解为“完整兼容”，最好拆成“结构可尝试 / 执行已验证 / 需要交互 / 能力缺失 / 网站异常”。

## 6. 建议修复顺序与验收

### P0：稳定执行和认证状态

1. 消除 header 求值的循环等待，明确可重入宿主调用与执行队列的所有权。仅移除串行保护会重新引入上下文串源，不能作为修复。
2. 定义副作用按程序顺序发生一次的契约：相同 URL 的不同调用必须可区分；随机/时间不能在内部重跑中悄悄变化；缓存/Cookie/UI 事件不能重复提交。
3. 让登录头、来源状态的写入对脚本随后发出的请求立即可见；普通 action 保留现有登录头；缺失登录函数明确报错。
4. 恢复错误响应进入 `loginCheckJs` 的路径，补全 `source.login` 和请求响应对象的必要行为，并避免重登递归/死锁。

验收至少包含本次所有离线反例对应的**正确行为断言**，再加入取消、失败、并发来源和退出后重新创建运行时的组合。

### P1：完整登录控制器与状态模型

实现动态登录字段、事件、`upLoginData/reLoginView`、上下文和刷新通知；明确来源持久值、登录数据、登录头、Cookie、共享库及规则局部变量的归属、寿命和刷新顺序。随后做 Android 与 iOS/macOS 的原生浏览器会话验收。

验收用本地认证站覆盖：表单登录 → 保存 Token → 当次脚本访问私有接口 → Token 失效 → 检查脚本重登 → 重发 → 重启恢复；另测验证码/取消、修改设置不掉登录、网页跳转后回收会话。

### P2：建立参考执行与真实样本矩阵

从用户确认“同设备/同网络下 Legado 可用”的失败源开始，按纯规则、JS 请求、动态 header、登录、WebView、字体等分层，固定源版本和响应快照。抽取对应本地参考实现运行规则，不先启动覆盖整个 Android 应用的大规模改造。

每例记录：来源版本、平台、阶段、请求序列、响应快照哈希、规则输入/输出、必要状态变化、最先失配点。认证数据脱敏，不把 Token 和密码写入报告。无法离线模拟的浏览器挑战单列真机结果。

分别报告：离线语义一致率、参考可用源的完整在线链通过率、需要用户交互的比例、目标站异常比例、未验证比例。不同类别不相互替代。

### 运行时方向

优先评估在独立工作线程/运行环境中保留同步宿主调用语义，让网络和 UI 通过明确 RPC 返回结果，避免重跑整段脚本；跨端继续使用 QuickJS/JSC 也可以，但关键是调用、状态和对象契约。

Android 直接使用 Rhino/Java 可以减少该平台的语言与类桥差异，但不能自动解决 iOS，也可能形成两套行为分叉。它适合作为参考执行器或经过评估的 Android 后端，不应把“换一个 JS 引擎”当成完整方案。上述 P0 反例应成为任何候选运行时必须通过的准入条件。

## 本次验证与未验证

- 已运行：macOS JavaScriptCore 离线观测，12 项全部完成收集；存在的差异见表，不宣称兼容通过。
- 已检查：新增 Dart 诊断程序格式与静态分析、本文涉及的本地源码链路。
- 未运行：Legado APK 对照、Android/Windows/Linux 脚本探针、真实网站登录、物理设备登录、全量书源在线链路、产品构建和发布。
