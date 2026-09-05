# 大型 TXT 编辑与增量同步改造

日期：2026-09-05。用户明确要求 200 MB、500 MB TXT 可编辑、可同步，避免内存随整书大小膨胀。

## 改造顺序与行为保护

1. 先保留现有 TXT 编码、真实原文、章节边界、定位迁移、保存事务与恢复回归；新增大型文件和无换行长段落场景。
2. 复用现有字节索引/流式读取能力，编辑器仅持有当前有界章节分片。哈希、编码转换、写回、版本恢复均流式处理；删除整本 readAsBytes/整本 String 及 64 MiB 拒绝路径，不以调大常量替代架构修复。
3. 保存以原文件范围复制到临时文件、替换目标范围、原子切换实现；保留崩溃 journal、原始字节和未修改部分。正常编辑不影响其他章节定位，分片边界变化按可靠映射/失效策略处理。
4. 同步按内容分块和版本清单复用未变化数据，首次上传完整数据、后续只上传缺失块。普通 WebDAV 无通用服务端拼接保证；云端完整 TXT 镜像与纯分块主存储的选择等待用户回答，不默默改变已有云端文件约定。
5. 大文件同步全流程避免整书内存物化；冲突、重试、条件提交及旧版本可恢复语义保持。
6. 使用真实生成的 200 MiB、500 MiB 文件，验证局部改动结果、未修改区间 hash、峰值 RSS/增量内存、上传字节数和失败恢复。测试按进程串行，禁止与其他 Flutter 命令并行。
7. 最终全项目静态分析、必要 reader/sync 回归、macOS 无签名产品构建；记录测量数据和协议限制，更新设计说明及过期 UI 上限文案。

不新增依赖，不修改发布签名、用户云端数据或无关工作区改动。

## 已实现与实测（2026-09-05）

原生 TXT 删除整书编辑/同步/导入的大小拒绝路径；Web 内存导入、系统分享入口及非 TXT 格式仍有各自限制。编辑器与原生大 TXT 阅读器复用 `streaming_txt_index.dart`，删除原大文件整书解码索引实现；单段默认约 32K UTF-16 单元。同步复用原有绑定、队列、文件事务与冲突机制，不另造业务状态机。

- v3 开关默认不改变现有 v2 绑定；开启前说明云端将是分块格式。A 升级后，B 从元数据描述跟随 v3，已修改的本机版本保留并参与正常冲突判断。
- 旧基线中已确认的内容块零请求复用；新块先校验/上传，当前清单最后 ETag 条件提交。上传中断可复用已传块，新增块和提交后的清单必须回读校验，接收按块和整书校验；流式写入带背压。取消与失败会清理本轮未完成的整书临时文件。
- 本地保存基线在构建临时文件后和原子替换前再次流式校验，避免大书保存期间外部修改被覆盖。

运行 `dart run tool/benchmark_large_txt_streaming.dart`，每组独立 Flutter 测试进程；夹具流式生成、内容块不高度重复，首次实际复制量等于整书大小。修改为插入 7 字节，编辑区两侧的流式 SHA-256 均保持一致。

| 夹具 | 打开编辑段 | 保存 | Flutter 测试进程峰值 RSS | 保存阶段新增峰值 RSS | 新增正文块字节 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 200 MiB 有章节 | 8.120s | 25.077s | 261.56 MiB | 58.34 MiB | 141,599 B |
| 500 MiB 有章节 | 20.643s | 64.119s | 240.69 MiB | 44.69 MiB | 141,599 B |
| 200 MiB 无标题、无换行 | 8.312s | 25.948s | 276.50 MiB | 53.22 MiB | 76,070 B |

500 MiB 首次传输 524,288,000 字节；插入后新增正文块 141,599 字节（约 138 KiB），另需提交版本清单和 HTTP 元数据。以上传输量由磁盘模拟传输实际写入计数，**不是用户真实 WebDAV 网络测速**。生产 transport 另用模拟 DAV 回归验证新增块的 HEAD/PUT 请求数、旧块零请求、ETag 冲突和损坏拒绝。

200→500 MiB 最坏阶段新增 RSS 变化为 -13.66 MiB；各阶段均低于约定的 192 MiB 增量门槛。本次本机结果支持内存不按整书内容线性增长，不能外推所有设备固定使用同样内存。测试进程 RSS 含 Flutter 测试运行时，非移动端应用真机峰值。

### 实际成本与未覆盖项

- 本地保存仍需 O(N) 顺序 I/O、临时完整文件、历史快照和全书校验，500 MiB 本机保存约 64 秒；目前不宣称瞬时编辑保存。磁盘不足返回失败并保留可恢复文件。
- v2 普通 TXT 模式仍完整流式上传；v3 在云端为 App 分块格式，本地始终有完整 TXT。旧 v2 副本保留但不再更新。
- v3 暂无云端历史清单目录/保留策略，本机历史及本机/云端孤立块自动回收尚未实现。
- 未连接用户真实 WebDAV，也未完成两台物理设备、移动端文件提供器或真机内存验收。

原始完整指标：本次验证目录 `/tmp/open-reading-large-txt-validation/benchmark-final.json`；日志 `/tmp/open-reading-large-txt-benchmark-final.log`。

协议依据：[RFC 9110 Partial PUT](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.5)。普通 WebDAV 的局部 PUT 不具备跨服务商通用保证，客户端分块格式用于避免依赖服务端拼接扩展。

## 最终验证与修改入口

- 22 个回归测试文件共 145 个测试通过，另有上述 3 组实际大文件基准。最终结果见 `/tmp/open-reading-large-txt-validation/verified-regressions.json`。
- `flutter analyze --no-pub`：No issues found；`git diff --check`：通过。
- macOS Debug 产品无签名构建：`xcodebuild ... CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`，BUILD SUCCEEDED。未执行签名发布、安装或用户云端操作。
- 原生阅读索引：`lib/core/reader/streaming_txt_index.dart`、`lib/core/reader/txt_chapter_parser.dart`、`lib/pages/reader/native/native_reader_parsers.dart`。
- 编辑与导入：`lib/services/books/txt_edit_service.dart`、`lib/services/books/book_import_service.dart`、`lib/pages/reader/native/txt_chapter_editor_page.dart`、`lib/pages/library/import_book/import_book_page.dart`。
- 增量传输：`lib/services/sync/txt_chunk_manifest.dart`、`chunked_txt_webdav_transport.dart`、`mutable_txt_sync_service.dart`、`webdav_client.dart`、`webdav_book_file_service.dart`、`webdav_sync_controller.dart`。
- 界面：`lib/pages/settings/sync/book_file_sync_page.dart`、`txt_sync_details_page.dart`、`txt_sync_storage_mode_control.dart` 及中/英/日/繁体文案。

本次删除大 TXT 整书解码索引路径，复用共享扫描器与既有文件事务/同步状态；没有新增依赖。工作区中的其他书源、发布等既有修改保持原样。
