# 书源导入与管理响应性

本次直接执行已有功能的体验修复。保留工作区已有书源发现、阅读器和同步改动，不增加依赖。

已确认：导入 route 以 StatefulBuilder 手动刷新，异步完成缺少统一生命周期保护；输入地址变化不会废弃旧预览；下载、解析、保存共用一个笼统 loading。管理列表有反复分组和状态复制，整理进度会触发整个管理页重建。

改动前先跑既有导入、管理和整理回归。随后：
- 用独立有生命周期的导入组件接管监听、文件选择与关闭；统一链接/JSON 入口，输入区与预览可滚动，主要动作留在底部。显示下载、解析、保存阶段；分析可取消，保存期间避免重复提交或提前关闭。
- 编辑地址立即废弃旧预览；文件选择异常和空结果保持可恢复；明确显示识别数与待导入数量，保留协议开关和访问责任确认。
- 将实际阻塞 UI 的聚合解析/去重放到后台；修复无意义的串行重试和重复解析（以网络回归为准）。
- 复用管理列表计算结果，避免整理每个进度通知重建整个管理页；保留分组、筛选、批量操作和全部断言。

验证包括迟到异步结果、关闭弹窗、输入变更、保存保护、窄屏与大字体、后台解析与管理进度回归。Flutter stateful widget 测试必要时逐项独立进程。静态分析、格式、结构检查、产品构建分别报告。实际 Flutter 预览并保存视觉验收 JSON；本机未安装 visual-verdict skill，按同一验收要求人工检查真实渲染图。模拟数据仅用于测试/预览，不代表真机帧率或外部书源可用性。

## 最终实现

- 导入面板沿用应用主题和分段胶囊，短文件标签、两步提示、可滚动表单、固定底部操作、实际导入数量、错误详情与直接超时恢复说明。关闭、文件选择异常、地址编辑、协议开关和保存防重入均有明确处理。
- 新增 `widgets/book_source_add_flow.dart` 管理路由生命周期，取代在管理页内交错的 StatefulBuilder 回调；保存时禁止关闭，读取期间可以取消。
- 链接导入共用 30 秒总预算；真正取消 DNS 后续请求、重定向、嵌套队列和独立 ORSP 探测。嵌套单项失败保留成功书源；下载与解析阶段随实际工作更新。
- 聚合预览和两类去重面板的模式计算移至后台。确认去重直接传回已计算的预览，避免再次全量分析；兼容性报告、选择汇总复用缓存。
- 管理状态复用不可变列表和筛选缓存，分页不复制整表。整理进度按 100ms 合并通知，运行状态变化才重建管理页；重复组列表按需构建。状态和视图缓存归入 `controllers/book_source_management_state.dart`，保留原 controller 导入兼容并满足每模块少于 800 行限制。

## 验证与范围

- 68 项相关回归通过：导入分析/控制器 22、导入界面 11、管理控制器 12、管理整页 9、整理协调器 3、整理面板 3、去重面板 4、书源架构 4。各测试文件独立进程顺序验证，未跳过断言。
- 性能结构回归确认 100 次密集进度回调合并为 2 次运行中通知；分页/选择复用筛选缓存；40 个重复组仅构建首屏部分。此数据是通知/构建次数，不是设备 FPS。
- 本次范围的 Dart 静态分析、格式检查、`git diff --check` 通过。macOS Debug 产品构建成功，构建时使用临时命令行 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`；没有修改持久签名配置或新增依赖。构建准备导致的 Podfile.lock 生成变化已恢复。
- 全仓分析受并行 TXT 工作影响：先看到基准工具的 exit 名称冲突，随后最后一次全仓扫描报 `lib/core/reader/streaming_txt_index.dart:550` 的 `sourceEnd` 未定义及另一处格式提示。它们不属于本次书源改动，未在此任务修改；不把它们表述为书源或平台构建失败。
- 实际查看 Flutter 渲染的导入预览、文件错误、深色 1.3 倍字体三张图；中英日 1.6 倍字体的 360×640 布局有组件测试。预览工具 `tool/preview_book_source_import.dart`，输出 `.omx/book-source-import-previews/`；验收 JSON 在 `.omx/state/book-source-import/ralph-progress.json`。预览数据为模拟书源。
- 未做 iOS/Android 真机帧率、触摸或屏幕阅读器验证，也未对用户实际书源站点做网络可用性保证。

主要改动文件：`book_source_management_add_source.dart`、`book_source_management_page.dart`、`widgets/book_source_add_flow.dart`、`widgets/book_source_add_panel.dart`、`widgets/book_source_dedupe_review_sheet.dart`、`widgets/book_source_management_list.dart`、两个书源 controller 及管理 state part、`book_source_import_analyzer.dart`、`source_import_service.dart`、`book_source_maintenance_coordinator.dart`。另有四语言 ARB/生成本地化、相关回归测试与手动预览工具。
