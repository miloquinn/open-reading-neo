# 平板布局调整

现状：820px 起启用固定 NavigationRail；iPad mini 竖屏未进入平板布局，较大 iPad 横屏被当作桌面。页面宽度与导航模式耦合。

实施边界：保留桌面侧栏与手机底栏，iOS / Android 窗口宽度 >=600px 且高度 >=500px 使用平板布局。分屏缩窄回退手机结构。复用既有导航材质、动画、用户排序/标签/尺寸设置，不加依赖，不改同步业务与已有脏文件。

1. 先运行现有导航尺寸和动画回归，新增平板断点、顶部安全区、切换与旋转回归。
2. 复用同一悬浮导航实现，平板顶置、横排图标文字；统一顶部内容避让，移除底栏空白。复用 PageView 状态保存但平板禁用整页横滑，避免与横向内容争抢手势。
3. 首页续读和阅读节奏分栏、最近阅读网格；书库按可用宽度计算密度；书源发现卡片优化；设置逻辑分栏；AI 保留舒适阅读宽度并适配新顶栏和键盘。
4. 运行相关回归与静态分析，渲染平板横竖屏、手机与深色模式截图，检查遮挡和溢出。visual-verdict 技能在当前安装中不可用，执行等价人工截图检查并记录结果。

阅读器、导入与设置子页优先保持已有行为，本轮覆盖主导航页面及共享导航。


## 最终实现

- 触控平台保留一套导航实现：平板顶置、手机底置；延续目的地排序、隐藏、尺寸设置、选中/按压动效与玻璃效果开关。大字号时平板导航改为图标和文字上下排列并增加高度。
- 平板顶部内容避让包括系统安全区、浮动导航与标题；标题栏随文本缩放增高。键盘打开时顶部导航保持可用；阅读器转场时导航滑出屏幕。
- 首页按可用内容宽度在单列和 3:2 双栏之间切换，近期书籍复用约168dp网格密度策略。
- 书库封面和卡片按可用宽度排列，保留用户密度设置；多选时单独预留底部删除栏空间。
- 发现页标准视图支持2–3列，列表模式保留目录组织。
- 设置宽屏按外观/阅读/通用与数据/高级/支持分栏，窄屏恢复原顺序和惰性列表。
- AI 对话列限宽760dp，历史记录用平板浮层；测量输入浮层实际高度，处理键盘、错误条、关联书籍和大字体造成的尺寸变化。

## 修改文件

| 范围 | 文件 |
| --- | --- |
| 断点与共用导航 | `lib/utils/layout_helper.dart`、`lib/pages/home/home_shell_page.dart`、`lib/pages/home/parts/home_shell_layout_part.dart`、`lib/pages/home/home_mobile_chrome.dart`、`lib/pages/home/widgets/home_bounce_navigation_item.dart`、`lib/pages/home/widgets/home_mobile_top_bar.dart` |
| 首页 | `lib/pages/home/home_mobile_dashboard_page.dart` |
| 书库 | `lib/pages/library/library_page.dart`、`lib/pages/library/parts/library_chrome_part.dart`、`lib/pages/library/parts/library_collection_part.dart` |
| 发现 | `lib/pages/book_sources/book_sources_page.dart`、`lib/pages/book_sources/book_sources_page_list_content.dart`、`lib/pages/book_sources/widgets/book_source_list_directory.dart` |
| 设置 | `lib/pages/settings/settings_page.dart`、`lib/pages/settings/parts/settings_layout_part.dart`、`lib/pages/settings/parts/settings_about_part.dart` |
| AI | `lib/pages/ai/ai_page.dart` |
| 回归 | 新增 `test/tablet_home_shell_test.dart`、`test/tablet_home_settings_layout_test.dart`、`test/tablet_ai_layout_test.dart`；扩充 `test/library_page_test.dart`、`test/book_source_discovery_page_test.dart`，明确 `test/home_dashboard_page_test.dart` 的桌面平台测试条件 |

简化：页面布局不再用侧栏作为平板的唯一判据；复用导航、网格密度和安全区指标；设置页面只调整组件组织；AI删除固定高度预估。

## 验证与限制

全项目 `flutter analyze --no-pub` 无问题，`git diff --check` 通过。

状态化测试按独立进程顺序运行，覆盖平板完整壳层、首页/设置、AI、书库、现有导航尺寸/动效/焦点/设置、阅读器返回、首页、设置、AI历史。AI测试覆盖2倍和3倍字号下末条消息不被输入栏覆盖；书库测试实际进入多选并滚动到最后一本。

截图使用真实Flutter组件和临时示例数据，覆盖834×1194竖屏、1194×834横屏、744×1133深色、600×960分屏和大字体、390×844手机回退及AI键盘状态。测试环境的示例封面采用生成的本地PNG；为规避flutter_tester缩放解码等待，预热续读封面的两种缩放缓存，不改动产品图片解码路径。截图用于布局验证，不代表真机玻璃材质与动画性能。

