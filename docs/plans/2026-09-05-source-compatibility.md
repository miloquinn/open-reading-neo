# 阅读书源与漫画源兼容性增量改进

## 边界

对照阅读书源格式的规则与请求参考实现，修正可离线复现的语义缺口。
仅改源引擎和对应测试；不修改版本、发布流程或用户生成的 coverage/。
不增加依赖，不重写 UI，不声称完全兼容 Rhino/Java 平台能力。

## 行为锁定与清理顺序

1. 运行既有规则、请求、运行时和架构回归；新增测试先复现缺口。
2. 请求层：对齐 AnalyzeUrl.UrlOption.getBody 的 JSON 对象/数组序列化，
   以及 POST JSON 正文的默认 Content-Type；保留表单和显式类型。
3. 规则层：根据 Kotlin 实现核查字符串列表和规则转换语义，集中修复
   选择器边界，避免上层继续添加补丁。
4. 漫画层：以最终响应 URL 为图片基准，保留图片请求 options，
   消除正文规则重复求值和图片列表重复解析；以测试约束图片顺序、分页、替换。
5. 复用现有模块；将图片提取移出 reading 协调类，并把既有远程资源 URL/headers
   解析移为共享叶子模块，避免提取器反向依赖 catalog 编排层。
6. 每条独立路径完成后复测，最后运行相关源测试、静态分析、格式与架构检查。

## Fallback 审查

- JSON 解析失败后尝试 HTML：合法的内容识别边界，保留。
- 旧漫画目录选择器失效时从受限章节锚点恢复，以及全本单章节：
  已有回归的兼容路径，本轮保留。
- 原始章节 URL 恢复、受限漫画容器图片恢复：已有回归；只在规则未返回图片时使用，
  不能因猜到更多图片就覆盖成功的显式规则/替换结果。
- 漫画 list/value 双重执行：不是必要兼容路径；由单次规则结果推导图片和正文。
- 任意脚本/网络错误不得吞掉；不新增无依据的静默重试。

## 验收

新增失败案例在修复后通过；文本、漫画、请求选项既有测试不回退。
架构文件预算和导入边界不退化；没有新的依赖或发布文件变更。
记录已验证项目和未覆盖的真机、在线源或 JS 平台差异。


## 已复现的兼容性缺口

- POST 对象正文原先被拒绝；数组中的后续 `,{` 被误当作 options 起点；
  JSON 字符串原先被发送为表单媒体类型。
- CSS 属性值内的 `@` 被拆成规则段；属性列表保留空白与重复项；
  正文字符串求值丢失多值，迫使漫画额外调用 list。
- 漫画图片相对地址使用源根 URL，options/srcset 边界不清，
  raw-page recovery 可覆盖显式选择或复活 replaceRegex 删除的图片。

以上用离线夹具验证；请求层另有本地 HTTP 服务验证实际 UTF-8 字节和媒体类型。
参考行为追到 `AnalyzeUrl.UrlOption.getBody` 与 `OkHttpUtils.postJson`，
而非仅根据方法名称或中间 header map 推断。

## 第一阶段完成与验证（2026-09-05）

- 新增 23 项回归，源相关 18 个测试文件共 213 项测试通过。
- 漫画打开、正文替换两项 reader widget 测试分别在独立进程通过。
- `flutter analyze --no-pub`：No issues found。
- 变更 Dart 文件格式检查与 `git diff --check` 通过。
- 每页正文脚本从两次求值降为一次；正常成功路径不再扫描原始整页找更多图片。
- 去除 rawPages/directImageValues 等重复数据路径；有序 Map 合并同图请求头，
  替代重复图片的线性查找。reading 协调类从 692 行降至 543 行。
- 图片提取与 URL/options 解析分为两个共享职责，目录与漫画均复用远程资源解析。

变更文件：

- `lib/book_sources/source_engine/rules/source_rule_engine.dart`
- `lib/book_sources/source_engine/rules/source_rule_html.dart`
- `lib/book_sources/source_engine/source_request_template.dart`
- `lib/book_sources/source_engine/source_runtime_catalog.dart`
- `lib/book_sources/source_engine/source_runtime_reading.dart`
- `lib/book_sources/source_engine/source_content_images.dart`（新增）
- `lib/book_sources/source_engine/source_remote_asset.dart`（新增，从 catalog 移出）
- `test/source_request_test.dart`
- `test/source_http_transport_test.dart`
- `test/source_rule_html_compatibility_test.dart`（新增）
- `test/source_runtime_comic_compatibility_test.dart`（新增）
- `test/source_remote_asset_test.dart`（新增）
- `lib/book_sources/README.md`
- 本计划文档

未修改版本号、依赖、发布工作流或 changelog，保留原有 coverage/。
本轮没有提交或推送。未跑各平台发布构建、物理设备、实际在线书源/漫画源；
离线解析与本地 HTTP 测试不能证明所有现存书源可用。多链接分页、subContent、
标题规则、HTML终端形状和完整 Java/Rhino API 兼容仍需独立增量处理。

## 第二阶段：补齐已列出的规则能力

