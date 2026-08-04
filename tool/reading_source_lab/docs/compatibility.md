# Reading source compatibility notes

## 上游执行模型

阅读书源的“收源”不是简单保存 JSON。导入层先接受对象、数组、URL 清单或文件 URI，按
`bookSourceUrl` 与本地版本比较；真正的兼容性由后续执行链决定：

1. `AnalyzeUrl` 先执行 URL 中的 `@js:` / `<js>`，再替换 `{{...}}`、分页表达式和请求参数。
2. 请求参数对象决定 GET/POST、headers、body、charset、WebView 与页面脚本。
3. `AnalyzeRule` 把规则拆成选择器、脚本、状态、正则替换等连续阶段。
4. HTML 规则由 JSoup 执行，JSON 规则由 JsonPath 执行，XPath 规则由 JXDocument 执行。
5. `&&` 合并各规则结果，`||` 取首个非空结果，`%%` 按位置交错合并结果列表。
6. `@put` / `@get` 与 `java.put` / `java.get` 把搜索阶段变量带入详情、目录和正文。

研究锚点（公开阅读书源执行实现的源码快照下载于 2026-08-04）：

- `ImportBookSourceViewModel.kt`：导入对象、数组、URL 和 URI，比较更新时间并选择新增/更新。
- `model/analyzeRule/AnalyzeUrl.kt`：URL 脚本、模板、请求 options、编码和 WebView。
- `model/analyzeRule/AnalyzeRule.kt`：规则阶段拆分、模式识别、状态和正则替换。
- `model/analyzeRule/AnalyzeByJSoup.kt`：`&&` / `||` / `%%`、旧式选择器与终值语义。
- `model/analyzeRule/AnalyzeByXPath.kt`、`AnalyzeByJSonPath.kt`：XPath/JSONPath 合并语义。

## 三批样本基线

用户提供的三份文件共 4,152 条配置：141 + 62 + 3,949。样本不提交到仓库。

- 文字类型占绝大多数，但也包含图片、音频/视频等非文字类型。
- `shareBookSource.json` 中约 2,188 条含 `@js:`，1,980 条含 `<js>`，脚本兼容是核心问题。
- XPath、POST、分页表达式、Cookie/login 字段和 WebView 使用量都很高。
- 有空 URL、旧式 URL 模板和潜在认证配置；审计工具只输出数量，禁止打印字段值。

## Open Reading 对照

三批样本的核心阅读链结构覆盖为 3,547 / 4,139（85.7%）：文字类型、有效 HTTP(S)
地址、搜索入口、目录规则和正文规则均存在。该数字表示离线结构可尝试，不代表站点在线、
规则仍有效或登录/风控已经通过。扩展能力等级单独统计，避免可选登录字段、关闭的 Cookie
开关或元数据文本把公开阅读链错误降级。

| 能力 | 当前状态 | 说明 |
|---|---|---|
| 对象/数组/URL 清单导入 | 支持 | 64 MiB、10,000 条、嵌套 URL 有界。 |
| CSS/旧式选择器 | 支持 | 包含阅读书源方括号索引、排除、倒序和 `@all`/`textNodes`。 |
| `&&` / `||` / `%%` | 支持 | 合并、回退和交错合并均有离线回归。 |
| XPath | 部分支持 | 常用轴、谓词和属性已支持，不等同完整 XPath 1.0。 |
| JSONPath | 支持 | RFC JSONPath 及常见旧式过滤写法。 |
| `@put` / `@get` | 支持 | 书籍变量跨搜索、详情、目录和正文保留。 |
| JavaScript | 原生端支持 | QuickJS + 有界网络重放；Web 端不执行脚本。 |
| `source.get` / `source.put` | 支持 | 按书源隔离的来源级键值在 QuickJS 生命周期中保留。 |
| Java 集合方法 | 支持 | `getStringList` / `getElements` 兼容 `size/get/isEmpty/toArray`。 |
| GET/POST/headers/charset | 支持 | UTF-8、GBK、GB2312、GB18030。 |
| WebView/webJs | Android 支持 | 仍需真机长期样本矩阵。 |
| Cookie 会话 | 支持 | 每来源隔离；脚本可读取、按键读取、设置和清理当前来源 Cookie。 |
| 同步请求响应对象 | 支持 | GET/POST/HEAD 返回正文、最终 URL、状态码、headers 和 cookies。 |
| `cache` | 支持 | 按来源隔离，支持持久会话值、内存值、删除和有效期。 |
| 共享脚本库 | 部分支持 | 内联脚本已支持；远程 JSON 脚本清单仍需受控下载缓存。 |
| 登录/验证码/付费 | 未完整支持 | 需要明确用户交互和副作用边界。 |
| Java/RSA/简繁辅助 API | 部分支持 | 按真实样本逐步补齐，不能宣称完整 Java 兼容。 |

## 后续补齐顺序

1. 用本项目对新书源批次做离线能力分层。
2. 从每类选取不含认证信息的最小规则夹具，先写失败测试。
3. 优先补纯解析和无副作用辅助 API；登录、验证、购买单独设计交互与权限。
4. 再跑 Open Reading 的搜索→详情→目录→正文真实链抽测，区分站点失效与引擎缺口。
