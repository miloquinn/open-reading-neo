# 共享菜单交付与验证

## 结果

所有操作型 `PopupMenuButton` 和书库 `showMenu` 已迁移到共享菜单，听书音色选择同样复用。原书源管理顶栏组件保留兼容封装，删除旧缩放/位移弹层实现。新路由在触发按钮处连续插值裁切边界和圆角，360ms展开、280ms收回，业务动作在收回完成后执行。保留选择、禁用、分组、主题及现有回调；增加安全区约束、长列表滚动、大字号换行、键盘与减少动态效果支持。

## 本次涉及文件

共享实现：
- `lib/widgets/app_menu.dart`（新增，唯一菜单表面与动画）
- `lib/widgets/floating_subpage_scaffold.dart`（旧入口兼容封装，删除重复实现）
- `lib/widgets/reader_aloud_panel.dart`（仅音色选择改用共享菜单，其余既有修改保留）

迁移入口：
- `lib/pages/book_sources/widgets/book_source_management_source_card.dart`
- `lib/pages/book_sources/widgets/book_source_organization_actions.dart`
- `lib/pages/book_sources/book_source_maintenance_page.dart`
- `lib/pages/library/library_page.dart`
- `lib/pages/settings/custom_fonts_page.dart`
- `lib/pages/reading_stats/detailed_stats_page.dart`
- `lib/widgets/reader_control_chrome.dart`
- `lib/widgets/reader_navigation_sheet.dart`
- `lib/widgets/reader_annotated_text_page.dart`

测试与规范：`test/app_menu_test.dart`、`test/floating_subpage_scaffold_test.dart`、`test/book_source_management_page_test.dart`、`test/book_source_management_organization_test.dart`、`test/reader_annotations_navigation_test.dart`、`test/txt_unresolved_navigation_test.dart`、`test/source_edit_page_test.dart`、`tool/preview_app_menu.dart`、`DESIGN.md`、`docs/plans/2026-09-12-shared-menus.md`。

未新增依赖。保留工作区原有未提交修改，未提交或发布。

## 验证

各 widget 文件使用独立 Flutter 测试进程，未合并有全局状态的测试套件。

| 文件 | 结果 |
| --- | --- |
| test/app_menu_test.dart | 13通过：真实裁切起点/中间/终点、反向收回、途中取消连续性、回调顺序、禁用、滚动、安全区、放大文字、减少动画、Escape、方向键/回车、选中语义、焦点恢复 |
| test/floating_subpage_scaffold_test.dart | 4通过 |
| test/reader_aloud_panel_test.dart | 17通过，含音色选择后刷新播放 |
| test/book_source_management_page_test.dart | 13通过 |
| test/reader_control_chrome_test.dart | 5通过 |
| test/reader_navigation_sheet_test.dart | 10通过 |
| test/book_source_management_organization_test.dart | 通过 |
| test/reader_annotations_navigation_test.dart | 通过 |
| test/txt_unresolved_navigation_test.dart | 通过 |
| test/library_page_test.dart | 通过 |
| tool/preview_app_menu.dart | 通过，真实Flutter逐帧渲染 |

书源管理4处测试原来只等待单帧或固定时长；现在等待菜单关闭及后续界面稳定，保留所有原断言。

受影响文件 targeted `flutter analyze` 无问题，`git diff --check` 通过。全仓分析早先只有一个独立风格提示；最终复查时工作区其他文件仍在变化，出现同步服务与书架服务的方法缺失、接口不一致等错误（最新快照64项，日志 `/tmp/open-reading-menu-analyze-final.log`）。这些文件不在本次菜单改动范围，未覆盖其他工作的修改，不能将当前全仓分析报告为通过。上表为各文件实际运行时的独立测试结果。检索确认 `lib` 中无直接使用原生 `PopupMenuButton` / `showMenu` 的操作菜单。

## 独立问题与边界

两项页面测试在临时恢复原生菜单后仍同样失败，确认不由本次菜单迁移引入；对照结束后均恢复共享菜单：
- `source_edit_page_test.dart`：保存后编辑页面未关闭。原生对照日志 `/tmp/open-reading-menu-ab-source-edit-native.log`。
- `detailed_stats_page_test.dart`：找不到“阅读总览”文案。原生对照日志 `/tmp/open-reading-menu-ab-detailed-native.log`。

未修改上述无关保存逻辑或统计页面文案，未跳过任何断言。AI协议、书源类型等编辑表单下拉框保留；系统文本选择工具栏不在本次范围内。

未做 Android/iOS 真机帧率或触摸手势测试，也未执行平台发布构建。

## 视觉证据

`artifacts/app-menu/app-menu-morph.gif`：390×450、24张真实Flutter渲染帧，展示顶栏圆形按钮展开和收回。目录另含浅色、深色大字号、底部向上展开、60ms/100ms等中间帧。目视检查表面圆角、图标对齐、文字可读性与安全区通过。二进制预览保持未跟踪。
