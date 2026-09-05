# 书源双视图与动效

用户已认可同一套胶囊视觉的目录、标准推荐和标准分类设计稿。直接更新现有 Flutter 页面，保留真实书源、主题、导航和请求模型。

- 目录：来源分组与轻分割线，分类胶囊，保留可搜索与按需展开。
- 标准视图：书源胶囊、滑动分段选中底板、顺序固定的分类横条。推荐展示封面，分类与最新采用简洁书籍行。
- 动效：按下 97% 与回弹；选中色渐变；内容先短淡出再淡入，过渡只保留一棵懒加载 sliver 树。异步结果在过渡中更新时采用最新状态，旧内容退出时不可点击。
- 返回目录：在内容不可见的切换时刻恢复原滚动位置，避免先跳顶再切页。
- 兼容：遵从减少动态效果；支持深色、自定义主题、键盘和大字体；不添加依赖、不改请求协议。

验证：控件选中/按压/减少动态效果、切换中连续更新与销毁、目录返回滚动位置、分类加载与错误、长列表懒加载；发现页原有测试逐项独立进程执行。运行 Dart 格式检查、Flutter 静态分析和产品构建；用实际 Flutter 渲染检查两个视图。

基线：现有发现页组合测试出现 pumpAndSettle 超时；`pull to refresh invalidates cached responses before reloading` 单独进程通过。按现有 CI 隔离方式验证，不据此改业务逻辑。

架构检查要求每个书源模块少于 800 行；将分类内容构建方法原样归入既有 `book_sources_page_list_content.dart`，与其他目录/书籍 sliver 同处一处。已有目录、分类、滚动返回回归先通过，再做此职责归位。

补充修复：重复点击当前分区保持书单；从其他分区返回已缓存的分类时重新关联首个分类书单，避免只剩分类栏。已先复现失败再通过控制器回归。

## 验证结果

- 书源控件、内容过渡、封面布局、目录展开、控制器、架构共 37 项通过。
- 发现页 26 项逐个独立进程通过，含快速切换、滚动恢复、500 个分类的懒加载与搜索。
- 最终回归在临时隔离 checkout 上覆盖本任务文件执行，避免同工作区其他阅读器任务的正在编辑状态影响结果。
- 最终书源文件与回归测试的静态分析通过；随后重新检查当前完整工作区，`dart analyze` 也通过（No issues found）。格式和 `git diff --check` 通过。
- macOS Debug 产品构建通过：使用命令行 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 验证编译，无持久签名设置变更。该构建发生在最后的分类缓存修复之前；最终修复另经回归与静态分析。
- 未做 iOS/Android 真机触摸、帧率或屏幕阅读器验收。

可复现预览：`tool/preview_book_source_ui.dart` 使用真实页面组件和模拟书源，以 390×844 渲染推荐、目录、分类与深色 1.3 倍字体。各 capture 单独运行；可设置 `BOOK_SOURCE_PREVIEW_FONT` 指向中文字体、`BOOK_SOURCE_PREVIEW_COVER_PATH` 指向示例封面。封面仅写入临时预览缓存，不添加到生产资源。预览覆盖页面内容，不代表手机导航外壳或真机截图。

## 主要文件

- `lib/pages/book_sources/book_sources_page.dart` 与既有 `book_sources_page_list_content.dart`：双视图内容切换和滚动恢复。
- `lib/pages/book_sources/widgets/book_source_pill.dart`、`book_source_sliver_transition.dart`：复用胶囊与单棵内容树过渡，避免重复页面树。
- `book_source_discovery_sections.dart`、`book_source_list_directory.dart`、`book_source_category_picker.dart`、`sourced_book_cards.dart`：推荐、目录、分类、选择器与书籍行。
- `lib/pages/book_sources/controllers/book_sources_controller.dart`：修复分类缓存返回空书单。
- 相关书源测试与 `.github/workflows/pr-checks.yml` 的独立发现页用例清单；`tool/preview_book_source_ui.dart` 为手动预览工具。

## 视觉验收

实际查看 `.omx/book-source-ui-previews/` 中推荐、目录、分类、深色大字体四张 Flutter 渲染图，并与已选分类设计稿对照。胶囊、分段选中底板、封面文本层次、细分割线和大字体换行符合方案；窄屏分类轨道保持可横向滚动，末端固定全部分类入口。动态行为由针对过渡中间帧、快速更新、减少动态效果与返回位置的测试验证，静态图片本身不作为动画流畅度证据。

示例截图复用同一张生成山水封面，真实应用仍使用原书源封面和缓存。沿用应用现有“发现”标题、导航与主题色，不把设计稿中的虚构书源/封面写入产品。

## 书源协议区分

根据用户补充并对照阅读书源格式的发现页参考实现：阅读兼容书源展示自己声明的发现频道，不套用 ORSP 的固定推荐/分类/最新栏目。实现只调整控制器的分区来源索引，继续复用现有频道胶囊与内容过渡：ORSP 按能力提供推荐/分类/最新；阅读书源仅进入内部频道浏览分区，因此不显示通用分段栏。混合书源的推荐和最新请求只发给 ORSP，阅读书源浏览始终携带所选频道。源自己命名的频道（包括名为“最新”的频道）不被删改。

无效或过期的分区切换会被忽略，避免切换书源后旧栏目回调重新触发不适用的请求。预览中的“阅读书源”也改用真实 readingSource 协议标记和兼容功能开关，以免用 ORSP 假数据掩盖差异。

协议区分验收：控制器与架构 18 项、实际页面协议切换及既有目录/快速切换 4 项通过；定向静态分析通过。已目视对比 `reading-channels-light-390x844.png` 与 `categories-light-390x844.png`：前者只有阅读书源自带频道，后者保留 ORSP 通用分段栏，二者书单正常显示。未另做真机验收。
