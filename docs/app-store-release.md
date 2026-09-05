# App Store 对接与发布

本页记录 2026-09-05 对 iPhone/iPad 版的准备工作。书源与漫画源由另一条开发线处理；
不要把其未完成的工作混入上架验证结论。macOS 商店版需独立验证签名、沙盒和购买流程。

## 本轮结果

| 项目 | 状态 |
| --- | --- |
| App Store Connect App | 已登录并确认现有“开元阅读”，Bundle ID 为 `com.niki.xxread` |
| 商店版本 | iOS 草稿从空白 `1.0` 对齐为项目当前版本 `2.6.4`，仍为“准备提交” |
| 类别 | 已保存为“图书”，保留现有中文名称“开元阅读”和副标题“让阅读连接世界” |
| 文案 | 简体中文、英语（美国）的描述、推广文本、关键词、支持与营销网址已填写保存 |
| 截图 | 现有六张 PNG 均为 1242×2688，但含 Android 状态栏；未上传，需重采 iOS 界面 |
| Apple 登录 | 客户端权限与接口已有，线上公开配置为启用；尚未进行本轮真机登录验证 |
| 内购 | 后台已有同 ID 的“永久高级版”非消耗型商品，准备提交；与客户端和线上配置一致 |
| 现有内购价格 | 中国大陆 ¥28.00、美国 $3.99，销售范围为所有国家或地区；本轮未调整 |
| 隐私清单 | 已补原生省电设置直接读取 UserDefaults 所需的 `CA92.1` 声明 |
| 签名/上传工具 | 已实现并通过模拟工具测试；默认导出，显式 `--upload` 才上传 |
| API 文案工具 | 已复用现有管理密钥完成真实 API 认证，读取到正确 App、版本、历史构建和内购商品 |
| 真正发行 | 未完成签名归档、未上传构建、未提交审核、未发布商店版本 |