书源发现全文件合跑存在状态化测试超时，相关新增及代表性原有用例已分别通过；同时启动Flutter进程曾造成共享native_assets目录竞争，改为串行运行恢复正常。以上为测试基础设施信号。

尚未在实体iPad验证手势、键盘和GPU表现；本轮没有平台安装包构建或发布。没有修改既有同步业务、DESIGN.md或其他并行任务的文件。

参考：[Apple iPad顶部悬浮标签栏](https://developer.apple.com/documentation/uikit/elevating-your-ipad-app-with-a-tab-bar-and-sidebar)。

## 对齐复核计划（用户追加）

统一平板1200dp外框、28dp内边距；标题与主内容使用同一左右边界，首行内容使用同一顶部避让。修正设置在超宽窗口的限宽计算、书库竖屏与搜索框的不同边距、发现页筛选条额外限宽。首页双栏上下边缘等高对齐，保留AI内部独立居中的阅读宽度。先新增坐标回归观察失败，再调整共享尺寸并检查横竖屏及1366dp宽屏截图；不改业务。


对齐复核结果：

- 坐标回归先复现标题x=32、首页卡片x=28的4dp偏差；修复后误差断言控制在0.1dp以内。
- 所有平板主内容共用28dp内边距；1366dp窗口下统一左边界111、右边界1255。
- 首页标题、首卡、近期书籍左边界一致；横屏两张卡片上下边缘一致。
- 设置账号卡片、双栏内容与标题共用限宽；分区标题图标与卡片外边缘对齐。
- 书库竖屏/横屏/搜索框/多选底部操作统一边距；发现标准筛选、结果首排和目录搜索/条目统一左右边界。
- 本轮独立进程验证通过：平板壳层3项、首页/设置2项、书库5项、发现平板1项、发现手机列表1项；全项目静态分析无问题。横竖屏及1366dp宽屏截图已更新。

## 顶部渐变模糊（已选择第二方案）

去掉平板标题栏的整条玻璃面板，顶部独立布置从强到弱并在正文前归零的模糊背景。标题和操作始终清晰，悬浮导航复用现有实现。空间足够时标题/导航/操作同排；窄窗或大字号时导航和标题分两行，共用连续渐变背景，避免重叠。共享安全区指标负责同步改变内容起点，保持28dp基线。手机保留原导航与标题栏。

先验证现有壳层能复现固定玻璃面板，再验证平板无横向玻璃surface、同排中心对齐、窄屏回退、滚动内容可穿过模糊区域、关闭玻璃效果可降级。已有ProgressiveBlur只使用平均sigma，不能直接当作真实渐变模糊复用；新增局部顶部效果，不改变其他使用者。


第二方案实现与验证：

- 新增 `lib/pages/home/widgets/home_tablet_top_backdrop.dart`：单个局部 BackdropFilter，在过滤层内渐变擦除模糊结果，连续露出清晰背景；强模糊区域随实际控件底部延长，再24dp渐隐、末尾16dp完全透明。标题与按钮在其上单独绘制，保持清晰；关闭玻璃效果时跳过背景过滤。
- 新增 `lib/pages/home/widgets/home_tablet_toolbar.dart`；修改壳层 `home_shell_page.dart`、`parts/home_shell_layout_part.dart` 与 `home_mobile_chrome.dart`。共用左右边界；可用宽度足够时，标题/悬浮导航/操作按钮同排居中对齐；宽度不足或大字号时两排。进入书库多选时收起空导航行，保留底部操作。
- 简化：平板不再嵌套手机的整块 GlassTopBar，渐变背景只在壳层绘制一次，五个主页面继续复用同一导航与统一尺寸。未增加依赖或修改其他页面的旧 ProgressiveBlur。
- 本轮40项测试通过：像素渲染2、完整壳层3、尺寸9、系统栏3、导航动效7、焦点2、平板AI5、首页/设置2、书库5、导航设置2。各文件独立进程串行执行。
- 像素测试比较同一棋盘开关模糊时的局部对比度，验证顶部/中部/下部逐渐清晰以及底部采样像素与原图完全一致。完整壳层验证无玻璃面板、1194dp同排对齐、1366dp边界、横竖屏/600dp分屏、3倍字号、滚动标题固定、书库多选进入/退出、手机回退和键盘。
- 预览封面统一预热测试缓存，并断言可见RawImage已加载，避免测试截图出现空白封面；产品图像路径未改变。
- 全项目静态分析和差异空白检查通过。截图复核覆盖浅色/深色内容穿过顶区及大字号滚动。真机GPU渲染与滚动帧率仍未验证，本轮未构建或发布安装包。
