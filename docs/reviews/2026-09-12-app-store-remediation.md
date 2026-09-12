# App Store 审核整改记录 — 2026-09-12

## 审核对象与证据边界

- macOS 2.6.7 (260911002)，提交 ID `a00361ca-b291-4cdb-a16d-b345d29928e8`。
- 2026-09-12 浏览器读取 App Store Connect：版本仍被拒绝、关联旧构建；永久高级版商品 `com.niki.xxread.premium.lifetime` / `6797734053` 仍为“准备提交”；内购审核截图和审核备注均为空。
- 浏览器连接恢复后再次确认以上状态。本次没有向 Apple 发送回复、保存后台元数据或重新提交审核。
- 9 月 8 日的本地后端及 GitHub HEAD `6e31100` 落后于生产。实际 `Azure-hk:/srv/open-reading/current` 当时指向 `code-releases/20260911T110450Z`，已有账号删除、凭证解绑/恢复与相应测试。此前依据本地代码提出的“缺少删除后端”不适用于该生产版本。

## 修复与验收顺序

1. 保留现有 ASWebAuthenticationSession 和 Apple 商店分发限制；只将明确的 CANCELED 认证异常视为取消，其余异常显示错误。
2. 服务端确认注销成功即清除内存账号状态；本地安全存储清理失败不应将成功注销描述为服务端失败。
3. Apple 原生登录附带一次性 authorization_code；后端即时交换并加密保留撤销凭据。删除 Apple 账号前验证用户意图、邮箱验证码与必要的 MFA，再撤销 Apple 授权；依据 Apple TN3194，旧账号缺少或损坏撤销凭据时仍完成本地账号删除，并明确提示用户在 Apple 账户设置中手动移除授权。保留已有 Apple 内购恢复逻辑。
4. 分别运行客户端服务测试、独立 widget 测试和后端真实 PostgreSQL 回归；构建隔离 macOS 商店候选，避免打入共享工作区中其他任务尚未完成的代码。
5. 最终签名候选在真实 Mac 完成登录、删除与购买/恢复验收；录制从登录至删除成功的完整过程。
6. 补内购截图、审核说明与专用审核账号；提交商品时关联新的 app 版本构建，然后更新审核。

## 已获得的验证证据

- 最终隔离客户端：86 项账号/Apple 购买/分发核心测试、10 项注销页面测试、7 项账号页面测试通过；Flutter 3.44.9 / Dart 3.12.2 静态分析无问题。两个有全局状态的 widget 文件分别运行。
- macOS arm64 Release 最终编译成功，Bundle ID `com.niki.xxread`、版本 `2.6.7`、构建 `260912001`，商店分发 define 为 true；编译包含 Apple 授权码上送及注销后可滚动的手动撤销提示。`CODE_SIGNING_ALLOWED=NO`，不是签名归档或上传证据。
- 隔离候选基于客户端 `b2156de`，只包含本次账号相关修改，位于 `/tmp/open-reading-review-20260912/client-candidate`，分支 `codex/app-store-review-20260912`，提交 `62fa45bf4031035a06e5a1afe2e45684290bf405`；隔离工作区干净。共享客户端保留同样的账号修复，其他任务的改动没有纳入此候选。
- 客户端归档和补丁保存在 `build/app-store-review/20260912/`；zip 名称明确标为 `UNSIGNED`。
- 后端集成基线为线上 `20260912-promotion-ui`，保留管理员路由和活动码最新修改。最终全套 **339 项通过**（含真实 PostgreSQL 删除、购买恢复及活动码回归），ruff app/tests/scripts 通过；独立架构复查 APPROVE。
- 网页 typecheck、1506 键三语检查、下载规则检查和 Nuxt build 通过；采用最新活动码页面再次构建通过。
- 使用独立本地 PostgreSQL 16 数据库；没有读取或修改生产用户数据库。

## 已部署的后端

- 当前 release：`/srv/open-reading/code-releases/20260912-apple-account-review`，由 `20260912-promotion-ui` 在服务器复制成新目录，仅覆盖 12 个白名单源码/测试文件及本地构建的前端产物；没有整仓覆盖共享后端。
- 完整备份：`/srv/open-reading/backups/pre-apple-review-20260912T095222Z`，含 PostgreSQL custom dump 和一致性 SQLite 备份，仅保留在服务器私有目录。
- 完整恢复、临时库两次迁移演练通过；生产迁移前后旧表指纹一致。新增 `membership_apple_credentials` 表，不改变已有购买或活动码数据。
- 双服务 active，公开 HTTPS health 正常。管理页匿名访问跳转 `/milo/login`；旧 `/admin` 页面保持 404，管理 API 和注销预览仍要求认证。
- 账号注销与 Apple 凭据写入共用用户行锁，解决并行登录时遗漏撤销的问题。注销路径在 Apple 网络调用期间占用一条数据库连接，每个已保存客户端凭据最多等待 15 秒。
- 没有对真实用户发起删除或购买测试；Apple 实际授权交换/撤销及 StoreKit 仍需专用账号验收。

## 修改文件和简化

- 客户端 15 文件：账号页、注销弹窗、`account_api_client.dart`、`member_account_controller.dart`、四语 ARB/生成代码、3 个测试文件；完整差异见产物中的 `client-review.patch`。
- 后端 12 文件：会员模型/数据库、成员仓储、账号路由、认证服务，3 个测试文件，以及网页注销页/API 类型/注销文案/错误翻译；精确路径与前后 SHA-256 见 `apple-review-manifest.json`。
- 简化注销成功的处理：服务端成功立即清空内存登录状态，本地凭据清理失败不会误报为账号未删；避免通过额外“重新登录”流程阻止旧 Apple 账号注销。未增加依赖。

## 环境和材料缺口

- 当前 Mac 缺少可用 Apple Distribution 签名身份与 macOS 商店 provisioning profile；文档记载的 App Store Connect API env 文件也不存在。需要原有签名环境/证书才能正式归档上传。
- 尚未提供可永久删除的专用测试账号；真实设备录屏未完成。不得使用日常账号或后台所有者账号代替一次性测试账号。
- 无最终候选的内购审核截图；不得将 mock 测试画面或模拟价格冒充实际购买界面。
- 浏览器连接现已恢复；内购审核页已保留用于后续补充，本次尚无后台写入。

## 并行修改事故与恢复

回收生产源码时，共享后端在最初检查后出现了活动码和管理员登录任务的未提交修改。一次未在写入前再次人工检查结果的 rsync 覆盖了部分已跟踪文件。已停止共享后端写入并通知两个任务恢复；新 Apple 撤销实现仅在隔离目录开发。

管理员任务已恢复并部署 `/milo` 页面映射、导航和登录回跳，309 后端测试及 13 浏览器场景通过。活动码任务已完整恢复并部署，328 测试（含真实 PostgreSQL）、静态检查和桌面/移动功能检查通过，迁移前后已有表指纹一致。后续界面微调发布为 `20260912-promotion-ui`。Apple 补丁必须以最新 current 为基线最小覆盖，不得用旧快照整仓部署。
