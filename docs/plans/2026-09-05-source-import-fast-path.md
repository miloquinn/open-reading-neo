# 书源导入取消文件上限与解析提速

## 要求与实施范围

用户要求取消导入文件大小限制、加快“导入后一直在解析”，并参考阅读书源格式的既有导入行为。此前导入界面的紧凑布局沿用，仅移除大小提示；保留工作区其他任务的修改。

动手前计划：增加超出旧上限的有效文件回归，保留结构校验、兼容分类、去重默认选择、取消和协议解析行为；对比相同合成数据，依据实际耗时减少重复处理，不以缩短超时或修改加载文案代替提速。

## 兼容实现对照

只读追踪 `ImportBookSourceViewModel.kt:134` 起的导入，以及 `:211` 起的比较：Gson 在后台从字符串或 InputStream 读取书源，预览前按原始 URL 和更新时间比较已有源，不做我方兼容标记扫描。`GsonExtensions.kt:92` 起实现 InputStreamReader/Gson，导入 ViewModel 没有固定字节上限。

本轮保留我方既有规范化去重与兼容结果，优化其实现；没有把它替换成参考实现的简化比较，也没有声称已经复制了流式读取架构。

## 修改文件与简化

- `lib/book_sources/source_engine/source_import_service.dart`：删除固定字节上限、下载进度/Content-Length 拦截和对应错误映射，删除默认总条数限制；下载结果已是 Uint8List 时直接复用。异步字节导入的解析与预览构建均放入 compute。统一 UTF-8/JSON 组合解码。
- `lib/book_sources/source_engine/source_config.dart`：默认不限制数量，显式传入 maxSources 仍受校验；提取 runnableCapabilities 供预览统计和保存共用，删除只为统计数量而构造完整注册对象的操作；静态大小写不敏感匹配器直接检查脚本，删除整段 toLowerCase 拷贝，同类标记找到后跳过后续搜索。
- `lib/book_sources/services/book_source_import_analyzer.dart`：删除字节上限，复用组合解码。
- `lib/pages/book_sources/widgets/book_source_add_flow.dart`：删除文件选择阶段的大小拒绝。
- `lib/l10n/app_{en,zh,zh_TW,ja}.arb` 与生成的本地化文件：移除上限提示和不再使用的文件过大错误。
- `test/book_source_large_import_test.dart`：新增真实 70 MiB 文件、10001 条和下载 Content-Length 回归。`test/source_config_test.dart`、`test/book_source_import_analyzer_test.dart` 补充兼容标记、能力、BOM/Unicode/非法输入保护；移除只断言 64 MiB 常量的旧测试。
- `tool/benchmark_source_import.dart`：同一组合成数据的分阶段计时工具。未新增依赖。

## 验证证据

新上限测试先在旧代码 RED：70 MiB 有效 JSON 被拒绝；10001 条被拒绝。修改后 5 项均通过：同步与后台导入 70 MiB；默认 10001 条；显式 maxSources:10 拒绝11条；可读响应声明128MiB Content-Length时不被提前拒绝。

核心测试 `source_config`、`book_source_import_analyzer`、`book_source_add_controller`、`book_source_dedupe_engine`、`book_source_large_import` 共73项通过。最后扫描实现调整后重新运行 source_config 的26项，仍通过。独立进程运行 add_flow 11项、management_page 9项、dedupe_review 4项、architecture 4项，全部通过（总计101个不同测试）。目标文件 dart analyze 无问题，dart format 与 git diff --check 通过。

首次完整基准发生机器负载波动，因此不使用其中最快一轮作最终结论。最终在同一进程、相同字节输入中交替对照5轮，以中位数报告。临时基线保留原扫描、完整对象统计与分开UTF8/JSON解码；当前路径调用实际 BookSourceImportAnalyzer.analyzeBytesAsync。先分别预热，样本生成不计入耗时，前后都包含后台任务启动及结果返回。

| 合成输入 | 修改前中位数 | 修改后中位数 | 耗时减少 |
| --- | ---: | ---: | ---: |
| 1000条 / 5,084,671 bytes | 125.878ms | 91.829ms | 27.0% |
| 2000条 / 57,611,271 bytes | 1247.333ms | 842.326ms | 32.5% |
| 10000条 / 15,746,671 bytes | 468.762ms | 384.351ms | 18.0% |

完整每轮值保存在 `/tmp/open-reading-import-paired-benchmark.log`，临时对照文件在 `.omx/import-performance-comparison/`。此对照不是运行另一客户端的跨应用测评。

## 仍需注意的验证边界

这些是 macOS Flutter VM 合成测量，未使用用户实际慢文件、Android/iOS真机，不承诺任意大小瞬间完成。JSON数据仍整包驻内存；取消会丢弃迟到结果，现有compute任务不能在解析中途终止。Web compute与UTF8组合解码使用平台回退，不具备原生isolate的线程/内存行为；大文件浏览器存储配额、Web Worker，以及超大批量保存的主线程工作，均未在本轮实现或验证。没有将预览解析回归冒称为所有平台的大文件保存端到端支持。
