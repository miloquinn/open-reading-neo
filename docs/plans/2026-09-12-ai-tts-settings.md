# AI 与云端朗读设置优化

用户要求：让云端 TTS、AI 助手配置符合阅读应用风格，改善手机配置体验，并在设置中提供云端 TTS 入口。

## 实施与整理计划

1. 先运行已有 AI 设置、听书面板回归，保留协议、服务商配置、密钥存储与播放切换行为。
2. 复用 DESIGN.md 的信息架构、视觉语言与响应式约束：浮动子页面顶栏、主题色、16px 页面边距、受限表单宽度；避免多层卡片和巨大弹窗。
3. 云端 TTS 用同一独立页面承接设置和听书快捷入口，连接与音色分组，高级音频格式收起，固定保存；密钥可显隐、留空保留，清除为明确动作。
4. AI 模型编辑改为独立页面，预设可继续编辑，保留模型获取和协议帮助，明确编辑与当前使用状态。
5. 删除替代后的内嵌弹窗/弹层代码；不新增依赖。已有工作区改动保持原样。
6. 独立进程验证 widget suites，运行分析；真实 Flutter 渲染检查手机浅/深色、大字号与键盘空间。视觉判定保存在 .omx/state/ai-tts-settings/ralph-progress.json。

## 验收

- 设置 → 数据与服务能进入云端 TTS；听书入口打开相同页面，保存刷新播放配置。
- 保存、密钥保留/清除、非法地址、写入失败、取消与重试有测试证据。
- 模型服务商/协议切换、编辑/启用与错误提示保留；窄屏和放大文字无 overflow。
- 不宣称真实服务可用：真实 TTS/AI 网络请求需要用户服务凭据，真机键盘与播放另行记录验证缺口。

## 验证记录

- `flutter test --no-pub test/cloud_tts_settings_page_test.dart`：6 项通过；密钥保留/移除/取消、存储失败与重试、地址校验、320×568 + 1.4 倍字号 + 240px 键盘场景。
- `flutter test --no-pub test/reader_aloud_panel_test.dart`：13 项通过；听书入口打开共享配置页，原有播放/音量/计时器断言保持。测试桩显式声明不支持真实平台队列，使用 Navigator 关闭底部弹层并等待通知定时器。
- `flutter test --no-pub test/settings_page_test.dart`：9 项通过；设置入口使用共享播放服务，既有设置布局回归保留。
- `flutter test --no-pub test/reader_aloud_cloud_service_test.dart`：7 项通过。
- `flutter test --no-pub test/ai_configuration_test.dart test/ai_settings_store_test.dart`：10 项通过。
- `tool/preview_ai_tts_settings.dart` 使用真实 Flutter 与本机中文字体渲染；TTS 390×844 浅色、深色 1.4 倍字号及展开高级选项已检查。
- 本次不新增依赖，不更改 AI/TTS 请求协议。未使用真实密钥请求付费服务，未验证实体设备上的声音、输入法和系统返回手势。
- `flutter test --no-pub test/ai_settings_page_test.dart`：5 项通过；协议帮助、可编辑预设和保存、错误可见、同端点预设切换保留输入密钥、320×568 + 大字号键盘场景。相关自动化回归合计 50 项通过，stateful widget 文件最终分别在独立进程运行。
- 最终 `tool/preview_ai_tts_settings.dart` 渲染验证通过；浅色与深色 1.4 倍字号下，AI 概览、AI 编辑和 TTS 配置/展开更多选项均已检查。最终视觉判定 94/100，依据 DESIGN.md 的应用原生风格与可用性约束，不以复刻被否定的旧弹窗为目标。
- 本次 11 个 Dart 文件的定向 `flutter analyze --no-pub` 通过，`git diff --check` 通过。全仓分析另有既存 WebDAV 文件 `prefer_initializing_formals` 提示，本次未修改该并行工作文件。

## 修改文件

- `lib/pages/settings/cloud_tts_settings_page.dart`：新增共享 TTS 配置页。
- `lib/pages/settings/ai_model_editor_page.dart`：新增独立 AI 模型编辑页。
- `lib/pages/settings/ai_settings_page.dart`：替换旧大弹层，提供明显编辑入口与中性未配置状态。
- `lib/pages/settings/settings_page.dart`、`lib/pages/settings/parts/settings_layout_part.dart`：设置中增加云端 TTS 入口。
- `lib/widgets/reader_aloud_panel.dart`：听书快捷入口进入同一配置页，移除旧 TTS 弹窗，修复配置卡片 Material 层。保留此前已有的播放器布局改动。
- `test/cloud_tts_settings_page_test.dart`、`test/ai_settings_page_test.dart`、`test/settings_page_test.dart`、`test/reader_aloud_panel_test.dart`：对应交互、布局及导航回归。
- `tool/preview_ai_tts_settings.dart`：可复现的真实 Flutter 截图脚本。
- `DESIGN.md`、本文件：设计约束、实施计划与验证证据。

整理结果：删除 AI/TTS 原有内嵌大表单和依靠延迟释放控制器的旧路径，表单生命周期由各自页面持有；复用已有主题和子页面框架，无新依赖。未触碰其他任务的书源、同步与阅读内容改动。