商店后台：[开元阅读版本草稿](https://appstoreconnect.apple.com/apps/6756944051/distribution/ios/version/inflight)。
版权字段按项目现有 `LICENSE-MIT-LEGACY` 填为 `2026 miloquinn`；提交前需由权利人核实。

## 目前不能直接提审的事项

1. **账号删除**：客户端和官网后端都没有用户自助删除流程。需提供身份确认、
   账号与相关数据删除、会话清理，以及适用时的 Apple 授权撤销。不能用退出登录代替。
2. **公开隐私政策**：官网源码未提供隐私政策/服务条款页面。文案 JSON 的
   `privacyPolicyUrl` 故意留空，不将猜测的 URL 写进商店。
3. **内购完整性**：后端已有签名交易验证与重复交易约束，但缺少 App Store Server
   Notifications V2 退款/撤销到权益状态的同步。现有 `/api/v1/auth/apple/notifications`
   是 Apple 登录通知，不是内购退款通知，不要填到 App Store 服务器通知 URL。
4. **商品与权益说明**：线上 `features` 为空，应用文案称高级会员暂未提供额外功能。
   需要先确认销售的具体权益、正式价格及审核描述，不能承诺尚不存在的解锁功能。
5. **实际设备截图**：需真实 iPhone 和 13 英寸 iPad 截图；勿拉伸 Android 图冒充。
   示例书籍、正文、封面的展示权也需要核对。
6. **账号资料**：审核联系人、审核账号、发行地区、年龄分级、内容版权回答及适用的
   备案/交易商信息待核实。后台现有 4+ 不能替代对新增内容访问功能的问卷复核。
7. **正式工具链与真机验证**：本机选中 Xcode 27 Beta（仅发现 Xcode-beta.app），
   不能把本机检查视为正式上传资格。签名、iCloud、登录、内购/恢复/退款需真实验证。

具体审核说明和隐私数据核对表见 [review-notes.md](../marketing/app-store/review-notes.md)。
对接后端位于相邻 `open-reading-web` 仓库；本轮只读检查，未修改或部署该服务。

## 签名环境

使用 Apple 接受的正式版 Xcode 26 或更新版本、对应 iOS 26 或更新 SDK、项目的
Flutter 版本、CocoaPods 和 Python 3.9+。Node 工具要求 Node 20+。仓库原有跨平台
release workflow 仍生成未签名 IPA，不会因本次改动自动向 Apple 上传。

Apple Developer 中的 App ID 与 App Store Connect 中的 App 必须同属正确团队：

- Bundle ID：`com.niki.xxread`。
- Sign in with Apple、Associated Domains、iCloud Documents 权限与工程一致。
- iCloud 容器：`iCloud.com.niki.xxread`。
- 关联域：`webcredentials:open.xxread.top`，核对线上 AASA 与正式签名团队。
- StoreKit 商品 ID：`com.niki.xxread.premium.lifetime`，类型为非消耗型。
- 自动签名需有相应证书/描述文件权限；导出会请求 App Store 分发签名。

本轮已在 `$HOME/.private_keys/appstoreconnect.env` 配置私有环境，引用已有 API 私钥，
没有新建 Apple 密钥或扩大权限。私有 env 文件与 `.p8` 保存在仓库之外，权限为 `600`。
避免将这些文件加入同步目录。脚本不读取仓库
里的密钥，不修改 Keychain 设置，也不把密钥值写入仓库。需要的环境变量：

| 变量 | 用途 |
| --- | --- |
| `IOS_TEAM_ID` | 实际 Apple Developer Team ID |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | 该 API Key 所属的 Issuer ID |
| `ASC_KEY_PATH` | 已存在 `.p8` 私钥的绝对路径（仓库外） |
| `DEVELOPER_DIR` | 可选：明确选择已安装的正式版 Xcode |

API Key 必须具备相应 App/签名权限。已有 macOS 公证 API Key 只有在权限匹配时才可复用；
Sign in with Apple 的 `.p8` 不能替代 App Store Connect API Key。
本地只导出时可以不设 ASC 三项，改用 Xcode 已登录账号和现有签名权限。

## 命令

从仓库根目录执行。以下 build number 仅为示例；先检查 Apple 中当前版本已有
构建，再选一个未使用且递增的号码。真实 API 返回的历史构建包括 `260824002` 等
日期型编号，状态为 `VALID`。因此保留项目现有日期型编号，不按旧文档的位数限制
强制改号；当前 Apple 文档要求一至三个点分整数。脚本只做格式检查，最终仍由 Apple
校验递增关系和重复编号。

```bash
# 加载已配置的私有环境（不输出其内容）。
set -a
source "$HOME/.private_keys/appstoreconnect.env"
set +a

# 只检查工具链和配置，不构建、不访问 Apple 服务。
bash tool/app_store/build_ipa.sh --check --build-number 260905001

# 只预览本地文案，不需要 Apple 凭据。
node tool/app_store/connect.mjs metadata

# 已加载私有环境变量后，只读检查商店版本、构建与商品。
node tool/app_store/connect.mjs status --version 2.6.4

# 默认只生成签名 IPA。
bash tool/app_store/build_ipa.sh --build-number 260905001

# 或：使用新的未占用构建号，归档并上传到 App Store Connect。
bash tool/app_store/build_ipa.sh --build-number 260905002 --upload

# 仅向已存在、可编辑的版本同步文案；不会创建 App/版本或提交审核。
node tool/app_store/connect.mjs metadata --apply
```

`--build-name` 可覆盖商店版本号，默认读取 pubspec。脚本不修改 pubspec 或
project.pbxproj；会刷新 Flutter 的本地生成配置，并以 `pod install --deployment`
保持 CocoaPods 锁文件。不要与另一个构建进程同时运行归档。

产物在 `build/app-store/<version>-<build>/`，目录仅当前用户可访问。已有目录时拒绝
覆盖，请保留旧产物或使用新构建号。导出模式生成 IPA 和 `SHA256SUMS`；上传模式使用
`xcodebuild -exportArchive` 的 `destination=upload`，不保证另留可下载 IPA。
`build.log` 是本地私有分发日志，不上传为公开 CI artifact。

API 同步只修改版本的描述、关键词、推广文本、支持/营销 URL 和可选更新说明，
应用名称/副标题/隐私 URL 仍需在 App 信息/隐私页核对。工具只查前 200 条状态记录并报告
分页限制；不是完整账单或会员审计工具。多个语言写入不是事务，失败后可再次运行，
已一致的字段会跳过。

## 验证与发布顺序

1. 集成并检查最终候选代码；记录 Git commit/tag。若触发原跨平台发布，遵守现有
   tag-triggered release 流程，不创建空的公开 Release。
2. 运行下列工具测试、项目分析与相关 Flutter 回归。状态型 widget 测试按仓库约定
   独立运行，不把测试进程挂起误报成产品构建失败。
3. 归档后验证包身份、构建号、隐私清单、签名；导出配置使用 Production iCloud。
4. 上传后在 App Store Connect 确认目标构建及处理状态，等 Apple 处理完成再测试。
5. 真机完成登录/文件导入/iCloud/朗读/购买/恢复/账号删除回归，补全审核资料与截图。
6. 明确最终售价、地区、隐私和内容版权信息后，再提交审核。上传构建不等于提审，
   提审也不等于获批或上架。

```bash
python3 -m unittest discover -s tool/app_store -p 'test_*.py' -v
node --test tool/app_store/connect.test.mjs
node tool/app_store/connect.mjs metadata
plutil -lint ios/Runner/Info.plist ios/Runner/Runner.entitlements ios/Runner/PrivacyInfo.xcprivacy
flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings
flutter test --no-pub test/apple_purchase_service_test.dart
flutter test --no-pub test/account_service_test.dart
git diff --check
```

本轮实测：Python 15 项、Node 18 项、Flutter 内购 3 项、账号服务 24 项通过；
plist、脚本语法、workflow YAML 解析、文案本地预检通过。分析无 error，有 3 条来自
并行开发书源文件的 warning/info；未为此改动另一条开发线。
真实 API 已认证成功；历史有 15 个有效构建，但不能据此声称本轮候选包已验证。
未执行完整 iOS 归档、App Store 上传、真机与购买沙盒验收。
新增 CI 仅做工具/文案验证，不应当被描述为产品构建已通过。

Apple 依据：[SDK 要求](https://developer.apple.com/news/upcoming-requirements/)、
[上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、
[API 密钥](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)、
[构建号](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)、
[隐私 API 声明](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)。
