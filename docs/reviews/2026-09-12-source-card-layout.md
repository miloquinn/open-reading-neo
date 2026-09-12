# 书源卡片与菜单触发器修订

用户反馈：卡片不适合圆形底板的三点按钮，收藏、开关和菜单挤占文字，长状态/分组有溢出。

## 修改

- `lib/widgets/app_menu.dart`：触发器样式与菜单表面/动画分开，新增 `AppMenuButtonStyle`；默认 plain，恢复卡片和列表中的无底板三点图标，保留至少44px点击区域。
- `lib/widgets/floating_subpage_scaffold.dart`：仅顶栏兼容封装显式使用 circular，继续从圆形按钮展开。
- `lib/pages/book_sources/widgets/book_source_management_source_card.dart`：上方保留40px图标/选择框、两行名称和说明、普通更多入口；元数据独立使用完整宽度；收藏/启停移到底部，避免挤占文字。长分组最多两行，超长内容省略并受宽度约束。
- 新增 `test/book_source_management_source_card_test.dart`、`tool/preview_book_source_cards.dart`；更新 `test/app_menu_test.dart`、`tool/preview_app_menu.dart` 和 `DESIGN.md`。

未添加依赖，未提交或发布，保留工作区既有修改。

## 验证

独立进程运行：app_menu 14项、floating_subpage_scaffold 4项、source_card 3项、book_source_management_page 13项均通过，共34项。卡片覆盖320/390宽度与1.0/1.4/2.0字号、长名称/分组、收藏、启停、菜单与选择模式文本对齐。

受影响7个文件的Flutter静态分析通过，git diff --check通过。真实Flutter渲染已检查暗色390px与浅色320px双倍字号，无overflow。证据：`artifacts/source-cards/book-source-cards-dark-390x844.png`、`artifacts/source-cards/book-source-cards-light-320x900-large-text.png`。

未进行真机触摸/帧率测试；未做平台构建或全仓回归。本次报告仅覆盖上述菜单与卡片改动。
