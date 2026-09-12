# App 审核资料草稿

这份资料用于准备审核信息，不代表已向 Apple 提交。提交前必须逐项按最终候选包复核。

## 审核操作说明（英文草稿）

Open Reading is a local-first ebook reader. Basic local reading does not require
an account. Import a legally distributable TXT or EPUB document from Files into
the library, open it, adjust fonts/themes and page-turning preferences, and add
bookmarks or notes. Reading statistics are available in the app.

Optional account features support Sign in with Apple and other sign-in methods.
The lifetime non-consumable in-app purchase (com.niki.xxread.premium.lifetime)
uses StoreKit 2 and server-side transaction verification. It unlocks additional
compatible source protocols and trusted local/private-network sources. These
features become available under Settings > Advanced Features and require the
member to enable them. Non-members do not see the advanced settings section.
The membership screen describes both benefits before purchase, displays the
App Store price, and provides readable membership terms, privacy information,
and the Apple standard EULA. The purchase is one-time and does not auto-renew.
Restore Purchases remains available to signed-in users, including active members,
and explicitly synchronizes with the App Store before server verification.
Use the same Apple Account for restoration. If the former Open Reading account was deleted, sign in to a new Open Reading account and use Restore Purchases to link the retained Apple purchase again.
Active members on iOS can open the system refund request sheet; Apple decides
whether to approve the request. A submitted request is not treated as a refund.
Provide a dedicated review account to test account functionality; do not use
the developer's personal credentials.

Third-party content sources are added by the user. The official app does not
bundle a third-party source directory or commercial books. Provide a stable,
authorized sample source for review if source functionality is included in the
submitted build. Document all source and comic functionality honestly after
the separate source implementation is complete.

AI requests use a service configured by the user. Explain which content is sent
and where consent appears in the final build. Background audio is used for
reading aloud.

## 需要补齐的材料

| 项目 | 当前状态 / 完成标准 |
| --- | --- |
| 审核联系人 | 后台填真实姓名、电话、邮箱；不放在公开仓库 |
| 审核账号 | 后台私密字段填写；测试登录、多因素验证及权限，避免审核时被一次性验证码挡住 |
| 本地示例书 | 使用自有或已获授权的 TXT/EPUB，保证能离线导入；不拿未知版权书籍作为附件 |
| 书源/漫画源示例 | 等另一条开发线完成，用稳定且有授权的服务验证；注明联网与配置步骤 |
| 账号删除 | 客户端与线上 20260912-apple-account-review 后端均已实现；入口：设置 → 账号 → 账号安全 → 注销账号。2026-09-12 已通过真实 PostgreSQL 的删除/购买恢复回归，仍需最终候选包真机全流程及录屏；后台所有者须先移交权限 |
| 内购 | 核实商品、价格、权益描述、税务协议，使用沙盒和 TestFlight 验证购买/恢复/退款 |
| 截图 | 重新采集 iPhone 与 13 英寸 iPad；现有宣传图包含 Android 状态栏 |
| 年龄分级 | 后台现有 4+，尚未按新增书源/漫画功能复核；按最终可访问内容回答问卷 |
| 发行地区 | 尚未确认；中国大陆备案、欧盟交易商资料由账号持有人根据实际情况提供 |

## App Privacy 填写依据

不要因为本地优先，或 `NSPrivacyCollectedDataTypes` 为空，就勾选“未收集数据”。
下面是按现有客户端/官网后端得到的核对项，最终申报取决于真实部署、保留期限、
第三方服务及 Apple 对 collected/linked/tracking 的定义。

| 数据 | 现有用途 | 提交前核对 |
| --- | --- | --- |
| 邮箱、显示名称、用户 ID | 登录、账号资料、会话 | 与账号关联；用于 App 功能；核对保留与删除期限 |
| 头像 | 用户主动上传的账号头像 | 照片或视频类别及服务器保留行为 |
| 购买记录 | 签名交易、永久会员权益 | 购买历史、与账号关联、退款后的保留依据 |
| 阅读文字、提问 | 用户配置的 AI 服务 | 第三方接收范围、明确同意、服务商是否保留数据 |
| 本地书籍、笔记、阅读统计 | 设备存储，可选 iCloud/WebDAV | 区分设备内处理、用户控制的同步、开发者可访问的收集 |
| 网络日志 | 官网与内容服务访问 | 核对真实服务器/CDN日志配置与保留期限，不凭客户端推断“不记录” |

需要一份公开可访问的隐私政策，说明开发者联系方式、具体数据用途、第三方共享、
保留与删除机制。2026-09-12 线上账号安全页已展示 `/privacy` 和 `/privacy-choices` 链接；需核对页面实际内容与 App Store Connect 已填写的 URL，不能再用落后的本地后端源码推断线上页面缺失。
内购授权绑定和退款处理也应与政策、会员文案一致。

Apple 参考：[账号删除](https://developer.apple.com/support/offering-account-deletion-in-your-app/)、
[App Privacy](https://developer.apple.com/app-store/app-privacy-details/)、
[审核指南](https://developer.apple.com/app-store/review/guidelines/)、
[截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)。
