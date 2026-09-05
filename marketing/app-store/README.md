# App Store 与官网宣传素材

本目录保存可长期复用的 Open Reading 宣传素材，避免成品只留在个人桌面或临时目录。

## 上架入口

- [上架对接与待办](../../docs/app-store-release.md)：真实后台状态、账号配置、签名上传步骤及审核缺口。
- [商店文案](metadata.json)：简体中文与美式英文草稿；隐私政策 URL 留空表示尚未落实，不能作为已完成申报。
- [审核说明与隐私核对表](review-notes.md)：提审时需要提供的操作路径与资料。

2026-09-05 核查：下述六张宣传图尺寸合格，但画面包含 Android 状态栏，
不能直接作为 iOS 截图提交。它们保留作宣传参考，正式提交前须重新采集真实
iPhone 和 iPad 界面，并核对示例书籍、封面及正文的展示授权。

## 目录

- `screenshots/`：六张精选原始应用截图，统一为 1216×2640，保留真实状态栏和应用界面。
- `promotional/iphone-6.5/`：六张 1242×2688 的宣传图及整套预览；尺寸符合 iPhone 6.5 英寸槽位，画面仍需替换为 iOS 实际界面。
- 正式应用图标继续使用 [`assets/images/app_icon.png`](../../assets/images/app_icon.png)，不在本目录重复保存。
- 官网加载的压缩 WebP 位于独立仓库 `miloquinn/open-reading-web` 的 `app/static/product/`，由本目录的精选截图派生。

## 素材对应关系

| 原始截图 | 宣传图 | 主要内容 |
| --- | --- | --- |
| `screenshots/home.jpg` | `01-daily-reading.png` | 首页、目标与阅读计划 |
| `screenshots/library.jpg` | `02-library.png` | 书库与阅读进度 |
| `screenshots/reader.jpg` | `03-immersive-reading.png` | 正文阅读 |
| `screenshots/page-turn.jpg` | `04-page-turn.png` | 仿真翻页 |
| `screenshots/personalization.jpg` | `05-personalization.png` | 主题、字体与排版 |
| `screenshots/stats.jpg` | `06-reading-stats.png` | 阅读统计与成就 |

## 维护规则

- 产品界面发生明显变化时，应同时更新原始截图、App Store 宣传图和官网 WebP。
- App Store 图必须保持 1242×2688，不得直接拉伸原始截图。
- 官网静态资源或 CSS 结构发生不兼容变化时，模板 URL 必须更新版本查询参数，避免旧缓存与新 HTML 混用。
- 不在素材中加入尚未实现的功能、虚构 UI 或无法验证的设备声明。