用户要求继续完成剩余项，本阶段覆盖：

1. 多链接 nextContentUrl 与单链接链式分页、有序合并、重复/重定向/下一章边界、页数上限。
2. 首屏上下文的 subContent 和 title，按阅读执行顺序处理；保留上一阶段图片替换约束。
3. HTML terminal 对齐 outerHtml 与 script/style 清理，使用克隆避免污染后续规则；
   all terminal 保持原文。同步更新明确与新目标冲突的旧 innerHtml 断言。
4. 脚本接口按本地 JsExtensions 与实际 helper 核对：补充字符集字节转换、
   URI表单编码、hex/base64重载及可映射的 Java 类入口。把 Java桥接从bootstrap
   移为单一模块，避免继续堆积启动脚本。未知 Java 类调用明确报错，不伪装支持。
5. 新增失败回归后修改，每个并行责任域通过后执行整体验证。

不增加 JVM 或 Android Runtime，也不让兼容脚本直接访问宿主文件系统。
对于依赖 Android UI/任意 Java反射/第三方字节码的行为，记录具体能力边界；
可移植的源解析规则不能借此跳过实现。


## 第二阶段审查补充

- `java.getString/getStringList` 的替换步骤原先丢失，已通过失败夹具复现。
  同步字符串接口补齐 joinSeparator/regexDotAll，复用既有规则管线。
- Java 包导入必须按类/包区分 Base64 实现；ArrayList 的删除不能复用
  DOM Elements 的整组移除语义。新增针对性测试约束这些边界。
- 唯一新增的异常降级为可选标题规则：参考 BookContent.kt 的 runCatching，
  标题出错保留原标题及已读正文。正文和分页错误继续传播。
- 全量正文替换必须同时约束图片结果，包括跨页删除、同名相对图片、URL改写；
  图片解析继续复用共享提取器，避免维护第二套 srcset/options 解析。


## 第二阶段完成与验证（2026-09-05）

- 22 个核心测试文件共 249 项通过（包含规则、脚本、请求、分页、漫画、
  编码、运行时接口与架构约束）。新增用例均先复现缺口后修复。
- `flutter analyze --no-pub`：No issues found。
- 29 个变更 Dart 文件格式检查通过，`git diff --check` 通过。
- 漫画打开与正文替换两项 reader widget 测试在独立进程通过。并发编辑曾使
  reader 测试文件暂缺辅助函数；对应任务补齐后，已使用当前文件重新验证两项通过。
- 固定分页最多 4 个并发、按页序求值，最多 20 页；预取失败有即时监听，
  下一章边界及自环比较会先解开 data wrapper 并去除 request options。
- 全文替换只执行一次；输出片段保留原页 base，统一复用图片提取器，
  连续片段用 StringBuffer 累积，避免同页反复拼接导致二次方拷贝。
- Java 类适配从 bootstrap 提出，编码集中至单一模块；同步/异步规则共用
  同一字符串语义，删除 host 中被新编码分发覆盖的重复分支。

第二阶段修改和新增的主要文件：

- `lib/book_sources/source_engine/source_runtime_reading.dart`
- `lib/book_sources/source_engine/source_runtime_rules.dart`
- `lib/book_sources/source_engine/source_text_replacement.dart`（新增）
- `lib/book_sources/source_engine/rules/source_rule_engine.dart`
- `lib/book_sources/source_engine/rules/source_rule_html.dart`
- `lib/book_sources/source_engine/rules/source_rule_port.dart`
- `lib/book_sources/source_engine/rules/source_rule_script.dart`
- `lib/book_sources/source_engine/scripting/source_script_bootstrap.dart`
- `lib/book_sources/source_engine/scripting/source_script_dom_api.dart`
- `lib/book_sources/source_engine/scripting/source_script_host_api.dart`
- `lib/book_sources/source_engine/scripting/source_script_text_api.dart`
- `lib/book_sources/source_engine/scripting/source_script_encoding_api.dart`（新增）
- `lib/book_sources/source_engine/scripting/source_script_java_compatibility.dart`（新增）
- `lib/book_sources/source_engine/scripting/source_script_html_formatter.dart`（新增）
- `test/source_runtime_pagination_test.dart`（新增）
- `test/source_text_replacement_test.dart`（新增）
- `test/source_script_compatibility_test.dart`（新增）
- `test/source_script_html_format_test.dart`（新增）
- `test/source_rule_html_compatibility_test.dart`
- `test/source_rule_engine_test.dart`
- `test/source_runtime_test.dart`
- `lib/book_sources/README.md` 与本计划

限制：尚未进行实际在线源、物理设备或平台发布构建验证。Java 类适配只覆盖
已实现的方法签名，并非完整 JVM/Rhino；Android 宿主 UI/任意 Java 字节码、
完整 Jsoup、所有字符集和繁简转换不在本地实现能力内。跨页捕获组若被替换规则
显式移动，其相对图片地址按整个匹配的起始页解析，该约定记录在 helper 与 README。
发布文件、阅读器自动翻页及其他任务的改动继续保留，由其各自任务负责。
本任务不提交、不推送、不发布。
