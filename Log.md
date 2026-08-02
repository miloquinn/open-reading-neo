# Open Reading 关键开发日志

> 本文件是精简流水账，只记录后续开发需要记住的关键变化、决策、验证和风险。
> 小型样式调整、普通重命名和无长期影响的修复不记录。
## 2026-08-02

### 阅读书源原生执行引擎

- 修复导入大量书源后发现页卡死：注册表小数据直接解析、大数据后台 isolate 解析；能力来源建立一次性索引，删除页面重建期的 O(n²) 扫描；标准布局来源条改为惰性构建，大型库默认限定单一来源；列表布局只在用户展开某个来源时加载其频道；跨来源发现请求使用最多 8 个 worker，不再通过无界 `Future.wait` 同时启动数千任务。新增 80 来源惰性构建、按需频道加载和 20 来源最大并发回归。
- 将阅读书源实现统一迁移到中性 `book_sources/source_engine/` 模块，稳定协议标识为 `readingSource`，新 ID 使用 `source.` 前缀；读取时保留旧持久化值兼容，避免用户现有书架和注册表断链。
- 导入改为后台 isolate 本地解析和单次批量保存，不逐源联网、不因脚本/WebView/XPath 等高级规则丢弃配置。用户两份真实文件共得到 4,561 个唯一配置，约 1 秒完成解析；静态核心规则判断中 4,027 条可尝试执行，该数字不作为在线率或全链通过率。
- 新增 QuickJS 脚本与同步网络重放、常用加密/摘要/DOM 辅助方法、RFC JSONPath、常用 XPath、状态规则、分页表达式、动态发现、独立 Cookie 会话、GBK、浏览器语义重定向及 Android 后台网页 DOM/Cookie 桥。
- 真实分层抽测定位并修复虚拟 DNS 环境下自定义连接通道把有效 200 响应变成 400、请求级裸 User-Agent 被误拒绝，以及旧式多类名选择器带空格时报非法 CSS 三个兼容缺口。普通公网仍固定已校验地址；仅虚拟 DNS 保留地址在完成相同检查后使用系统通道，WebView 起始与最终地址也经过网络策略校验。
- 简介清洗覆盖 HTML、字面换行/制表、Unicode 转义、二次实体和不可见控制字符；发现页保留标准/列表双布局，书源管理页支持搜索、筛选和大型惰性列表。
- 验证：核心脚本、运行时、导入、兼容扫描与简介清洗 61 项通过；新增网络/多类名规则后运行时 33 项通过；Android 关闭 Kotlin 增量缓存后 `:app:compileDebugKotlin` 成功。真实样本有完整搜索→详情→目录→正文通过项，其余失败已按站点状态、过期规则或来源脚本异常分阶段记录，不再用于导入过滤。

### 阅读正文五档字重与自定义变量字体识别

- 本地文件与在线书源阅读器新增共享正文字重设置，使用 300/400/500/600/700 五个长文常用档位，默认 400；设置存入 `native_reader_font_weight`，正文 `TextStyle`、strut、纵向列表 key 与分页指纹全部使用同一字重，调整后按既有 canonical 文本锚点恢复位置。
- “阅读设置 > 文字”在字号之后加入实时字样预览、语义名称与离散滑杆。变量字体显示完整真实 `wght` 范围；HarmonyOS Sans、JetBrains Mono、系统字体及静态自定义字体仍可调整，但明确提示为系统近似合成、效果可能因平台而异。
- 用户导入 TTF/OTF 时只读解析 SFNT `fvar` 表：存在 `wght` 轴就把最小/最大范围写入字体清单并合并到 `FontOption`；旧清单在启动时对本地文件回扫一次，静态字体也记录为已检查，后续不重复解析。字体字节不修改、不上传，MiSans 的在线再分发限制仍保持不变。
- `frontend-design` 方案采用五档滑杆而非九档技术参数：固定换字体后的数值语义，避免 100/200/800/900 极端档破坏长文可读性；唯一强调元素是使用当前阅读字体和当前字重绘制的实时字样卡片，其余控件沿用现有阅读设置视觉体系。
- 验证：46 个阅读器/字体测试文件共 266 项通过，另跑两套纯文本分页器相关用例均通过；覆盖五档控件与实时预览、设置持久化、分页指纹、本地/书源正文最终 `TextStyle`、自定义变量轴导入与旧清单回扫。全仓静态分析无 error/warning，保留 55 条既有 info。

### HarmonyOS Sans 官方按需字体与字重能力标识

- App 与阅读字体目录新增 HarmonyOS Sans SC Regular；不使用第三方镜像，而是通过 HTTP Range 从华为官方 `HarmonyOS-Sans.zip` 只读取目标 Deflate 条目。解压后的 8,483,132 字节原文件必须同时匹配 TTF 签名与固定 SHA-256，官方端不返回 `206`、条目大小变化或哈希不符时均拒绝注册。
- 应用内字体许可页新增完整 HarmonyOS Sans Fonts License Agreement，并明确该字体为固定 Regular；字体目录同时记录真实变量 `wght` 范围，列表可区分思源宋体 200–900、思源黑体 100–900、Instrument Sans 400–700、Newsreader 200–800 与固定字重字体。
- MiSans 虽允许商业作品使用，但官方协议同时规定许可不可转让、字体文件不得进一步分发；为规避授权风险，本轮不把第三方 MiSans 镜像接入一键下载目录，用户仍可自行从小米官方取得字体后使用现有本地字体导入。
- 验证：官方 ZIP 目标范围实际返回 `206`，解压后字体大小与 SHA-256 均匹配；在线字体解压/注册、固定哈希拒绝、字体目录和许可页定向 17 项通过。触达文件静态分析无问题；全仓分析无 error/warning，保留 55 条既有 info。全量测试分别以单并发运行 10 分钟、默认并发运行 6 分钟，均未输出失败但在工具时限内没有结束，残留的本轮测试子进程已精确清理，因此不宣称全量通过。

### 在线书籍手动整书换源

- 对照成熟阅读器的换源搜索、目录预检和书籍迁移逻辑，新增手动整书换源；并发搜索当前来源之外的已启用来源，书名规范化精确匹配，作者校验默认开启且可关闭，结果按来源完成顺序渐进展示。
- 候选不能仅凭搜索命中直接切换：用户选中后必须实际获取详情、完整目录和映射后的当前章节正文。章节定位优先完整标题和章节号，再按新旧目录比例回退；章内阅读百分比保留。
- 已入书架的在线书原位更新同一条 `Book`，保留书籍 ID、用户书名、封面、书签、笔记与书架顺序，只替换 `sourceId/sourceBookId` 和来源快照；新来源进度先写入，数据库更新失败时回滚新进度。目标来源版本已在书架中时拒绝隐式合并，避免丢失两边关联数据。
- 换源任务页使用“当前来源 -> 目标来源”迁移轨道区分搜索命中与正文已验证状态；书架在线书长按菜单和在线阅读器顶栏提供入口。本轮只支持手动整书换源，不做静默自动换源或单章混源。
- 性能复核确认掉帧来自无界请求风暴和每个来源完成时的同步整页重建：搜索现固定最多 6 路 worker，取消/重新搜索后停止调度剩余来源；页面以 120ms 窗口合并进度与候选，使用原位惰性列表和稳定键去重，不再每次复制全部结果。大型书源注册表的 JSON 解码、阅读书源兼容扫描与运行门禁过滤改到后台 isolate，换源页先显示任务框架再等待来源集合。
- 验证：换源、注册表、书架、进度、聚合搜索、阅读控制栏和在线阅读器合计 59 项相关回归通过；触达文件静态分析无问题。全仓静态分析无 error/warning，保留 56 条既有 info 级提示。

### 数千条阅读书源快速导入与可管理列表

- 对照成熟阅读器的导入与批量入库流程，确认联网校验应是独立管理操作；Open Reading 原先把最多 120 个候选逐个执行“搜索 -> 详情 -> 目录 -> 首章正文”，最多保存 30 个，临时网络失败也会直接丢弃，这是大型聚合文件导入慢且只剩少数来源的根因。
- 阅读书源 JSON 导入改为本地解析、按 `bookSourceUrl` 去重、兼容能力标记和单次批量保存；不再调用在线阅读链验证，也不再隐藏未验证记录。可运行来源按导入配置启用，高级能力按实际调用解析，后续补齐能力无需重新导入。解析移到后台 isolate，URL 聚合文件修正为只下载和解码一次；批量保存直接返回内存结果，不再保存后立刻重新解析整份注册表。
- 兼容扫描不再因为 `enabledCookieJar=true` 或存在可选登录配置就判定整源不可运行；只有显式 Cookie 请求头和核心阅读规则真实使用受限能力时才阻止执行。图片、文件、音频、视频源继续只保存配置、不进入文字阅读运行时。
- 书源管理页改为 Sliver 惰性列表，支持名称/网址/备注/分组搜索，“全部 / 已启用 / 已停用 / 可直接使用 / 待兼容”筛选、可搜索分组选择，以及仅对当前筛选结果全选和批量启停/删除；600 条组件夹具确认末尾项目不会提前构建，搜索后可直接定位。
- 使用用户提供的真实文件只读回归：`shuyuan.json` 6,008,449 字节解析出 1,048 条、跳过 13 条无效配置，其中 368 条可直接运行；`shareBookSource.json` 22,049,828 字节解析出 3,880 条、跳过 69 条无效配置，其中 1,259 条可直接运行。Windows 测试环境后台解析分别约 0.27 秒和 0.60 秒；第二份文件转换/序列化约 0.62 秒、单次保存约 0.28 秒，过程零书源联网请求。

### 书库打开动画类型、节奏与深色首帧修复

- 书库打开动画继续保留“经典封面展开、极简淡入、纸面浮现、侧页推入”四种类型，只移除体验不稳定的“双页展开”；选中任一类型后在其下方展开“动画节奏”二级选项，支持“快速 / 优雅”，默认优雅并独立持久化。
- 开场时间轴收敛为两段：路由只负责把当前页面平滑交接到阅读主题底色，正文控制器等待本地/在线阅读器完成首帧绘制后再从 0 单向渐现到 1（快速 300ms、优雅 720ms）。删除两个阅读器内部重复的 360ms `AnimatedSwitcher`、正文就绪前的 360ms 延迟，以及加载态先显示正文容器再重置透明度的反向分支，修复“文字闪出、闪没、再次渐现”。经典封面在内容迟到时保持封面，不提前暴露加载页；正文就绪后才执行唯一一次交接。
- 首页“继续阅读”与本地阅读服务在创建路由前预读已保存阅读主题，并把同一主题同时种入阅读器和转场底色；纯黑/黑夜主题不再插入白色中间帧。路由、两套文字阅读器、动画设置和首页主题传递共 67 项定向测试通过。全仓静态分析当前被并行书源列表/文本规范化改动的 1 个 error 与 2 个 warning 阻断，本次触达文件没有新增 error/warning。

### Android 构建工具链兼容性升级

- Gradle Wrapper 从 `8.11.1` 升级到官方 `8.14` 系列最新补丁版 `8.14.5`，Android Gradle Plugin 从 `8.9.1` 升级到 `8.11.1`，Kotlin Gradle Plugin 从 `2.2.0` 升级到 `2.2.20`；继续保留 `android.builtInKotlin=false` 与 `android.newDsl=false`，本轮不迁移 AGP 9/Built-in Kotlin。
- `flutter analyze --suggestions` 确认 Java 17、Gradle、AGP、KGP 组合兼容，`:app:compileDebugKotlin` 成功；原有三条 Gradle/AGP/Kotlin 即将停止支持警告已消失。SDK XML 版本提示和应用/第三方插件 KGP 迁移提示继续作为后续风险保留。
- 完整 `flutter analyze --no-pub` 与 debug APK 构建被当前工作树中尚未完成的书源筛选/本地化生成改动阻断；Android 构建已越过原生 Kotlin 编译，最终失败点为缺失的 Dart 本地化 getter，与本次工具链版本变更无关。Windows 跨盘 Pub 缓存仍会让 Kotlin 增量缓存失败并自动回退到非增量编译。

## 2026-08-01

### 阅读书源声明式发现与统一发现页

- 参考成熟阅读器的“书源 -> 发现频道 -> 分页书单”实现，新增安全声明式发现适配：支持旧式 `标题::URL`、JSON `type=url`、`{{page}}`、`ruleExplore`，缺失独立书单规则时回退 `ruleSearch`。
- 核心阅读兼容扫描与可选发现扫描解耦；脚本发现或高级控件不再让已经验证的搜索/详情/目录/正文整体失效。历史存储的已验证书源会在读取时自动补回可安全运行的分类/浏览能力。
- 发现页采用单一操作逻辑：书源 Chip 位于栏目之前，所选书源只展示实际支持的栏目；阅读书源入口映射为横向频道 Chip，完整频道集合继续使用按书源分组、可搜索的惰性选择面板。
- 分类/频道书单新增分页、失败重试和 `sourceId + bookId` 去重；空页或整页重复时停止继续加载，避免第三方站点忽略页码造成无限请求。ORSP 推荐与最新聚合逻辑保持不变，阅读书源不会被误放进“最新”。
- `@js:` / `<js>`、`text/button/toggle/select`、`infoMap`、登录/Cookie/WebView 仍不执行，等待独立安全运行时评审。
- 验证：阅读书源解析/运行时/安全边界 33 项、发现页 14 项、统一搜索/发现流程 7 项、导入分析 3 项通过；新增未声明频道 URL 请求前拒绝测试。触达文件静态分析无问题；全仓静态分析无 error/warning，保留 60 条既有 info 级提示。

### 替换净化规则

- 新增独立的全局替换规则库和管理页：用户可新建/编辑普通文本或正则规则，启停、删除、搜索、按书名/书源设置作用范围，并导入/导出 JSON；导入兼容阅读书源常用替换规则字段。
- 入口采用“设置 > 数据与服务 > 替换净化”作为稳定管理入口，本地文字阅读器与在线书源阅读器底部控制栏增加 `find_replace` 快速入口。未把规则塞进阅读排版四个页签，因为它是跨书、可导入的数据资产，而不是单本书的字号/边距偏好。
- 在线书源正文在 HTML/纯文本规范化后、分页前应用规则；本地 TXT（含大文件惰性章节）在章节文字物化后、分页前应用规则。章节标题使用独立的标题规则；EPUB/Kindle 富文本按文本块净化并重算样式/图片偏移，不再出现“纯文本已净化但实际富文本仍显示广告”的分叉。规则变更返回阅读器时失效对应文字/分页缓存，并按章节内进度比例恢复位置。
- 规则导入同时兼容新版阅读书源的 `isEnabled`、`sortOrder` 和旧版 `enable`、`serialNumber` 等字段，接受布尔/0-1/字符串表示；导入文件限制 8 MiB、规则上限 5000 条，重复项按 ID 或“名称 + 表达式”覆盖，超量不再静默截断。管理页支持拖拽排序、删除确认、空搜索结果区分，并完成简中、繁中、英文、日文四语言接线。
- 验证：规则服务 8 项、阅读器控制栏与在线书源阅读器合计 27 项、本地阅读器 20 项定向测试通过；Web debug 构建成功。触达文件静态分析无 error/warning，仅保留阅读器既有 info；Web 的 Wasm dry-run 仍提示 `pdfx`/`flutter_tts` 既有第三方兼容性告警。

## 2026-07-29

### iOS 系统阅读字体与仿真翻页手势修复

- 本地文字阅读器与在线书源阅读器在 iOS 中文环境选用“系统默认”字体时，仍保持 `fontFamily: null`，但通过共享 `readerFontFamilyFallbacks` 显式固定系统自带苹方回退顺序（简体优先 `PingFang SC`、繁体优先 `PingFang TC`）。这规避 Impeller 对隐式 CJK fallback 字形运行解析不稳定而造成的相邻汉字粗细/视觉尺寸不一致；不新增字体资源，不影响非 iOS 平台和用户选择的自定义/在线字体。
- 手机单页仿真翻页不再按触点所在左右边缘预锁方向，而是以达到水平阈值后的真实位移决定前后页；因此从屏幕左侧向左滑也能翻到下一页。匹配自由外缘的起手仍使用较宽松的方向阈值并保持即时跟手；平板双页的 `edgeDragOnly` 书脊保护不变。
- 验证：新增 iOS 简/繁中文系统 fallback、非 iOS/显式 fallback 保持不变，以及左侧 15% 起手向左翻到下一页的回归测试；阅读排版、两套阅读器和 page-curl 定向 73 项通过；全量 `flutter test --no-pub --concurrency=1` 626 项通过。触达文件定向静态分析无 error/warning，仅保留既有 info；全仓分析仍被旧 `native_reader_page.sync-conflict-20260723-185753-XNTYOKG.dart` 的过期构造参数阻断。尚未完成 iOS 真机视觉复核。

### v2.4.3 正式发布

- `v2.4.3` 从提交 `3b826fd` 发布，基础构建号 `260729001`；PR checks Run `30438625424`、跨平台 smoke Run `30438625399` 和正式 Release Run `30439432924` 全部成功。
- GitHub Latest Release 为非 Draft/非 Prerelease，包含 Android 三 ABI、Windows、Linux、iOS unsigned、macOS universal 七个安装包及 `SHA256SUMS.txt`；全部重新下载后 SHA-256 复算 7/7 通过。
- Android 实际 versionCode 为 armeabi-v7a `260730001`、arm64-v8a `260731001`、x86_64 `260733001`，包名、版本名、完整签名与 Origo 身份一致。macOS 包确认 arm64/x86_64 universal、Developer ID、Hardened Runtime、Apple 公证 staple 与 Gatekeeper 通过；iOS IPA 确认为未签名且元数据为 `2.4.3+260729001`。
- 官网七个平台/架构槽位的版本、构建号、大小和 SHA-256 均与 GitHub 资产一致，Range 下载全部返回 206；Web `version.json` 为 `2.4.3+260729001`，首页和下载页为 200。
- 未做 iOS/Android 真机安装与视觉复核；用户现有未提交 iOS 工程配置改动未纳入本次 Tag 或发布台账提交。

## 2026-07-27

### 漫画/PDF 阅读器完整控制层

- `pages/reader/paged_image_reader.dart` 控制层升级：底栏新增上/下一页按钮、进度滑条、跳页输入（`_JumpPageDialog` 自持 TextEditingController，随路由销毁释放，避免退出动画期 dispose 断言）与设置入口；顶栏页码可点击直达。接入共享 `reader_tap_zones`（轻点走 `onTapUp` 坐标查表；控制栏可见时任意轻点先收起；章节动作在无章节结构的图片书中忽略）、`ReaderVolumeKeyController`（Android 音量键翻页）与 `ReaderKeepScreenOnController`（屏幕常亮），漫画与 PDF 两个宿主传入 `bookId`。
- 新增 `core/reader/paged_image_reader_settings.dart`：阅读方向（`ltr`/`rtl`）按书持久化（JSON 覆盖表，默认 LTR 不占存储），页面背景（黑/灰/白）全局持久化。RTL 模式下 `PageView.reverse`、滑条 `Directionality` 与翻页按钮同步镜像，点击区域按列镜像使默认布局在日漫方向下符合「点左边翻下一页」的习惯。设置面板（底部弹层）提供方向、背景色，以及与文字阅读器共用偏好键的「保持屏幕常亮」「音量键翻页」开关。
- 四语言 arb 新增 `imageReaderSettings`、`imageReaderDirection*`、`imageReaderJumpToPage`、`imageReaderBackground*` 共 9 键；`flutter gen-l10n` 再生成。
- 测试陷阱记录：`ReaderKeepScreenOnController.resetForTesting()` 不能放进 `testWidgets` 的 `setUp` await——其内部 await 的静态 `_pendingSync` 链跨 fake-async 区域后可能永不完成，会把后续所有测试的 setUp 卡死（现象为真实时间无限挂起、单测超时也不触发）。组件测试改为：mock 两个桥接通道 + 每个测试末尾在测试 zone 内主动卸载阅读器，控制器语义由既有单测覆盖。
- 验证：`paged_image_reader_test.dart` 重写为 6 项（越界收敛、fling 翻页、默认点击区域、RTL 反向与镜像、方向持久化+跳页、设置面板背景/常亮持久化）全部通过；`flutter analyze` 无 error/warning（70 条 info 均为存量）；触达源码已 `dart format`。全量 `flutter test` 606 项通过、3 项失败，失败均位于 `book_source_page_modes_test.dart` 的阅读设置面板断言——对应 `reader_settings_controls.dart`/`book_source_reader_page.dart` 在本次全量前被并行工作流（启动阅读恢复/AI 页）修改，不属于本次改动面；本次触达的全部目标测试文件均绿。

## 2026-07-27

### v2.4.2 正式发布

- `v2.4.2` 从提交 `fde8402` 发布，基础构建号 `260727001`；正式 Run `30212708703` 的 10 个 job 全部成功。发布主打 AI 阅读助手全链路，另含覆盖翻页、点击区域、启动恢复、阅读设置页签化与漫画容器嗅探（与另一台机器的并行工作合流）。
- 门禁：PR checks 成功；smoke 首跑 Windows job 因 pdfx 拉取 pdfium 网络抖动失败，重跑成功——该失败模式与代码无关，重跑即可。
- GitHub Latest Release 七个安装包 + `SHA256SUMS.txt`，本地复算 7/7 通过；官网七个平台/架构槽位版本、构建号（ABI 偏移）、大小一致，Range 全部 206；`version.json` 为 `2.4.2+260727001`。
- 已知问题（发布后立即修复，进 2.4.3）：`ReaderHttpAIService` 实例级 `_cachedActive` 使设置页切换模型对已打开的对话界面不生效（提交 `37e03e7` 移除缓存，每次请求重读配置）。

## 2026-07-26

### AI 页、对话历史、知识库与预处理

- 导航体系新增 `ai` 目的地（`HomeNavigationDestination.ai`，默认排在设置前）；`AppSettingsNotifier` 新增 `home_navigation_hidden_v1` 隐藏集合与 `visibleHomeNavigationOrder`，悬浮导航设置页每项加显示开关（设置页锁定不可隐藏，恢复默认同时清空隐藏），壳层按可见列表装配，用户可隐藏首页等页面。
- 新增 `services/ai/ai_chat_history_store.dart`：问AI/AI 页对话统一落盘（prefs JSON、上限 100 会话、ChangeNotifier 单例）；`reader_ai_panel` 每轮完整问答后带书名保存。
- `pages/ai/ai_page.dart`：AI 导航页进入即为对话界面（悬浮输入条），支持关联任意书籍；上下文注入 = 该书预处理摘要（≤1800 字符）+ 用户笔记/高亮（≤900 字符），经 `chat(pageText:)` 通道随系统提示词下发。左上角历史按钮进入 `ai_history_page.dart`（滑动删除、清空全部、Markdown 转写详情）。
- AI 预处理链路：`services/books/book_text_extraction_service.dart` 无头抽取 TXT/EPUB/Kindle 章节文本；`services/ai/book_preprocess_service.dart` 分块（6000 字符/块，超 24 块均匀抽样）逐块总结再合并成 Markdown，写入 `GlobalAIReadingService` 的 `memory.json.summary`（新增 saveBookSummary/loadBookSummary）。任务经 `ai_preprocess_task_controller.dart` 全局 FIFO 队列后台串行执行，"下载任务"页新增"AI 预处理"Tab 展示进度、取消与清理。设置页 AI 区块新增"AI 预处理书籍"开关（默认关，开启前校验模型可用并提示 token 消耗）；`scheduleImportedBookAnalysis` 死桩复活为导入后自动入队；书架长按菜单新增手动"AI 预处理"入队。
- 书架长按菜单由大卡片重排为紧凑行（小图标+标题+右侧摘要），删除项红色标示，容纳新增的 AI 入口。
- AI 页风格与其他页对齐：手机端标题走壳层共享顶栏、历史与新对话工具挂顶栏右侧（`AiPageController` 桥接，参照书库控制器做法），宽屏保留页内大标题行；书籍关联收进输入条左侧加号菜单，已关联时输入条上方显示可移除胶囊。会话存储新增 `bookId` 字段，历史页点选会话即返回 AI 页载入继续对话（沿用会话 ID，书籍上下文按 ID/书名恢复），只读详情页随之移除。键盘弹出时悬浮导航栏并入既有滑出隐藏机制，不再被键盘顶起。
- 验证：新增/更新 `ai_chat_history_store_test.dart`（持久化/去重/上限/损坏降级）、导航可见性与顺序测试；`flutter analyze` 无 error/warning。已知债：预处理与上下文注入的提示词沿用服务层中文硬编码约定。

### 漫画格式扩展：CBT 可读、CBR/CB7 按文件头嗅探

- `comic_book_parser.dart` 重构为容器嗅探入口：按文件头识别 ZIP（PK 前缀）/ RAR（`Rar!`）/ 7z 魔数 / TAR（offset 257 `ustar`），扩展名只作无魔数容器（旧式 V7 TAR、损坏 CBZ）兜底。ZIP/TAR 分别走 `ZipDecoder`/`TarDecoder`（IO 端保持 `InputFileStream` 流式读盘），真 RAR/7z 抛可跨 compute isolate 的 `ComicArchiveUnsupportedException(container)`。市面上大量 CBR/CB7 实为 ZIP 改名，识别后直接复用 CBZ 管线。
- `NativeReaderService` 漫画路由从 `cbz` 扩为 `{cbz, cbt, cbr, cb7}` 统一进 `ComicReaderPage`，移除 CBR 打开即 toast 的分支；阅读页把类型化异常映射为本地化提示（真 RAR→`readerComicCbrUnsupported` 更新措辞，7z/未知→新增 `readerComicArchiveUnsupported`，四语言）。页索引与单页解压 compute 参数新增 `ext` 声明扩展名。
- `BookFormatRegistry` 新增 `cbt`（fullReader）与 `cb7`（metadataImport，嗅探后可能可读）并更新 `cbr` notes；导入侧 `_extractComicMetadata` 对全部漫画格式尝试真实页数与首页封面（失败回退估算值），漫画扩展名全部进入完整读取白名单；导入 MIME 映射与导出 MIME 增补 `application/x-cbt`/`application/x-cb7`。
- `docs/book-format-support.md` 能力矩阵与 §3.7、`structure.md` 本地书籍格式、`CHANGELOG.md`/`assets/changelog/changelog.json`/`.github/release-notes/v2.4.2.md` 的 2.4.2 条目已同步（四语言）。真 RAR 解压依赖评估仍保留为 P2 待办。
- 验证：`comic_book_parser_test.dart` 新增 5 项（TAR 索引/解页、改名 ZIP 嗅探、真 RAR/7z 类型化异常、文件头识别、损坏 CBZ 报原始错误），`book_format_support_test.dart` 新增漫画容器能力断言；全量 `flutter test` 600 项通过（默认并发首跑出现 8 个文件 loading 抖动，属已知 Windows 环境问题，`--concurrency=4` 两次全量均通过）；`flutter analyze` 无 error/warning，info 均为存量；触达源码已 `dart format`，l10n 经 `flutter gen-l10n` 再生成。

### 阅读页 3×3 点击区域自定义

- 新增 `core/reader/reader_tap_zones.dart`：九宫格点击区域模型，每格可设为上一页/下一页/上一章/下一章/菜单/无操作；规范化保证至少一个菜单区域，缺失时中间格自动恢复为菜单。`ReaderSettingsStore` 以 `reader_tap_zones_v1` 单键（逗号连接的枚举名）在本地与在线阅读器之间共享，解码失败整体回退默认。默认布局与旧三分区语义一致（左列上一页、中列菜单、右列下一页），但边界从 0.28/0.72 移到 1/3；`book_source_page_modes_test` 的右缘轻点断言在新边界下不受影响。
- 两个阅读器的轻点分发改为查表：native `_handleTap` 与书源 `_handleTapZoneAction` 消费 `ReaderTapZones.actionAt(localPosition, viewport)`。上下翻页模式下点击翻页动作保持关闭（沿用旧行为），菜单照常；章节动作 native 走 `_setChapter(..., recenterContinuousScroll: true)`，书源在整书滚动下走 `_jumpToVerticalChapter`、其余走 `_loadChapter`，两侧均先做边界判断避免首末章误触发目录重定位。
- 新增 `widgets/reader_tap_zone_editor.dart` 全屏编辑层：入口在阅读设置面板（`tapZoneSettings` 复用既有预留文案键），点击后关闭设置弹窗、收起控制栏，直接在真实阅读页上盖九宫格预览；点格弹出主题化"选择操作"面板即时持久化，另有恢复默认按钮。编辑层在 native 放在最外层 Stack（`ReaderPullBookmark` 之外），书源放在章节 Stack 顶部并同时禁用下拉书签——`ReaderPullBookmark` 的 raw `Listener` 是祖先节点，命中路径会穿透覆盖层，仅靠遮挡挡不住。两个阅读器的 `PopScope` 在编辑层可见时 `canPop=false`，返回键先关编辑层再退出阅读器。
- 四语言 arb 新增 `tapZoneNextChapter`、`tapZonePreviousChapter`、`tapZoneNone`、`tapZoneSettingsHint`、`tapZoneChooseAction`、`tapZoneMenuRequiredHint`、`tapZoneReset`，并把 zh/zh_TW 的 `tapZoneSettings` 更名为「点击区域设置／點擊區域設定」；`tapZoneLegend`、`tapZoneLeftRight` 等历史预留键仍未使用。
- 验证：新增 `reader_tap_zones_test.dart` 7 项（默认布局、坐标映射、菜单兜底、编码回退、编辑层选择/关闭/重置）；全量 `flutter test` 586 项通过；`flutter analyze` 无 error/warning，info 均为存量；触达源码已 `dart format`。

### 阅读器"问AI"入口与对话面板

- 新增 `widgets/reader_ai_panel.dart`：本地与在线书源阅读器共用的"问AI"底部对话面板（72% 屏高、随键盘上移），面板内维护多轮对话历史并调用既有 `ReaderHttpAIService.chat`；打开时先 `loadSettings` 检查 `isConfigured`，未配置 API Key 时禁用输入并提示前往"设置 → AI 阅读助手"。回答经 `translateMockAiResponse` 渲染、错误经 `translateAIServiceException` 翻译，服务层错误码不直接暴露。
- `ReaderChromeOverlay` 底部控制栏新增可选 `onAskAi` 按钮（`auto_awesome_outlined`，位于朗读与设置之间）；`ReaderSelectionToolbar` 新增可选"问AI"动作，经 `ReaderAnnotatedTextPage.onAskAiSelection` 把 `ReaderSelectionSnapshot` 交给宿主阅读器。选中入口不要求 `bookId`（未入书架的在线书也可用），并复用 `onInteractionChanged` 抑制面板期间的翻页轻点。
- 上下文策略：控制栏入口传当前页文本（本地用 `bookmarkPage.text`，书源用 `_paginatedPages` 当前页，空时回退整章可读文本）；选中入口传选区前后各 1400 字符窗口，避免服务层 2800 字符截断只保留章节开头。选中提问的提示词经四语言 `readerAiSelectionPrompt` 本地化生成，在面板侧组装为首条 user 消息，后续追问共用同一 `chat` 通道。
- 四语言 arb 新增 `readerAskAi`、`readerAiInputHint`、`readerAiSendButton`、`readerAiThinking`、`readerAiNotConfiguredHint`、`readerAiEmptyHint`、`readerAiSelectionQuestionLabel`、`readerAiSelectionPrompt`；服务层 `ai_service.dart` 内置中文 system prompt 仍是遗留债（`lib/l10n/README.md` 已登记待迁移）。
- 验证：新增 `reader_ai_panel_test.dart` 3 项（发送/未配置禁用/选区自动提问）与选中工具栏"问AI"回传 1 项；全量 `flutter test` 579 项通过；`flutter analyze` 无 error/warning，info 均为存量。

### 新增覆盖翻页模式

- `ReaderPageMode` 新增 `coverSlide`，本地 TXT/EPUB 与在线书源阅读器共用新组件 `widgets/reader_cover_page_turn.dart`：阅读顺序靠前的纸页始终在上层，向前翻当前页左滑划出露出下一页，向后翻上一页从左缘滑入盖回，上层页右缘带渐变阴影、下层页按未揭开比例变暗。
- 纸页为实时 widget 而非 GPU 快照，相邻页离屏预挂载把排版成本移出手势首帧；拖动经原始指针流识别（`kTouchSlop` + 水平占优才启动，竖直意图与长按选区放行），松手速度交给与仿真翻页同参数的弹簧收尾，动画完成后才回调宿主提交页码，落指可接管收尾动画，无相邻页时橡皮筋回弹。
- 本地阅读器复用横滑/仿真的跨章 bookPages 窗口；`_commitHorizontalBackwardExpansion` 现在只在 `horizontalSlide` 下重建补偿索引的 `PageController`，覆盖与后续非滑动模式改为直接扩窗（覆盖模式在翻页提交回调里触发，补上了仿真模式向后跨章不扩窗的同类缺口）。平板双页整张 spread 作为整体滑动；书源阅读器与无动画/横滑一致仅单页，章节边界快照通过抽出的 `_singlePageTurnSnapshots` 与仿真翻页共用。
- 翻页模式弹窗按枚举顺序自动列出新模式，四个语言 arb 补充 `readerModeCoverSlide(Hint)` 文案；持久化按枚举名存取，旧版本读到未知名称回退默认模式。
- `CHANGELOG.md` 与应用内 `assets/changelog/changelog.json` 已预填 2.4.2 覆盖翻页条目（四语言），构建号与发布日期待发布时补齐；未创建 `.github/release-notes/v2.4.2.md`（该文件属发布流程产物，v2.4.1 亦未单独创建）。
- 验证：新增 11 项 `reader_cover_page_turn_test.dart` 覆盖程序化翻页、队列、拖动提交/回弹、快速甩动、回翻、橡皮筋与竖直手势放行；全量 `flutter test` 575 项通过；全项目 `flutter analyze` 无 error/warning，67 条 info 全部为存量（触达文件与 HEAD 逐条一致）；触达的 Dart 源已 `dart format`。

### v2.4.0 正式发布

- `v2.4.0` 已从提交 `c93dd21` 发布，基础构建号为 `260726005`；正式 GitHub Actions Run `30195026221` 的 10 个 job 全部成功。
- GitHub Latest Release 包含 Android 三 ABI、Windows、Linux、未签名 iOS、已签名并公证的 macOS universal 七个安装包及 `SHA256SUMS.txt`；全部安装包本地复算 SHA-256 通过。
- 官网 Android 三 ABI、Windows、Linux、macOS、iOS 七个平台/架构槽位均返回 2.4.0，Range 下载全部为 206；Web 首页和下载页为 200，`read.xxread.top/version.json` 为 `2.4.0+260726005`。
- 新增 `audioplayers_linux` 后，预发布 smoke 首次因 Runner 缺少 GStreamer 开发包失败；`.github/workflows/platform-smoke.yml` 与 `release.yml` 已同步安装 `libgstreamer1.0-dev`、`libgstreamer-plugins-base1.0-dev`，修复后跨平台 smoke Run `30194679486` 全部成功。

### 连续听书与 Android Live Update 通知

- 本地文件和在线书源阅读器接入统一 `ReaderAloudController`：从当前 UTF-16 文本位置开始分段朗读，支持暂停恢复、上下句、自动跨章、页面跟随、精确进度保存和睡眠定时；系统音色、语速、音量与音调继续复用既有 `TtsService`，OpenHarmony 暂不接入。
- 朗读分段改为真实句界，当前正在朗读的句子通过共享富文本层临时高亮；暂停保留、停止清除，不创建数据库高亮记录，并可与已有文字批注的下划线样式叠加。
- 新增 OpenAI-compatible 云端 TTS：可配置 Base URL、模型、音色、音频格式和失败回退；API Key 使用安全存储，普通配置使用 SharedPreferences。请求仅允许 HTTPS（localhost 调试例外）、禁止重定向、流式限制 12 MB，并使用有界会话内音频缓存；跨平台音频播放采用 `audioplayers 6.8.1`，系统 TTS 保持默认和兜底。
- 阅读控制栏新增听书入口和共享控制面板。系统 TTS 启用 Android 音频焦点，设置变化后的内部重启保持原 utterance 位置，避免暂停或调速后进度倒退。
- 听书面板改为最高占屏幕 72%，移除不可拖动的自绘横条并启用系统拖拽条；横条可直接下拉关闭，长内容留在面板内部滚动。定时关闭移除固定 15/30/60 分钟选项，改为任意小时/分钟滚轮、剩余时间、进度条和一键取消。
- 播放中调整语速、系统音量、音调、系统音色或云端 TTS 配置会立即从当前句的实时 UTF-16 位置重启剩余文本；云端音量直接作用于当前播放器，不重新合成。滑杆拖动期间只更新预览值，松手后提交一次最终参数，避免连续重启和设置写入乱序。
- Android 新增 `mediaPlayback` 前台服务与 framework `MediaSession`，通知和外设媒体键统一回传 Dart 会话。Android 16 使用 `Notification.ProgressStyle`，系统允许时请求 promoted ongoing；官方不保证普通媒体播放一定获得 Live Update 提升，因此始终保留普通持续通知与 MediaSession 回退。
- 验证：朗读分段/偏移、暂停恢复、跨章、引擎错误和通知控制 7 项单测通过；阅读器相关定向测试及最终全量 `flutter test --no-pub` 543 项通过；全项目 `flutter analyze --no-pub` 无 error/warning，保留 64 条既有 info；`./gradlew :app:compileDebugKotlin` 成功。尚未在 Android 16/16.1 真机验证 promoted 展示资格、锁屏媒体键和厂商后台策略。
- 当前句高亮、云端设置安全存储、HTTPS/重定向边界、流式响应上限、缓存复用、系统回退、播放中即时调参、可拖拽限高面板与任意时长定时器新增回归测试并通过；最新全量 `flutter test --no-pub --concurrency=1` 共 545 项通过，全项目静态分析无 error/warning、保留 64 条既有 info，Android debug APK 构建成功。尚未使用真实第三方 TTS 账号及 Android 真机验证云端音频焦点、熄屏连续播放和厂商后台策略。

### 阅读标注：高亮与可点击文字批注

- 本地文件与在线书源阅读器接入统一 `ReaderAnnotatedTextPage`：四种翻页模式都可选中文字，选区工具栏按当前阅读主题展示“高亮、笔记、复制”；高亮支持多色与下划线，文字批注带原文引用。
- 文字批注在正文中使用可点击虚线下划线；点击标记文字会打开主题化详情面板，展示引用原文与笔记内容。`ReaderTapObserver` 把普通翻页轻点延后到内联识别器处理后，详情面板打开时不会同时翻页。
- 仿真翻页不再通过 gesture arena 与 `SelectionArea` 竞争，而是读取原始指针流：快速水平拖动达到 18px 后开始折页，长按超时后让位给文字选择；轻点观察器同步使用 Flutter `kTouchSlop`，修复 8–18px 手指抖动落入无响应空档导致右侧轻点或滑动偶发失效的问题。
- `ReaderTextPage` 新增显示偏移到章节 UTF-16 offset 的选区映射，`ReaderSelection/TextAnchor/CanonicalLocator` 成为标注定位真相源；EPUB 原有粗体/斜体样式与标注样式分段合并，不改变分页测量。
- SQLite 升至 v20：`book_notes` 增加稳定 UUID `annotation_id` 与 `payload_json`，迁移会幂等补齐旧记录并创建唯一索引；`BookNoteDao` 保留文本标注按 CFI 合并语义。批注导航页支持定位和删除，书源书仍须先加入书架才能持久化。
- 画笔记入口、画布、笔迹绘制与保存回调已移除；旧 `ink` 数据仍可由模型和同步兼容层安全反序列化，但不会再作为可创建类型暴露，也不会出现在正文或批注列表中。
- notes WebDAV 数据集继续保持关闭；不改同步能力开关或远端记录身份，适配器继续保留 `annotation_id/payload_json` 兼容映射。新增模型、迁移、选区工具栏、可点击批注、导航和阅读器回归测试。
- 审查修正：轻点由共享 `ReaderTapObserver` 单点处理，长按/拖选与批注点击不再和翻页重复触发；零首行缩进时选区会跳过被隐藏的源空白；旧批注按章节 ID、章节标题和旧字段逐级回退，批注列表按真实章节顺序排列。
- 验证：标注、迁移、同步兼容、选区手势、可点击批注、仿真翻页与两套阅读器专项通过；最终全量 `flutter test --no-pub` 543 项通过。全仓格式检查与 `git diff --check` 通过，`flutter analyze --no-fatal-infos --no-fatal-warnings` 无 error/warning，保留 64 条既有 info 级提示。未执行真机视觉验收或签名构建。

### WebDAV 同步书源与在线书籍

- WebDAV v1 新增稳定 `book_sources` 数据集，按书源 ID 使用 HLC LWW 与 tombstone 同步用户注册的公开清单信息、启用状态和添加时间；WebDAV 密码、书源令牌、章节正文、目录和缓存继续禁止上传。旧客户端会保留未知数据集记录，不需要提升远端 `schema_version`。
- `books` 数据集补齐在线书的书源/书籍快照与导入时间。目标设备会把完整的 `storage_type = online` 记录直接物化为可打开的书架项；在线 tombstone 只删除仍为在线状态的记录，不会删除同源但已经下载到本地的书籍。
- `progress` 数据集现在同时承载在线书章节 ID、章节序号、章内进度和书架汇总进度；同步成功后通过书库事件总线刷新书架与首页。同步内容页新增“书源”开关，并把原“书架信息”明确为“书架与在线书籍”。
- 书源注册更新同时修复运营者、联系入口、许可、权利声明和目录页大小字段在刷新时丢失的问题。
- 验证：新增 8 项书源/在线书同步回归，WebDAV、书源和同步 UI 定向 34 项通过；最终全量 `flutter test` 504 项通过。全项目 `flutter analyze --no-pub` 无 error/warning，保留 64 条既有 info 级风格提示。

## 2026-07-25

### 2.3.8 Android 本地签名构建

- 为阅读字体初始化与跨平台字号一致性改动生成 `2.3.8+260725020` Android Release split APK。三份产物的实际版本码为 armeabi-v7a `260726020`、arm64-v8a `260727020`、x86_64 `260729020`；均为 `com.niki.xxread`，并通过 `apksigner verify --verbose` 与共享 Origo keystore 证书身份比对。
- 未向 PKT110 安装任何 APK。全量 `flutter test` 492 项通过；全项目 `flutter analyze` 被两份既有 `*.sync-conflict-*.dart` 测试备份中的过期必填参数阻断，非本次构建元数据或签名改动所致。

### 阅读正文自然对齐与字间距设置

- 本地 TXT/EPUB 与在线书源阅读器新增共享“对齐方式”和“字间距”设置：默认自然对齐，避免 `TextAlign.justify` 按行分摊剩余宽度造成同一页每行字距不同；用户仍可切换两端对齐。字间距范围为 `0.0–1.2`、步进 `0.1`、默认 `0`，不引入字体资源或新依赖。
- `ReaderSettingsStore` 统一持久化两个字段；分页缓存指纹、纵向列表 key、分页测量与最终 `RichText` 全部使用相同的字间距和对齐方式。排版变化继续按 canonical 文本 offset 恢复阅读位置。“系统默认字体”仍保持 `fontFamily: null`，真正跟随平台字体。
- 同步恢复阅读字体就绪门禁和正文 `TextScaler.noScaling` 行为，避免字体偏好尚未恢复时先绘制临时系统字体，以及 iOS/Windows 系统缩放对阅读字号二次放大。
- 验证：排版、设置、分页与两套阅读器定向 73 项通过；全量 492 项测试通过。正式源码定向静态分析无 error/warning，仅有既有 info；全项目分析被旧 Syncthing 冲突备份 `lib/pages/reader/native_reader_page.sync-conflict-20260723-185753-XNTYOKG.dart` 的过期构造参数阻断，未删除该备份。
- iOS Profile 真机包已用 Xcode 27 beta 构建为 `build/ios/iphoneos/OpenReading.app`（53.5 MB），签名标识 `com.niki.xxread`、Team ID `2HD5836RZ2` 校验通过。SloanePro 当时被 CoreDevice 标记为 `unavailable`，安装返回 4016；需解锁手机并保持 USB/受信任连接后重试，不需要重新编译。

## 2026-07-24

### GitHub Release 增加未签名 iOS IPA

- 版本 Tag 发布工作流新增独立 macOS 构建 job：以 `flutter build ios --release --no-codesign` 生成应用，并打包为标准 `Payload/*.app` 结构的 `OpenReading-iOS-unsigned-<version>.ipa`。
- IPA 会校验版本、构建号、ZIP 完整性、Payload 结构以及不含 `_CodeSignature` / provisioning profile；随后纳入 GitHub Release、SHA-256 清单和官网镜像 manifest。Release 正文新增平台下载表格与可点击链接，并明确该 IPA 仅供开发者自行签名或重新打包，普通测试走 TestFlight。
- 风险：未签名 IPA 不能由终端用户直接安装；后续如增加 Ad Hoc 分发，必须另行实现受限设备、签名和 HTTPS manifest 流程，不能将其混同为公开安装包。

### 阅读字体初始化与跨平台字号统一

- 本地 TXT/EPUB 与在线书源阅读器新增阅读字体就绪门禁：`AppSettingsNotifier` 尚未完成偏好恢复和 `FontLoader` 注册时只保留主题化打开占位，正文、分页和打开完成信号均等待最终字体，避免先显示系统默认字体、随后突然切成思源宋体或用户字体。
- 书籍正文统一使用不叠加系统缩放的 `readerBodyTextScaler`；iOS Dynamic Type 与 Windows 系统文字缩放不再二次改变正文实际字号，阅读器自身 14–32 档字号继续生效，工具栏等界面控件仍遵循系统无障碍设置。字体 ID 仍参与分页指纹，字体选择变化会按既有逻辑清理布局并按文本锚点恢复。
- 验证：正文分页、本地阅读器和字体设置共 22 项定向测试通过，书源阅读器打开流程 1 项通过；全项目静态分析无 error/warning，保留 64 条既有 info 风格提示。
- 公开 `CHANGELOG.md`、应用内四语 `assets/changelog/changelog.json` 与 `.github/release-notes/v2.3.8.md` 已补齐 2.3.8，内容聚焦上述阅读字体修复。尚未占用正式构建号，也未改 `pubspec.yaml` 版本。

## 2026-07-23

### Android SAF 与大型 TXT 发布阻断修复

- OPPO PKT110 的已授权目录曾由系统 `ExternalStorageProvider` 临时返回空列表；重启手机后同一授权和目录恢复，确认不是应用权限或格式过滤故障。排查期间加入的 direct-child、MediaStore 和目录文件描述符回退全部移除，正式代码只保留标准 `DocumentsContract` 扫描。
- SAF 文件物化改到 Android IO executor，Dart 在继续源哈希、托管复制和副本哈希前校验物化文件大小与扫描元数据一致。74,015,054 字节 TXT 的临时文件与托管副本大小、内容哈希已确认一致。
- 大型 TXT 的第二个空正文根因是过期的 `routeEntranceCompleted` 标志覆盖了实时 `AnimationStatus.forward`；路由等待现在以实时动画状态为准，并新增 active entrance 回归。用户已在 Debug 真机确认该 TXT 可正常阅读。
- 清理后相关 51 项测试通过，Android Kotlin 编译成功；全量测试 485 项通过、3 项既有首页/设置断言失败，完整静态分析无 error/warning、保留 64 条既有 info。`2.3.7+260723012` 三 ABI Origo Release 本地构建、包名、版本码和签名验证通过；PKT110 当前 Debug 签名不同，因此 `adb install -r` 被系统安全拒绝，未卸载或清除数据。
- 随后把 3 条过期 UI 断言与当前默认网格布局、10.5px 导航标签同步，全量测试达到 488/488。`v2.3.7` 正式 Run `30010883735` 的 GitHub Release、Android、Windows、Linux、macOS universal 签名与公证、Web 部署和官网镜像全部成功；官网六个平台/架构均为 build `260723012` 并通过 Range 206。

### 更新提示支持 Markdown 与显式跳过版本

- 更新弹窗改为响应式“版本扉页”布局，突出当前版本到最新版本的迁移关系，并复用应用主题展示可选择、可滚动的更新说明；新增无第三方依赖的常用 Markdown 渲染，覆盖标题、段落、有序/无序列表、引用、代码块、行内代码、强调、删除线和 HTTP(S) 链接。
- 自动更新检查不再把“稍后”误当成永久忽略；只有用户点击“跳过此版本”才写入 `skipped_update_version`。手动检查仍可查看被跳过版本，后续更高版本也会正常提示。
- Markdown 与更新提示定向 6 项测试通过，包含 390×700 紧凑视口；目标静态分析零问题。全项目静态分析无 error/warning，保留 65 条既有 info；全量测试中本次更新相关全部通过，剩余 3 项失败来自同期首页导航字号与书库布局设置断言。

### 书籍下载队列改为有界并发

- 全局书籍下载从单 worker 串行队列改为最多 2 本书并发；单本书内部仍保持最多 3 章并发，使常态网络峰值约为 6 个章节请求。慢书源不再独占整个队列，空出的执行槽按入队顺序补入下一本书。
- 每条排队任务保存自己的 `BookSourceShelfService`，发现页、搜索页等不同入口同时下载时不再复用首个活动任务的客户端实例。等待中和活动中的取消语义保持不变，活动任务真正结束后才释放并发槽，避免超出上限。
- 新增并发上限、FIFO 补位、任务服务隔离、活动取消补位和等待取消回归；下载控制器、发现页、书源下载服务与协议端到端共 26 项定向测试通过，目标静态分析零问题。全项目静态分析无 error/warning，保留 65 条既有 info；单并发全量 474 项中本轮下载相关全部通过，剩余 3 项为同期首页导航字号和书库设置显隐断言，与下载队列改动无关。

### 超长目录与首次切章不再挤占交互帧

- 阅读目录在书籍/书源目录加载阶段预先生成展示模型；目录面板无折叠时直接复用树列表，折叠可见性从逐项回溯祖先的最坏平方复杂度改为单次深度栈扫描。6000 层目录回归覆盖首次挂载、搜索与定位仍沿用原语义。
- 在线书源的 HTML 和 64 KiB 以上正文在后台 isolate 转换为 canonical text，规范化正文以 8 章 LRU 限制重复内存；相邻章节分页预热延后到正文首帧之后。章节和目录网络结果写入内存后立即交给阅读器，JSON 磁盘持久化改为后台执行，不再等待 `flush` 才显示；同键写入串行并通过临时文件替换，清理缓存会使旧代写入失效，避免旧内容乱序覆盖或清理后复活。
- 大型 TXT 索引章节新增异步随机区间读取：首次显示和目录远跳都会在提交章节状态前等待当前、前一章、后一章窗口完成读取，更远预热也必须先完成异步读取；跨章节纵向列表对未加载片段显示占位，不再由 `build` 路径触发同步读盘。同步读取只保留为兼容回退。
- 验证：目录、章节缓存、章节文本、索引读取、本地 TXT/EPUB 跨章与在线书源阅读共 60 项定向测试通过；目标静态分析无 error/warning，阅读器文件保留既有 info 级风格提示。全量 471 项中 467 项通过，剩余 4 项为同期发现页按钮位置、首页导航字号和书库设置显隐断言，与本轮阅读性能路径无关。

### 分页页首不再出现空白行

- 段落间距继续完全服从用户的 0/1/2 档设置，但分页边界新增“原文归属范围”和“实际可见范围”分离：连续换行、空白段或生成的段落间距若落在新页顶部，只折叠该页顶部的空白视觉行，首个非空行及其首行缩进仍正常保留。
- 被折叠的换行仍归属于连续的 canonical offset 范围，书签、阅读进度和重排恢复不会因删字符而漂移；章节末尾只有空白时并入前一页，不再生成独立空白页。本地文件与在线书源共用同一修复。
- 新增段落间距 0/1/2、章节首尾连续空行和跨页 canonical coverage 回归；分页、本地/在线共享管线定向 34 项通过，目标静态分析零问题。全量运行 468 项通过，本轮阅读器相关测试全部通过；剩余 3 项失败来自同期首页导航字号和书库设置显隐断言。

### 书籍加载交接与超大 TXT 首屏性能

- 封面→正文、封面→加载和加载→正文不再使用 260–280ms 的短交接：阅读器内部加载/正文切换统一延长到 360ms，封面释放延长到 380ms，持续加载门槛调整为 850ms。加载态换成主题化书本、旋转细环和三点波浪动画，并尊重系统“减少动态效果”。
- 本地与在线阅读器在加载占位和加载动画期间继续挂载同一套 `ReaderChromeOverlay`；点击阅读区域可立即呼出标题栏与控制栏并退出。封面释放到加载态后同步开放阅读页点击，不再等视觉进度完全结束。
- 70MB 级 TXT 的必现卡顿来自某个章节仍被当成巨型字符串：即使索引在后台 isolate 生成，正文首帧仍可能在 UI isolate 同步解码并分页几十 MB。大 TXT 索引缓存升级到 v4；所有超过约 32K 字符的章节都按换行边界分片，不再只处理无章节整本书。索引文本窗口由同期异步读取实现加载当前及必要相邻片段，首次全量索引继续延后到封面→加载交接结束后启动。
- 修复“首次无缓存顺滑、缓存后每次打开反而掉帧”的时序倒挂：缓存命中此前会在 460ms 封面飞行内立即反序列化大型目录、构建章节描述、读取相邻片段并启动首屏分页。现在缓存读取与章节窗口准备统一等入口路由落定后开始，且不追加首次索引专用的 800ms 延迟；返回中途取消或路由被移除时不会继续启动重活。
- 缓存门闩首版曾把新路由开始前的初始 `AnimationStatus.dismissed` 误当成退出，导致大型 TXT 直接返回空章节并提示没有正文。状态机改为必须先观察到 forward/reverse 运动，之后的 dismissed 才代表取消；新增“初始 dismissed → forward → completed”回归，禁止再次把路由初始态等同于退出态。
- 验证：新增大无结构 TXT 分片内容连续性、慢加载交叉透明度、加载期点击交互和主题背景回归；TXT 解析、封面路由、本地阅读器与在线书源阅读器定向 58 项通过，首页系统栏/悬浮导航 3 项通过。目标静态分析无 error/warning，保留阅读器既有 15 条 info 提示。单并发全量 460 项中本轮相关失败已修复并复跑通过，仍有 5 项同期导航字号、分页高度和设置页显隐断言与当前实现不一致，均不在本轮阅读器改动范围。
- 用户要求将本轮书籍打开、加载、悬浮导航、退出缩回和 Android 预测性返回动画统一归入 `2.3.7`；`CHANGELOG.md`、应用内四语种 changelog 与 GitHub release notes 已同步。签名测试包 `2.3.7+260723005` 三 ABI 验证通过；PKT110 上原 Debug 签名版本经用户确认后卸载清数据，arm64 Origo Release 安装成功并启动到 `MainActivity`。
- 正文密集页面的返回掉帧进一步定位为退出时仍需合成完整阅读层树。封面路由现在在退出信号发布时开启 `SnapshotWidget`，首个退出帧把当前屏幕冻结为纹理，后续只合成单张快照；预测性返回取消时继续使用快照恢复，动画完成后再释放并切回实时正文。书籍路由、page-curl、本地/书源阅读器与首页悬浮栏联合回归 82 项通过，目标分析仅保留 page-curl 既有 3 条 info。

### Android 侧滑返回不再顶跳首页悬浮栏

- 阅读器沉浸模式隐藏系统栏后，Android 预测性返回会临时显示手势提示区域并重新上报底部 `viewPadding`，导致底层首页正在回弹的悬浮导航中途整体上移。首页现在在整个阅读活动（异步准备、路由存活、退出动画）期间沿用进入阅读器前的稳定系统安全区，路由彻底结束后才接受新的 inset。
- Android 宿主在创建窗口、隐藏和恢复系统栏时统一重申透明 edge-to-edge，并关闭状态栏/导航栏的系统对比度遮罩，减少手势提示线弹出时附带的黑色底边。
- 新增沉浸阅读期间隐藏系统栏、临时手势栏和退出后恢复三段 inset 回归，并补充阅读活动生命周期断言。

### 非书库入口统一为纸面开合动画

- 无法稳定捕获封面位置的阅读入口移除原有 `0.985 → 1.0` 整页缩放，改为纸面纵向位移、背景淡入和延迟正文淡入：首页“继续阅读”使用较轻的 2.5% 视口位移，发现页详情使用 4% 位移延续底部面板方向，退出按同一路径下沉。书库网格、卡片和列表继续使用现有封面展开/缩回；减少动态效果开启时取消所有新位移。
- 发现页书籍详情不再先关闭详情、再弹出第二个“加入书架”面板；详情、加入方式、提交、成功、已存在、失败重试和下载进度统一在一个 `AnimatedSwitcher` 状态流中。新加入成功播放小封面落入书架横线的反馈，停留 550ms 后面板向下关闭；重复加入只显示信息态，失败保留面板，下载可在面板内查看并转入后台。
- 新增首页/发现页纸面位移、无整页缩放、减少动态效果、详情到阅读器接力、在线加入成功/重复/失败、下载转后台和自动关闭回归；书籍转场、发现页、首页、两种阅读器、系统栏与 page-curl 定向共 89 项通过，相关文件静态分析零问题。全量测试复跑只剩 `home_bounce_navigation_item_test.dart` 两项并行导航样式失败：实现字号为 10.5，测试仍期望 11.5；首次全量中的章节缓存临时目录清理竞争在复跑时未重现。

### 书籍打开改为封面后台预热正文

- 原封面展开路由为了避免占用动画帧，会等 460ms 飞行完成后才挂载阅读器；因此封面只能过渡到纯色占位，解析和分页结束时正文再突然出现。
- 现在路由首帧就把本地与在线阅读器挂载在封面飞行层之后，并在后台恢复设置、解析内容和准备首页；封面飞到接近全屏后不会再按固定时长撤掉，而是等待正文首帧和阅读器内部 260ms 淡入完成，再用 280ms 与正文直接交叉透明度。只有持续加载时才把封面渐隐到已淡入的加载动画，加载完成后再交叉渐变到正文，整个链路不再暴露裸主题白底。系统栏切换仍延后到路由落定，避免封面动画中途改变视口 inset。
- 书库与首页的点击回调在第一个 `await` 之前就发布阅读活动状态，手机悬浮导航立即用 180ms ease-out 向下滑出并屏蔽点击；退出动作起步时，导航栏同步用 360ms `easeOutBack` 从屏幕下方回弹。减少动态效果开启时两个过程直接跳到结束态。
- 封面放大和退出缩回统一为 `Cubic(0.16, 1.0, 0.3, 1.0)`：前段快速响应点击，后段逐渐减速落位。动画回归按等时间段位移量验证后段小于前段，防止退出再次退化为慢起快收。
- 退出时序后续改为“动作起步即回弹导航”：工具栏返回、系统返回与 Android 预测性侧滑一开始，悬浮导航就从下方弹出，不再等反向路由结束。侧滑取消时导航栏重新收起。
- Flutter 3.44 的 `PredictiveBackEvent` 现直接驱动自定义书籍路由 controller，封面缩回跟随 Android 14+ 系统边缘手势进度；提交手势从当前位置继续 reverse，避免 Flutter 默认 commit 路径重置 controller 后的跳帧。本地书和已加入书架的在线书支持跟手返回；需要退出确认的直接在线阅读仍保留 `PopScope` 门禁。Android Manifest 显式开启 `enableOnBackInvokedCallback` 。
- 退出正文→封面的交接提前为返回进度 `2%..40%` 的直接线性映射，纸色不再延后遮住封面；交接完成后通过独立工作作用域暂停 page-curl ticker、同步抓图和后续快照预热，侧滑取消并恢复全屏后再继续。异步 `toImage` 在 debug 模式会先检查 boundary 已完成 paint，避免 `debugNeedsPaint` 断言。
- 真机截图确认偶发红屏是 `RenderBox was not laid out: RenderTransform`：阅读路由 `pop` 起步时 `Navigator.push` Future 已返回，书库 `_loadBooks()` / 首页 `_loadAllStats()` 提前重建卡片，而封面缩回仍每帧读取目标坐标。现在调用方等待 `route.completed`，把书名、进度和统计刷新延后到反向动画完全离开 Overlay；坐标解析遇到祖先未布局或 resolver 异常时安全使用点击时捕获位置，不再把断言冒到错误页。
- 封面路由、预测性返回提交/取消、刷新时序、翻页快照暂停、正文就绪门控、慢加载双重渐变、悬浮导航、TXT/EPUB 初始化与在线书源阅读定向共 77 项测试通过；目标文件静态分析无 error/warning，阅读器文件保留 15 条既有 info 提示。Android debug APK 已完成本轮状态驱动封面交接构建，并覆盖安装到 PKT110。

### 本地 TXT 目录远跳后的反向翻页不再闪页

- 目录从前部远跳到后续章节时，水平阅读器过去继续复用旧 `PageController`，新章节窗口第一帧会短暂落在旧绝对页码；从标题页反向进入上一章时，又会在动画过半后直接向列表头部插入更早章节，导致控制器索引瞬间指向另一张纸，再跳回正确页。
- 目录远跳现在原子换用目标索引正确的新控制器，首帧布局完成前只显示当前阅读主题背景；反向章节窗口在滚动停止后才扩展，并以新增页数补偿新控制器初始索引，标题页到上一章末页保持普通连续滑动。
- 新增八章 TXT 目录远跳回归，验证目标标题首帧定位、过渡背景以及上一章末页已准备；本地阅读器 EPUB/TXT/设置/初始进度共 15 项通过，静态分析无 error/warning，仅保留目标文件既有 14 条 info 提示。

### 首页导航排序与外观设置收纳

- 设置页外观卡片把“悬浮导航栏”和“书库布局”收纳为两个摘要入口；独立页面分别承载导航实时预览、文字模式、拖拽排序、恢复默认，以及卡片/网格、手机列数和网格详情设置。
- 首页导航顺序以 `home/library/discover/settings` 稳定 ID 列表持久化，非法、重复或缺失记录会按默认目的地补全；排序同步到手机横滑页面、悬浮底栏和宽屏侧边栏，并按目的地保持当前页面。带文字模式字号由 12.5 调整为 11.5，字重收敛为未选中 600、选中 700。
- 新增简中、繁中、英文和日文文案，以及顺序恢复/规范化/持久化、实时预览、显示模式、拖拽和书库条件选项回归。首轮全项目 433 项测试通过；补充 rail→mobile 与切页动画竞争修复后，目标文件静态分析零问题、导航/书库定向与应用 smoke 共 21 项通过。最终全量复查受工作区并行的 `native_reader_initial_progress` 改动影响，出现 2 项无关失败，随后该并行文件又进入空安全编译错误状态，本功能未改写该阅读器路径。

### 应用主题与强调色合并

- 设置页移除独立“应用主题”，只保留“强调色”；18 个快捷颜色之外新增 HSV 饱和度/亮度色盘、色相条、十六进制输入和 Material 3 色板预览。
- 强调色成为应用配色唯一来源，浅色和深色 `ColorScheme` 统一由 `ColorScheme.fromSeed` 生成，不再把强调色局部覆盖到另一套主题上。
- 新增 `appAccentColorV2`，首次升级时按“旧全局强调色 > 旧自定义主题色 > 旧命名主题色”的顺序迁移并清理双层旧字段；迁移、持久化、色盘确认和非法十六进制输入共 6 项定向测试通过，全项目 431 项测试通过，静态分析无 error/warning。

### 阅读主题支持跟随系统

- 阅读主题列表首位新增“跟随系统”；浅色系统外观复用“白天”，深色系统外观复用“纯黑”，选择结果继续通过既有阅读设置在本地与在线书源阅读器之间共享并持久化。
- 两种阅读器监听系统亮度变化并即时重绘；旧主题排序首次读取时会把新选项迁移到首位，之后仍可在主题管理页与其他预设、自定义主题统一排序。
- 关闭玻璃效果后，阅读控制栏与图标按钮不再额外提亮或降低边框透明度，直接使用主题的实色；系统状态栏和导航栏也提交当前阅读背景色，并在主题选择、应用恢复及系统亮度变化时同步刷新。
- 补齐简中、繁中、英文和日文名称；系统主题、非玻璃控制栏和系统栏定向 41 项及全项目 434 项测试通过，目标文件静态分析无 error/warning，保留 15 条既有 info 提示。

### 本地 EPUB 水平跨章分页移出动画路径

- 定位到本地阅读器在 `PageView.onPageChanged` 动画过半时扩大章节窗口，并同步分页窗口外的新 EPUB 章节；新章节文本较长时，这项 UI isolate 工作会直接占用跨章动画帧。该路径与在线书源阅读器独立，在线书源连续翻页改动不会直接影响本地 EPUB。
- 水平滑动现在会在页面绘制后预热章节窗口外前后相邻章节；若页面仍在拖动或回弹，分页持续延后到滚动停止。排版指纹变化会丢弃过期任务，避免字号、边距或视口变化后错误复用布局。
- 新增真实四章 EPUB 回归，记录分页缓存缺失并验证跨章前后一窗口已完成预热、跨章动画期间零分页缺失；本地阅读器 EPUB/TXT/设置定向 12 项通过。静态分析只有目标文件既有的 14 条 info 级风格提示，无 error/warning。

### v2.3.6 发布日志整理

- 已同步 `CHANGELOG.md`、应用内四语版本历史与 GitHub release notes：公开说明覆盖缓存优先的在线书源阅读、首页直达书源阅读器、水平翻页中断保护、深色阅读主题打开转场、在线字体下载流畅度、书库网格阅读信息，以及 WebDAV 可读原文件目录与历史兼容。
- `v2.3.6` 已发布为 GitHub Latest Release，基础构建号为 `260723001`；6 个安装包和 `SHA256SUMS.txt` 完整下载校验通过。Android 三 ABI 已通过共享 Origo 签名校验；macOS universal 已通过 Developer ID、Hardened Runtime、Apple 公证、staple、codesign 与 Gatekeeper，并确认包含 x86_64/arm64。
- 官网六个平台/架构均已镜像 2.3.6 且 Range 返回 206；Flutter Web 已部署为 `2.3.6+260723001`。正式 Run `29979062941` 的 9 个 job 全部成功。
- 首次误提前创建的 `v2.3.6` Tag 指向仍声明 2.3.5 的提交，工作流在产生产物前即失败；修复时仅短暂禁用 Tag 删除/重写规则，纠正到版本一致且已通过主线检查的提交后立即恢复 `Protect version tags` 为 active。

### 在线字体下载掉帧修复

- 在线字体网络进度从全局 `AppSettingsNotifier` 通知中拆出，并以 100ms 间隔节流；字体弹窗只局部重建在线字体区域，`MaterialApp` 仅监听 App 字体 family 与语言变化，下载分块不再引发应用根节点和设置页连续重建。
- TTF/OTF 签名检查与 SHA-256 改为后台 isolate 直接读取临时文件并流式计算，避免 18–25MB 中文字体在 UI isolate 上同步哈希；`FontLoader` 仍在下载完成后注册一次。
- 新增 100 次突发进度的通知隔离回归，以及真实分块写盘、哈希、注册结果回归；字体定向 10 项稳定通过，目标文件静态分析零问题，全项目分析无 error/warning，保留 69 条既有 info 提示。首次全量 416 项通过；随后并行工作区更新后的 419 项全量运行有 1 项无关的书源横滑动画测试失败，单独重跑仍失败，未在本次字体修复中扩展处理。

### 在线阅读改为缓存优先打开

- 在线书源现在同时落盘缓存章节目录和已读正文；再次进入阅读页时先恢复目录与当前章节，不再先等待书源完整目录请求，离线或书源暂时变慢时也能打开 30 天内的缓存内容。
- 章节目录缓存超过 30 分钟、正文超过 12 小时后采用 stale-while-revalidate：本次仍立即显示旧缓存，网络更新在后台完成并供下次打开使用。整本下载保持严格刷新路径，陈旧正文不会被静默打包进本地 TXT。
- 缓存键加入书源 API 地址，避免同 ID 书源迁移后串用旧内容；设置页既有“书源章节缓存”清理入口继续同时统计和删除目录、正文及内存缓存。
- 新增跨实例磁盘复用、正文后台刷新和目录后台刷新回归；书源、下载、缓存管理定向 43 项与全项目 414 项测试通过，改动文件静态分析零问题；全项目分析无 error/warning，保留 69 条既有 info 提示。

### 书库网格可选显示书名与进度

- 设置页“书库布局”在网格模式下新增“显示书名和进度”开关，默认关闭以保持既有纯封面网格；偏好通过 SharedPreferences 独立持久化。
- 开启后每个封面下固定显示一行书名和一行精简进度，长书名使用单行省略号，进度以细条和百分比组合展示，避免网格高度随内容变化。
- 简中、繁中、英文和日文文案已补齐；设置持久化和网格信息组件定向 4 项测试通过。

### WebDAV 书籍改为云端原文件保存

- WebDAV 书籍内容始终未做端到端加密，但旧路径以 SHA-256 作为无扩展名文件名，容易被误认为密文，也无法在云端文件管理器中直接按格式识别。
- 新上传路径最终确定为 `books/<书名 - 作者>/<原文件名>`：上传字节保持原样，原文件名和扩展名保留；未知作者省略，非法目录字符安全替换。同名但内容不同的书使用 `(2)`、`(3)` 可读编号，避免覆盖。
- SHA-256 不再出现在书籍目录或文件名中，只保存在同步元数据和本地索引里，用于判断同名文件内容是否一致及恢复完整性校验。持久封面路径不变。
- 下载继续完全信任远端元数据中的路径，因此历史 `blobs/books/sha256/<prefix>/<hash>` 文件无需迁移且仍可恢复；重新上传同一本书时会写入新的可读原文件路径。
- 新增中文、空格文件名、路径非法字符、同名同内容复用、同名异内容编号和历史路径兼容回归；WebDAV 全套 36 项与全项目 414 项测试通过，静态分析无错误或警告（保留 69 条既有 info 提示）。

## 2026-07-22

### v2.3.5 正式发布

- 公开 `CHANGELOG.md`、应用内简中/繁中/英文/日文版本历史和 GitHub release notes 已补齐 2.3.5，内容聚焦简洁首页、浏览器数据库与自动 Web 部署、macOS 签名公证链路，以及设置、封面和平台图标细节。
- 发布前清理了本地导入流程残留的联网封面搜索服务：EPUB/PDF 优先使用文件内封面，TXT/MOBI 等缺少内置封面时仅在本地生成默认封面，不再静默请求豆瓣、Google Books 或 Open Library。
- `v2.3.5` 已发布为 GitHub Latest Release，基础构建号为 `260722009`；正式资产包含三套 Android APK、Windows x64、Linux x64、macOS universal 和 `SHA256SUMS.txt`。
- macOS universal App 已通过 Developer ID、Hardened Runtime、Apple 公证、staple 和 Gatekeeper 验证；首次发布暴露并修复了 Environment Secret 格式、P12 Base64/密码和非 ASCII App 路径下的 `Info.plist` 读取问题。
- 官网已镜像六个平台/架构槽位，全部返回 2.3.5 且 Range 请求为 206；Flutter Web 已部署为 `2.3.5+260722009`。Cloudflare 会对 GitHub Runner 的公网版本探测返回 403，源站部署包装器已在原子切换前严格校验版本，因此后续 CDN 探测失败只记录告警，不再推翻成功部署。

### 首页收敛为继续阅读入口

- 首页移除阅读计划、每日目标、专注计时和 AI 阅读建议，不再为首页初始化对应服务；主要入口改为最近一本书的封面、作者、进度和继续阅读操作。
- 今日、本周、累计阅读时长与七日节奏合并为一张统计卡，其他最近阅读改为轻量封面列表；手机与宽屏统一复用同一响应式实现，删除旧版重复仪表盘及其拆分文件。
- 新增 320px 手机与 1280px 宽屏回归，锁定主卡、阅读节奏、最近阅读以及“无阅读计划 / 无 AI 文案”；视觉快照检查修复了周节奏和封面列表的窄屏高度溢出。首页目标文件静态分析零问题，Flutter 全量 399 项测试通过；全项目分析无错误或警告，仍报告 68 条其他文件的 info 级风格提示。

### macOS GitHub Release 签名与公证链路

- Release workflow 新增受 `MACOS_RELEASE_ENABLED` 仓库变量控制的 macOS job：构建 arm64/x86_64 universal App，导入临时 Developer ID keychain，以 Hardened Runtime 签名，通过 App Store Connect API Key 提交 Apple 公证，staple 后再打包 ZIP。
- 发布门禁会校验 bundle 版本、双架构、Developer ID 签名、公证票据和 Gatekeeper；macOS ZIP 同步进入 GitHub Release 不可变资产集合、SHA-256 清单和官网 import manifest。
- Release sandbox 增加出站网络权限，避免正式签名 App 无法访问 WebDAV、书源和更新接口。证书与公证密钥只从受审批的 GitHub `release` Environment 读取并在 runner 结束时清理。
- 官网导入器已改为 manifest 驱动的动态资产集合并部署生产；Developer ID P12 与 App Store Connect API Key 已写入受审批的 GitHub `release` Environment，`MACOS_RELEASE_ENABLED=true`。本次 v2.3.5 将作为首个正式签名、公证并进入 GitHub Release 与官网镜像的 macOS universal 版本。

### WebDAV 跨平台书籍元数据与封面恢复修复

- Android 上传、iOS 下载真机联调发现：书源下载形成的 TXT 在恢复时会被普通导入器把第一章标题误判为书名，同时 WebDAV 只传原文件、不传持久封面，导致另一设备的书名和封面与上传端不一致。
- 书籍恢复现以远端书架元数据校正书名、作者和书源身份；持久封面作为独立的 SHA-256 内容寻址 blob 上传和恢复，书籍与封面均校验大小及摘要。旧远端记录保持兼容；本地有封面而远端缺失或哈希变化时重新列入待上传以便补传。
- 数据库升级到 v19，`sync_book_files` 新增封面摘要、名称、大小和远端路径；迁移可对旧表幂等补列，协议新增字段保持旧客户端可忽略。
- WebDAV 连接配置与同步内容拆成独立页面；同步内容开关即时持久化，关闭阅读进度后下一次同步不再处理该数据集。
- 新增书名/作者覆盖、封面上传/复用/恢复、损坏封面拒绝及临时文件清理、旧表补列、封面元数据快照和同步范围即时保存回归。

### 在线书源整本下载改为流式落盘

- 生产下载记录确认 1235 章、约 39 MB 的正文已全部成功返回，但旧实现仍把整本 `BookSourceChapterContent` 保存在列表中，随后再构造完整 `StringBuffer` 并一次性 UTF-8 写盘；中文字符串、最终拼接和编码缓冲叠加会造成远高于下载体积的峰值内存，容易在移动设备完成网络阶段后被系统终止。
- `BookSourceShelfService` 改为每批最多 3 章并发，批次完成后立即按目录顺序写入同目录 `.part` 文件并 flush，只保留当前批次正文；全部成功后才改名为正式 TXT。失败或取消会尽力关闭 sink 并删除临时文件，不暴露半本书为可读本地文件。
- 新增“第二批尚未完成时第一批已落盘”和“取消后不残留 `.part`/TXT”回归；书源下载 5 项、下载控制器 3 项和相关静态分析通过。默认翻页模式改为水平滑动后，两条仍验证上下翻页交互的旧测试已显式固定目标模式；WebDAV 同步内容页测试移除不必要的 FFI 数据库依赖；全量 398 项通过。

### v2.3.1 iOS App Store 90683 修复与 TestFlight 交付

- App Store 静态校验发现 `file_picker` 间接链接的 `DKCamera` 引用了前台定位 API，而 `Runner.app` 缺少 `NSLocationWhenInUseUsageDescription`；主应用现补充用途说明，声明仅兼容图片导入组件处理照片位置信息，不在后台定位或用于其他用途。
- 占用正式构建号 `260722006`，营销版本为 `2.3.1`。发布前 386 项 Flutter 测试、静态分析、格式检查与 Web release 构建全部通过；Wasm dry run 仍只有 `pdfx` / `flutter_tts` 既有兼容性警告。
- App Store Archive 与 IPA 使用 Cloud Managed Apple Distribution 和 App Store provisioning 成功导出；实际 IPA 已核对包名、版本、用途说明、iCloud Production entitlement、隐私清单、非豁免加密声明与深度 codesign 完整性。
- Transporter 于 14:53 将 `2.3.1 (260722006)` 成功交付到 App Store Connect，交付日志确认 `UPLOAD SUCCEEDED with no errors`，当前等待 Apple 完成应用处理。产物位于 `build/testflight/2.3.1-260722006/`，IPA SHA-256 为 `C3ECE0C8E0BA40E9DE85169635C34A5E4E1FD6C969B7A6F76561672B67487255`。Flutter 仍提示启动图使用默认占位资源，后续正式商店审核前应替换。

### 下载任务逐条取消

- 下载任务页和下载进度弹窗新增单任务取消。等待任务取消后不进入 worker；活动任务通过独立取消令牌中止章节目录、重试等待和并发章节请求，取消不会记为失败，队列继续下一条。
- Android 前台下载服务新增 `CANCEL` 动作，移除对应活跃任务和系统通知；文件写入前后均检查取消状态，已创建但尚未入库的文件会被删除。
- 新增活动任务取消后继续队列、等待任务不启动的控制器回归；下载控制器与书源下载定向 6 项通过，全项目静态分析零问题。

### v2.3.1 Android 快速测试构建

- 版本更新为 `2.3.1+260722005`，公开更新日志、四语应用内版本历史和 GitHub release notes 已记录 WebDAV 稳定性、新书上传策略及缓存/书源封面改进。
- 使用共享 Origo 身份完成三 ABI release APK；实际 versionCode 为 `260723005 / 260724005 / 260726005`，包名、版本和签名身份完成必要核对。便于真机测试的 arm64 包为 `build/app/outputs/flutter-apk/open-reading-2.3.1-260722005-arm64-v8a.apk`。
- 按用户要求未执行安装、真机、全量测试或完整发布验证；Android 坚果云 WebDAV 兼容性仍需通过该测试包实测。

### 书源封面请求风暴与缓存边界修复

- 发现页推荐书架、分类与最新列表改为纵向 Sliver 惰性构建，不再在单个 `SliverToBoxAdapter + Column` 中同步创建全部封面。
- 新增共享 `SourceCoverCache`：同 URL 请求去重、最多 4 路并发、瞬态错误单次退避重试、压缩字节内存/磁盘缓存；损坏图片解码失败会按 URL 驱逐并最多重新获取一次，旧 in-flight 请求不能覆盖或移除驱逐后的新请求。
- 书源书籍加入书架时把可用远程封面保存到 documents `covers/`；设置页新增安全缓存管理，分别显示并清理书源封面、在线章节和临时更新缓存，封面统计包含磁盘、压缩内存和 Flutter 解码缓存，不触碰书籍、数据库、阅读进度、已保存封面或凭据。
- 新增并发上限、请求去重/重试、驱逐竞态、磁盘复用、书架封面持久化、惰性 shelf 和缓存分类大小/清理测试；定向测试与全项目静态分析通过，全量测试结果见本轮最终验证。

### v2.3.0 iOS TestFlight 归档

- 为 TestFlight 占用正式构建号 `260722004`，营销版本保持 `2.3.0`；归档基于已发布、已真机 Profile 验证的 `v2.3.0` 提交，未包含归档期间其他任务产生的未提交 WebDAV 改动。
- 新增 App 级 `PrivacyInfo.xcprivacy`，按 Apple required reason API 规则为应用容器/iCloud 文件和用户授权文件声明文件时间戳用途 `C617.1`、`3B52.1`；`Info.plist` 同时声明不使用非豁免加密，避免 TestFlight 出口合规状态悬空。
- 发布前 Flutter 格式检查、静态分析、全量 373 项测试和 Web release 构建通过。App Store Archive 与 IPA 导出成功，Distribution profile 确认 `iCloud.com.niki.xxread` 使用 Production 环境、启用 beta reports 且关闭调试 entitlement；IPA 通过深度 codesign 校验。
- 产物保存在 `build/testflight/2.3.0-260722004/`，IPA SHA-256 为 `E13C346FB51675B9277CA271F06A02EAAE887EE53707EACD23245EC72207C5FE`。Flutter 仍提示启动图使用默认占位资源；不阻塞 TestFlight 归档，但正式 App Store 审核前应更换品牌启动资源。服务器端上传/验证尚未执行。

### v2.3.0 正式发布准备

- 正式版本统一为 `2.3.0+260722003`，公开 `CHANGELOG.md`、四语应用内版本历史与 `.github/release-notes/v2.3.0.md` 已覆盖 WebDAV 同步、书籍文件导出/系统关联、书库布局、Android 实时下载进度、书源窄屏重构和无阻塞顶部提示。
- 发布前质量门通过：Flutter 格式检查、静态分析、全量 373 项测试与 Web release 成功；官网后端 Ruff、95 项测试、compileall、`uv lock --check`、部署脚本语法以及客户端两份 GitHub Actions 工作流检查通过。
- 使用共享 Origo 身份构建 Android 三 ABI release；实际 versionCode 为 `260723003 / 260724003 / 260726003`，逐包通过 APK v2 签名与证书身份比对。Windows/Linux 和最终 `SHA256SUMS.txt` 由 `v2.3.0` Tag 触发的受保护 GitHub Actions 流水线生成，Environment 审批由仓库维护者完成。
- 发布提交 `da41a3d` 与 annotated Tag `v2.3.0` 已推送；主线 PR checks `29889957129` 和跨平台 smoke builds `29889957084` 全部成功。Release workflow `29890368280` 已通过 Tag/版本校验与源码质量门，并停在 `release` Environment 等待维护者审批；本地未代为批准。

### 应用内短通知统一为无阻塞顶部浮层

- 清理更新检查、用户协议、书源、字体、WebDAV 等页面遗留的 Flutter 底部 `SnackBar`，所有应用内短反馈统一走 `widgets/side_toast.dart`；Android 下载进度等系统通知保持独立，不受本次改动影响。
- 手机提示位于顶部居中，平板/桌面位于右上；默认 2.2 秒自动退场，警告和错误按可读性稍延长。连续提示直接替换，不堆叠排队；浮层使用点击穿透，不阻断阅读、滚动或按钮操作，并保留无障碍 live region 与减少动态效果适配。
- 新增组件回归覆盖自动退场、连续通知替换和底层按钮点击穿透；相关页面定向 21 项测试通过，`flutter analyze --no-pub` 零问题。全量测试执行期间与工作区内另一个更新日志测试进程发生并发冲突，执行至 366 项时无断言失败，但 `changelog_page_test.dart` 的测试设备被 `SIGTERM` 中断，未作为本次完成依据。

### 书籍文件导出、系统文件关联与分享接收

- 书库本地书长按菜单新增导出能力：Android 通过 MediaStore 流式复制到公共 `Download/开元阅读/` 并避免同名覆盖，iOS 使用系统文档导出面板，Windows/macOS/Linux 使用另存为；导出始终复制，不改变书库原文件和数据库路径。书源下载书明确以应用合成的 TXT 导出。
- Android 注册 TXT/EPUB 的打开、单文件分享和多文件分享 Intent；外部 `content://` 在临时权限失效前物化到受控缓存，执行大小、数量、总量、MIME/扩展名和文件头校验，冷/热启动统一进入持久化请求队列。单本导入后直接阅读，重复内容打开已有书，多本进入现有导入队列。
- iOS 注册 Document Types，并通过 Scene/AppDelegate 接收 security-scoped URL；Share Extension 使用 App Group inbox 向主应用交付文件。iOS 不保证分享扩展可以强制拉起主应用，因此“在开元阅读中打开”负责立即进入阅读，“分享”负责可靠添加并由主应用恢复后消费。
- Dart 新增 `BookExportService`、`IncomingBookService` 和平台桥，入站请求只有在数据库初始化和用户协议通过后才按 FIFO 消费；失败码与四语提示覆盖权限失效、不支持格式、超限、内容不匹配和部分文件跳过。桌面启动参数、macOS open-files 与 Linux MIME desktop entry 接入同一导入主链路。
- 发布前复核补齐 macOS 冷启动恢复与新请求接收的串行化/去重、单书路由入栈确认、混合文件过滤顺序，以及桌面入口 10 文件 / 500 MiB 请求级兜底；Android、iOS 和桌面统一保留 100 MiB 单文件限制。
- 验证：`dart format` 检查通过，`flutter analyze` 零问题，全量 `373` 项 Flutter 测试与 Web release 构建成功；Android 三 ABI release 使用共享 Origo 身份完成签名，包名均为 `com.niki.xxread`，versionName 均为 `2.2.10`，实际 versionCode 为 `260723002 / 260724002 / 260726002`，逐包通过 APK v2 签名和证书 SHA-256 身份比对。macOS AppDelegate Swift warnings-as-errors 类型检查通过；完整 macOS 构建仍被仓库既有的 10.15 deployment target 与当前 Xcode 仅支持 12.0+ 的冲突阻塞。系统选择器、OEM 文件管理器和 iOS 分享面板仍需真机验证。

### 书库卡片与纯封面网格切换

- 设置页“外观设置”新增书库布局选择：卡片模式保留既有书名、阅读进度和状态信息；网格模式只显示封面，点击继续阅读、长按仍进入书籍管理。
- 网格模式可选择手机每行 2 列或 3 列，两列提供更大的封面；平板与桌面按所选密度响应式增加列数，避免宽屏出现少量超大封面。布局模式和列数分别通过 SharedPreferences 持久化，升级后默认继续使用卡片模式。
- 简中、繁中、英文和日文文案已补齐；`flutter analyze` 零问题，布局偏好与响应式列数定向测试共 14 项通过。未执行签名构建或发布。

### Android 16 原生实时下载通知

- 书籍与官网 APK 下载继续复用既有 Flutter MethodChannel 和 Android 前台 `dataSync` 服务；Android 16+ 改用系统 `Notification.ProgressStyle`，以百分比短状态请求 promoted ongoing 展示，旧版 Android 继续使用普通进度通知。
- 新增 `POST_PROMOTED_NOTIFICATIONS` 非运行时权限；是否提升到状态栏或锁屏实时更新仍由系统、用户设置和 OEM 决定，提升失败不会影响下载或普通通知。
- 平台边界保持不变：Dart 侧通知抽象仅在 Android 执行原生通道，iOS、macOS、Windows、Linux 和 Web 不编译或调用 Android 实现。ColorOS 官方流体云仍需单独的 UPK/Seedling 适配，不与本次 Android 标准能力混用。
- 构建号迁移为 `YYMMDDNNN` 日期加当日构建次数格式；`build.md` 作为不可复用的正式构建台账，签名或可分发 release 构建在执行前占号，完成后回写结果，失败也保留记录。
- `2.2.10+260722001` 已使用共享 Origo 身份完成 Android 三 ABI release 构建；实际 versionCode 为 `260723001 / 260724001 / 260726001`，包名、版本和逐包签名身份均核验通过。

### WebDAV 同步设计基线

- 新增根目录 `DESIGN.md` 和 `docs/webdav-sync-design.md`，基于当前 SQLite、SharedPreferences、应用管理文件、设置页、CanonicalLocator 与历史旧同步实现，确定 WebDAV 功能的产品与技术契约。
- 新增 `docs/webdav-sync-ux-design.md`，把设置入口、首次配置四步流程、同步概览、同步范围、按书上传下载、书库云端状态、批量操作、活动队列、错误恢复、危险操作、响应式和无障碍要求细化为页面级实现规范。
- 新方案采用本地优先、每设备独立不可变变更批次、稳定 UUID / `book_uid`、Hybrid Logical Clock、tombstone 和阅读会话集合合并；明确拒绝上传整个 SQLite、共享 JSON 全量覆盖、先上传后下载、用本地 ID/路径做远端主键、进度取最大页码和统计按日取最大值。
- 首版建议同步书架元数据、CanonicalLocator 进度、书签、笔记和阅读会话；书籍原文件默认关闭并延后到第二阶段。WebDAV 密码使用现有安全存储，HTTP 默认拒绝，首版明确不承诺端到端加密、Web 平台或系统级常驻后台同步。
- 本轮只完成设计与文档，没有修改数据库、业务代码或依赖；实施前仍需确定书源注册列表、书籍文件和端到端加密的首版范围。

### WebDAV 核心同步与按书文件传输

- SQLite schema 升级到 18，新增同步记录、设备水位、本地同步状态和书籍 blob 索引表。元数据使用每设备不可变变更批次、稳定书籍身份、HLC、tombstone 和记录级 LWW 合并；阅读会话以记录并集处理，进度只同步 CanonicalLocator。
- 设置页新增“数据与同步 → WebDAV 同步”，支持连接测试、安全保存密码、自动同步、数据范围、状态与手动同步。密码只写入 `flutter_secure_storage`；默认要求 HTTPS，私网 HTTP 需用户显式开启。
- 书籍原文件默认不上传。用户开启上传权限后，在“待上传 / 可下载 / 已同步”三个分类中按书选择；文件以 SHA-256 内容寻址上传，下载后先校验大小与摘要再进入现有导入链路。书库配置后显示快捷入口。
- 当前恢复链路沿用导入器安全边界，单书限制为 100 MiB；不会因开启上传权限而自动上传全部书籍。Web/开源鸿蒙、系统常驻后台同步和端到端加密仍不在当前承诺范围。
- 新导入书籍的原文件策略改为“每次询问（默认）/ 自动上传 / 始终手动”。每次询问在导入完成后展示本次书籍列表；自动上传明确可能使用移动网络；始终手动只保留批量文件页入口。同步失败页面同时显示连接、扫描本机、读取/合并远端或上传等失败阶段。
- 当前同步 UI 和默认范围移除笔记/高亮，仅保留书签。新增稳定数据集能力目录：`notes` 远端身份与适配器代码保留，但当前标记为不支持；未来版本的远端记录只进入 `sync_records` 镜像，不会物化到当前业务表。后续上线时必须按“业务 schema 迁移 → 能力开启 → 用户范围偏好迁移”顺序升级，不改远端数据集名或记录身份。
- 针对 Android 文件在扫描途中暂时不可访问的情况，书籍身份计算改为回退到已持久化哈希或元数据身份，不再中断整轮同步；不可变远端写入同时兼容部分 WebDAV 服务对已存在路径返回 HTTP 409 的行为，会读回内容校验后再决定是否成功。
- WebDAV 与导入相关协议、安全配置、数据库迁移、数据集能力、UI 和文件传输定向 32 项测试通过，全项 `flutter analyze --no-pub` 零问题。本轮首次全量测试在并行 Toast/更新日志改动前通过 363 项；并行改动后的最新全量复跑被 `side_toast_test.dart` 自动消失断言和随后的 `changelog_page_test.dart` 进程终止阻断，均不涉及 WebDAV 代码。

### 两端对齐长段落首行缩进根因修复

- 2.2.7 真机复核确认，段首缩进字符已经进入最终 `RichText` 和 Android 辅助功能树，但 Flutter/SkParagraph 会在两端对齐且段落需要自动换行时裁掉首行的纯前导空白；因此短段落看起来正常，长段落看起来没有缩进，跨页末行又可能偶然恢复，形成不一致表现。
- Windows SkParagraph 测试曾显示 `WORD JOINER + 全角空格` 可以阻止裁剪，但 Android 真机仍会忽略零宽锚点并裁掉长段首行空白，因此不再采用该方案。`ReaderTextLayout` 现使用字形为空、Unicode 分类为宽字符而非空白的 Hangul Filler 生成 0–4 字宽视觉缩进，排版引擎不会把它当空格裁掉；中文/英文引号开头、无前导空白、一个半角空格、Tab、全角空格和其他已支持 Unicode 空白全部统一替换为用户设置值，不依赖内容首字符做例外判断。
- TXT、EPUB、HTML/HTM/XHTML、Markdown、FB2、RTF、DOCX 和在线书源继续共用这一显示投影，canonical offset、书签和进度不受生成字符影响。定向验证覆盖共享布局、书源分页/文本、TXT 分章共 35 项，包含两端对齐长段、引号段和单空格段回归；未执行本地安装包构建。

### v2.2.9 Android 官网更新安装回归

- 正式发布版本更新为 `2.2.9+18150`，取代未完成审批的 2.2.8 发布流程。修复后台下载改造后官网 APK 下载完成只发送通知、没有立即调用原生 `installApk` 的回归；现在仍先完成大小、摘要、包名、版本号和签名校验，再自动打开系统安装器，并保留完成通知重试入口。
- 本次按发布请求跳过本地测试；正式 Release 工作流仍会执行仓库既有的发布前校验、签名构建和官网镜像导入。

### 发现页大量分类改用惰性选择器

- 分类栏目不再用多行 `ChoiceChip` 一次性布局所有书源分类；主页面固定展示当前分类，点击后在移动端底部面板或桌面对话框中按书源分组选择，并支持按分类名或书源名搜索。
- 选择面板使用 `ListView.builder` 仅构建可见行，保留自动选择首分类、书源筛选和分类书籍加载行为；500 分类回归与原发现页筛选测试共 3 项通过，相关静态分析零问题。

### 全格式首行缩进与 Unicode 段落边界统一

- 修复 TXT 中 Flutter 会视觉换行、但阅读布局只识别 CR/LF 的根因：共享字符规则现同时识别 VT、FF、NEL、Unicode line separator 与 paragraph separator，并统一替换段首 NBSP、`U+2000..U+200A`、窄不换行空格、全角空格和 BOM 等源缩进，避免只有第一个视觉段落获得设置中的首行缩进。
- EPUB 的 `<br>` 现在生成明确段落边界，XHTML 源码为排版而插入的普通 CR/LF 仍折叠为空格；块解析补齐 `div/section/article/dd/dt/stanza/v/subtitle` 等正文容器，并保持嵌套块不重复。HTML/HTM/XHTML 与 FB2 改用结构化块提取，避免 DOM `.text` 把相邻段落粘连。
- Markdown、RTF、DOCX 继续先转换为 canonical 文本，再与 TXT、EPUB、HTML、FB2 和在线书源统一进入 `ReaderTextLayout → NativeTextPaginator`；PDF 与漫画使用独立渲染器，不适用文本首行缩进。
- 验证：`flutter analyze --no-pub` 零问题；共享布局、TXT 分章、书源文本与分页 33 项测试，以及本地阅读设置/分页和 TXT 标题页 10 项 widget 测试全部通过。未执行全量测试、签名构建或发布。

### 应用内更新日志改为数据驱动

- 删除 `ChangelogPage` 中逐版本构造 `_ChangelogEntry` 的硬编码清单，以及四语 ARB/生成文件中的版本专属 `changelog2xx*` getter；页面改为通过 `ChangelogService` 异步读取 `assets/changelog/changelog.json`。
- JSON schema 统一保存版本顺序与简中、繁中、英文、日文条目；第一项自动标记为当前版本，语言按完整 locale、语言代码、英文和任意可用语言回退。后续发布只需追加数据项，不再修改 Dart 页面或逐条扩写 widget 测试。
- 页面增加加载态、失败态和重试操作；测试改为读取同一资产并动态验证首尾条目、四语版本集合和非空内容，不再知道任何真实版本号。定向 5 项测试通过，`flutter analyze` 零问题。

### v2.2.6 正式发布源

- 正式版本更新为 `2.2.6+14137`，补齐 CHANGELOG、GitHub Release Notes 与应用内简中、繁中、英文、日文版本历史。本版包含在线章节段落修复与平滑跨章、按需字体、AI 阅读设置、本地化错误提示，以及跨页面持续运行的下载任务队列和 Android 前台进度通知。
- Android 普通图标和自适应前景中的书本主体在既有安全区基础上再整体缩小 `12%`，普通图标主体宽度约从画布的 `78%` 降至 `69%`，自适应前景约从 `55%` 降至 `49%`；图案、渐变和其他平台图标不变。
- 发布前验证：Flutter 全量 `318` 项测试通过，`flutter analyze` 零问题，`dart format` 检查通过，Web release 构建成功；官网后端 `90` 项测试、Ruff、compileall、`uv lock --check`、GitHub Actions 工作流检查与部署脚本语法检查全部通过。
- GitHub `release` Environment 已确认有 required reviewer，九个发布 Secrets 齐全，仓库级 Android 签名 Secrets 不存在；发布继续由受保护的 `v2.2.6` Tag 触发，不手工创建或覆盖 Release 资产。

## 2026-07-21

### 跨平台书籍下载队列与 Android 后台通知

- 在线书源“下载到本地”不再把下载生命周期绑定在阻塞弹窗上：`DownloadTaskController` 以单书任务队列串行运行下载，单书内部仍沿用原有最多三章并发。书源列表和在线书架下载入口共享同一队列；弹窗新增“后台继续下载”，书库桌面/移动顶部新增下载任务入口，任务页显示排队、章节进度、完成和失败状态。
- Android 新增无第三方依赖的 `DownloadForegroundService` 与 MethodChannel 桥：首次下载请求 Android 13+ 通知权限，活跃书籍和官网 APK 下载显示实时进度并以 `dataSync` 前台服务提高应用切后台后的存活优先级。权限被拒绝或通知桥失败不会取消下载。
- Android 完成通知可点击：本地书籍按数据库 ID 打开阅读器，已校验 APK 按缓存路径与预期 build number 重新进入现有签名/版本验证安装桥。iOS 不下载或安装 APK，更新仍跳转官网/GitHub；书籍任务继续可从应用内任务页查看。
- 验证：新增队列串行与进度保留回归；定向 Dart 静态分析通过。Android 原生编译/真机通知仍待完整 Android SDK 可用后执行。

### 书源章节文本适配器改用内容探测分路径

- 修复在线书源首行缩进失效：`readableBookSourceChapterText` 之前按 `BookSourceChapterContent.contentType` 分纯文本/HTML 两条路径，但书源声明不可靠——纯文本常被声明为 `text/html`，HTML 也偶尔声明为 `text/plain`。HTML 路径的 `flush()` 会折叠所有空白（含换行），导致无块标签的纯文本被合并成单段，共享布局层只在首行生成缩进，后续段落全部失去段落边界信号。
- 改为内容探测：用正则 `</?[a-z][a-z0-9]*` 探测内容是否含 HTML 标签起始，有则走 HTML 提取路径（保持 `walk+flush` 与段内 `\s+` 折叠的 HTML 正确语义），无则走纯文本路径（换行即段落分隔）。顺带修掉反向 bug：声明 `text/plain` 但实际含 HTML 标签的源此前会把 `<p>` 当字面文本吐出。
- 重构同时清理结构：两条路径都输出 `List<String>`，`removeRepeatedSourcePageMarkers` 与 `_removeRepeatedLeadingChapterTitle` 提到主流程统一调用；`_extractPlainTextParagraphs` 与 `_extractHtmlParagraphs` 各自为纯函数。
- `contentType` 协议字段未删——仍被 `book_source_reader_page.dart` 的 `CanonicalLocator` 与磁盘缓存序列化使用，只是不再驱动解析路径。
- 验证：`book_source_chapter_text_test.dart` 7 项全过（含两条新增回归用例：纯文本标 `text/html`、HTML 标 `text/plain`）；`flutter analyze` 零问题。工作树中其他无关模块（`font_catalog_helper.dart` 的 `digit-separators` 实验、`online_font_service_io.dart` 的类型错误）阻止了跨文件测试运行，但与本次重构无关。

### 国际化收尾与 v2.2.6 签名包

- 接手另一 AI 中途中断的国际化任务：ARB key 和四语种生成文件已全部就绪，但 `settings_page.dart` 的 AI 快捷模型卡片/配置弹窗还有十几处硬编码中文和英文字符串未接回已存在的 `l10n.settingsAi*` key（如 API Key 状态文案、Base URL/Temperature 标签等）；其余文件里的中文字符串（AI 提示词模板、分词停用词表、书籍元数据正则等）确认属于非 UI 文本，未改动。全项目 `flutter analyze` 零 error、315 项测试全过。
- 版本升级为 `2.2.6+14135`。首次构建误用不带 `--split-per-abi` 的普通 `flutter build apk --release`，产出 85MB 单一通用包；体积异常是因为遗漏了官方发布一直使用的三 ABI 分包方式，并非在线字体改造无效。改用 `--split-per-abi` 后 arm64-v8a 降到 32.6MB，符合字体资源改为运行时下载后的预期体积。
- 首次构建 versionCode 与真机实际情况不符：仓库 `pubspec.yaml`/CHANGELOG 记录的 2.2.5 基础构建号是 `14134`，但真机上通过分包安装的 arm64-v8a 实际 versionCode 是 `14134+2000=16134`（Flutter split-per-abi 会给每个 ABI 加上固定偏移：armeabi-v7a +1000、arm64-v8a +2000、x86_64 +4000）。改用分包后基础构建号 `14135` 对应的 arm64-v8a versionCode 为 `16135`，仍高于机上已装的 `16134`，可以正常覆盖升级。
- 使用共享 Origo 配置（`/Users/xiaoyuan/certs/shared/origo/origo.p12`，alias `open-reading`）完成三 ABI split release 构建：armeabi-v7a/arm64-v8a/x86_64 versionCode 分别为 `15135`/`16135`/`18135`，均通过 `apksigner verify --verbose`（v2 scheme）。arm64-v8a 产物 SHA-256：`DCB6CAA31297405A67E5714ECCF1E311AA821D50310E83AE9D6F6FEF25BE98FE`。本轮只完成本地签名打包，未创建提交、Tag、GitHub Release 或官网镜像。
- 已在 `/Users/xiaoyuan/certs/CLAUDE.md` 记录 open-reading 项目对应哪个 keystore/alias，避免下次又要重新翻找证书目录。

## 2026-07-20

### iOS 阅读状态栏遵循顶部样式

- 修复 iOS 选择“阅读信息栏”或“完全沉浸”后系统状态栏仍常驻的问题：`ReaderFlutterViewController` 现在随 reader UI bridge 覆盖 `prefersStatusBarHidden`，并在状态切换时请求控制器刷新状态栏、Home Indicator 和系统手势边缘。
- `UIViewControllerBasedStatusBarAppearance` 改为启用，移除已废弃的应用级 `UIApplication.statusBarStyle` 写入；“系统状态栏”继续显示 iOS 状态栏，退出阅读页恢复普通 edge-to-edge。Windows 无法执行 iOS 原生构建，本轮通过 8 项系统 UI 映射测试和全项目静态分析验证，仍需在 macOS/iPhone 上做最终原生行为确认。

### v2.2.5 Android 签名真机测试包

- 版本升级为 `2.2.5+14134`，同步更新正式 CHANGELOG、应用内中英日繁版本历史与 `.github/release-notes/v2.2.5.md`；本次只生成真机测试包，未创建提交、Tag、GitHub Release 或官网镜像。
- 使用 Windows 共享 Origo keystore 完成三 ABI split release 构建；armeabi-v7a、arm64-v8a、x86_64 实际 versionCode 分别为 `15134`、`16134`、`18134`，三份 APK 的包名均为 `com.niki.xxread`、versionName 均为 `2.2.5`，全部通过 `apksigner --verbose`，证书 SHA-256 与 keystore 导出的 DER 证书一致。
- arm64-v8a APK 已通过无线 ADB 保留数据覆盖安装到 PKT110（Android 16），从原 `2.2.3 (14132)` 升级为 `2.2.5 (16134)`；设备进程、当前焦点窗口和顶层 Activity 均确认 `com.niki.xxread/.MainActivity` 正常运行。
- 首轮真机检查发现部分在线 TXT 的正文首行重复携带章节标题，在独占标题页之后再次显示。`BookSourceChapterText` 现仅在正文开头与章节接口标题或目录标题规范化后完全相同时剥离首行/首段，并保留正文后续出现的同名文字；最终签名包重新构建、三 ABI 重新验签，arm64 包覆盖安装并冷启动成功。
- 真机检查后进一步收窄手机首页悬浮导航：屏幕总侧边留白由 `20` 调整为 `36`，单项期望宽度由 `96` 调整为 `90`，保持高度、图标、标签、阴影和点击区域不变；三 ABI 签名包再次重建验签，最终 arm64 APK SHA-256 为 `C07A9DCB7E6479A6ABE5AF7F09C2DAE486211551D4F5EBA14909BE4A957C3E6F`，已覆盖安装并在 PKT110 前台运行。
- 最终代码格式检查无变更、全项目静态分析无问题，单并发全量 307 项测试通过。
- 首次构建暴露 runbook 与实际签名文档格式不一致：文档四行带 `密码：` / `Alias：` 标签且路径整行带引号。已修正外部 Windows release runbook，要求前三行取首个半角/全角冒号后的值、路径整行去引号，并先用 `keytool` 验证。
- 构建仍提示 Gradle 8.11.1、AGP 8.9.1、Kotlin 2.2.0 将在后续 Flutter 版本停止支持；本轮不扩大范围升级工具链，作为后续维护风险保留。

### 在线书源水平跨章动画完整提交

- 复核既有跨章优化后确认，下一章内容预取、分页布局预热和进度后台持久化均已生效，但 `horizontalSlide` 仍在 `PageView.onPageChanged` 动画过半时立即切换章节并重建整个 `PageView`，会中断余下横滑并形成明显顿挫。
- 水平跨章现在先用已预取的真实目标页完成当前 `PageView` 动画，只记录待提交章节；收到 `ScrollEnd` 且控制器确认停在对应边界页后，才在事件队列下一轮应用章节状态。用户滑到一半退回正文页时会清除待提交状态，不触发误切章。
- 新增水平滑动专项回归，验证动画中段仍保持原章节 `PageView`，动画收尾后才切换到已预取章节，并且不等待被阻塞的阅读进度写入；全项目静态分析无问题，书源阅读器/四种翻页模式/相邻章节预览 33 项定向测试通过，最终随 v2.2.5 签名包完成单并发全量 307 项测试。

### 本地与在线文字阅读内核统一

- 新增共享 `ReaderTextPage` 模型与 `paginateReaderText` 唯一分页入口；本地 TXT/EPUB 文本段和在线书源章节统一经过 `ReaderTextLayout → NativeTextPaginator`，书源原有包装层只保留兼容 API，不再拆分首页与续页执行第二套分页流程。
- 新增 `ReaderTextPageContent` 作为两类阅读器的最终文字绘制组件，分页测量和页面渲染共同使用同一 `NativeTextFlowStyle`、`RichText` 参数与 760px 单 leaf 内容宽度上限，避免桌面宽屏、首行缩进、段间距或字体设置产生来源相关换行。
- 在线章节标题改为与已识别 TXT 相同的独占标题页，正文第一页恢复完整可用高度；平板短章节自然排成“左标题、右正文”，不再用标题内嵌首页或人为右侧空白表达章节结构。
- 书源 HTML/纯文本规范化抽到 `BookSourceChapterText` 适配器：保留纯文本段落和既有缩进，只规范换行并清理重复远端页码；HTML 只负责提取 canonical 段落，禁止预先注入两个全角空格，所有视觉缩进和段间距由共享布局层生成。
- 全项目静态分析无问题；最终随 v2.2.5 签名包完成单并发全量 307 项测试，覆盖书源 canonical 文本、统一分页、TXT/在线章节标题页与重复标题剥离、布局 offset、四种书源翻页模式、相邻章节预览、平板双页预取和进度恢复。

### 跨平台应用图标统一

- iOS 以 `ios/Runner/AppIcon.icon` 的 Icon Composer 分层工程为设计源，同时保留无 Alpha 的 Asset Catalog 旧系统回退；Android 使用同一设计导出的白底普通图标和安全区内透明前景，Windows 使用多尺寸 ICO，Linux 从 Flutter 资源包加载透明桌面图标。
- 使用仓库固定的 Flutter 3.44.4 和 Xcode 27 完成 iOS Profile 签名构建，并安装到无线连接的 SloanePro；设备锁定阻止了命令行再次启动，但设备应用清单已确认 `com.niki.xxread` 版本 `2.2.4 (14133)`。

### v2.2.4 与 ORSP 1.3 同步

- App 版本升级为 `2.2.4+14133`；App 自身版本与其支持的书源协议版本分开维护，当前书源协议为 ORSP `1.3`。
- ORSP 1.3 章节目录分页已覆盖协议常量、客户端、持久化模型、内置规范、OpenAPI、示例发现文档、参考服务器、README、项目结构说明和应用内协议说明；客户端按书源声明的 `maxCatalogPageSize` 请求并兼容旧式未分页响应。
- 本版本同时包含书源 HTML `<br>` 段落边界修复和手机首页悬浮导航高度调整。当前仅完成版本与发布资料准备，尚未执行签名构建、Tag、GitHub Release 或官网镜像。

### 官网拆分为独立仓库

- 官网、发行 API、安装包镜像、下载统计、后台和生产部署代码从 `server/open-reading-web/` 拆分到独立目录 `F:\Work\open-reading-web` 与公开仓库 `miloquinn/open-reading-web`；独立仓库拥有自己的锁定依赖、CI、部署约束和 90 项测试。
- 客户端仓库移除官网源码及官网验证 job；Release 继续通过受控 SSH 镜像安装包，并使用 `tool/official_site/verify_official_download.py` 核验官网 arm64 APK，避免客户端发布流程依赖官网仓库工作树。
- 独立官网仓库 Ruff、Pytest 和 Actionlint 通过；客户端 PR/Release 工作流 Actionlint 通过。App Store 原始截图仍保留在客户端 `marketing/app-store/`，官网 WebP 由独立仓库维护。

## 维护时机

- 完成一个影响多个模块的重要功能。
- 改变核心架构、数据结构、目录边界或兼容策略。
- 完成版本构建、真机验证或重要发布准备。
- 发现会影响后续工作的风险、限制或操作规则。

## 2026-07-19

### 宣传素材归档与官网缓存兼容

- 新增 `marketing/app-store/`，归档六张 1216×2640 精选原始截图、六张 1242×2688 App Store 宣传图及预览；官网 WebP 继续保留在服务静态目录，应用图标继续使用运行时资源目录的正式版本。
- 官网首页样式 URL 增加版本参数，避免浏览器缓存旧 `home-blue.css` 时把新版第三张首屏截图按原始尺寸渲染；公共路由测试固定检查版本化 CSS 和六张最新截图引用。

### v2.2.1 平板纸背修复签名包

- 版本升级为 `2.2.1+12120`，正式 CHANGELOG、四语种应用内更新历史和 `.github/release-notes/v2.2.1.md` 已记录平板双页仿真翻页独立纸背修复。
- 使用仓库外共享 Origo 配置完成 Android 三 ABI split release 构建；armeabi-v7a、arm64-v8a、x86_64 实际版本码分别为 `13120`、`14120`、`16120`，三份 APK 均通过 `apksigner --verbose`，证书 SHA-256 身份与配置 keystore 一致。
- 产物整理到 `release-assets/` 并生成 `SHA256SUMS.txt`。本轮只完成本地签名打包，未创建提交、Tag、GitHub Release 或官网镜像。
- 修复代码完成单并发全量 295 项测试与全项目静态分析；版本历史改动另通过定向页面测试，最终分析无 warning/error。

### 官网首页最新真实截图更新

- 官网首页移除旧的三张产品图，改用最新首页、书库、正文、仿真翻页、个性化和统计六组应用截图；首屏以三张真实界面层叠展示，内容区改为完整截图画廊，不再使用过期或虚构 UI。
- 六张网页素材从原始 1216×2640 截图压缩为 760×1650 WebP，总体积约 450 KiB；桌面端使用三列错落布局，手机端使用可横向滑动的截图卡片，并保留减少动态效果适配。
- 官网服务 Ruff 检查通过，91 项 Pytest 全部通过；Chrome 以 1440px 桌面和 390px 手机视口完成实际渲染检查，首屏、截图画廊与响应式布局均可用。
- 官网代码已原子部署到生产发布目录 `20260719T154822Z`；远端 systemd、数据库、存储和本机健康接口正常，公网首页已包含六张 `*-latest.webp`，旧图片引用消失，静态资源返回 `200 image/webp`。

### ORSP 1.2 权利透明度与投诉闭环

- ORSP 从 1.1 升级到 1.2，发现文档新增可选的 `operatorName`、`contactUrl`、`contentLicense` 和 `rightsStatement`；客户端模型与本地注册表完整保存这些字段，仍保持对所有 `1.x` 书源的兼容。
- 新增书源门禁强化为明确禁止绕过登录、付费、DRM 或其他访问控制；书源管理页可查看运营者和权利信息、联系运营者，并明确提示这些内容属于第三方自我声明，Open Reading 不核验、不推荐、不背书。
- README、内置协议副本、OpenAPI、示例发现文档、参考服务器与 `SOURCE_POLICY.md` 已同步；仓库新增专用 rights-report Issue 表单，应用书源管理页提供直达入口。项目控制材料由维护者处理，独立第三方书源内容仍优先向其运营者或托管方投诉。

### v2.2.0 发布准备

- 版本升级为 `2.2.0+12119`；正式 CHANGELOG、四语种应用内版本历史和 `.github/release-notes/v2.2.0.md` 已覆盖自公开 `v2.0.1` 以来的平板双页、仿真翻页、阅读性能、页面目录重构、界面个性化、双更新源、官网分发统计、第三方书源责任与项目支持变化。
- 发布质量门通过：锁定依赖可恢复，224 个 Dart 文件格式一致，全量 284 项测试通过；静态分析仅保留 3 条既有 `cacheExtent` 弃用提示。
- 使用仓库外共享 Origo 配置完成 Android 三 ABI release 预构建；armeabi-v7a、arm64-v8a、x86_64 版本码分别为 `13119`、`14119`、`16119`，三份 APK 均通过 `apksigner` 且证书身份与配置一致。
- 客户端官网更新仅接受精确 ABI 与 `open.xxread.top` HTTPS 同域下载，APK 元数据和实际响应均受 512 MiB 硬上限约束；下载过程中一旦超过声明大小立即取消，完成后继续校验 SHA-256，原生安装桥再核对包名、版本码和当前已安装签名。相关更新检查、恶意元数据、大小边界与提示状态定向测试 13 项通过，相关静态分析无问题，Android Kotlin 编译成功。
- Web release 已验证更新下载服务使用条件导出，不会把 `dart:io` 带入 Web；整体 Web 构建仍被既有 `book_source_chapter_cache.dart` 两个 JavaScript 无法精确表示的 64 位整数字面量阻断，当前继续作为提示性检查。
- 发布文档收尾同步补齐页面目录重构、双更新源、官网统计和供应链校验；四语 ARB 已重新生成，应用内版本历史页面测试、定向静态分析、本地化 JSON 解析与差异检查通过。

### 官网发行镜像安全收口

- 官网导入器改为联网核对固定 GitHub 仓库/tag、草稿与 prerelease 状态，以及正式 Release 中 5 个安装包加 `SHA256SUMS.txt` 的精确资产集合、状态、大小、下载地址与可用 digest；镜像 job 发布后生成的本地 manifest 另与 GitHub API 的 URL、发布时间、更新日志、五类资产映射和版本化命名交叉校验，网络失败或 staging 不一致时拒绝导入。Android APK 强制使用 `aapt` 核对包名、versionName/versionCode，并用 `apksigner` 核对完整签名及配置证书 SHA-256，工具或证书缺失不能绕过。
- stable latest 在仓储事务内按平台/架构强制单调，曾记录更高版本后即使其已下架也不能重新激活低版本；官网累计下载改为全表聚合。运维备份删除下载事件、OAuth state、后台会话，并清空审计 IP/User-Agent；Uvicorn 关闭重复访问日志，Caddy 明细仍按 30 天轮转。
- 元数据与下载短链的滑动窗口限流改为线程安全的原子检查/记账；周期清理过期空桶，活跃 key 最多保留 8192 个并按 LRU 淘汰，避免分布式或高基数 IPv6 来源持续撑大进程内存。新增 10,000 个 IPv6 key 与 200 路并发争抢回归。
- 官网生产部署依赖改为固定 `uv 0.11.8` 消费仓库 `uv.lock`：远端先 `uv lock --check`，再以 `uv sync --frozen --no-dev --python python3.12` 创建环境；不再通过普通 pip 动态解析。uv 缺失、版本漂移或锁文件不一致都会在切换 `current` 前终止部署。
- 发布工作流在 GitHub Release 资产完成后二次核对完整集合和 SHA-256，再读取 split APK 实际版本码并通过固定 `known_hosts` 调用受控导入；Android 签名与官网镜像任务共同受 GitHub `release` Environment 保护，生产 SSH 与签名材料不进入仓库或日志。

### 欢迎页后的首次首页卷纸支持引导

- 新用户完成欢迎协议后，首页主壳会尝试领取一次性支持引导：透明宋体纸张从顶部卷轴向下展开，完成后做轻微悬浮，背景仅柔和压暗和模糊；系统启用减少动态效果时直接显示完成态。展示资格使用 `first_home_support_intro_seen_v1` 持久化，避免重复打扰。
- 浮层提供“立即支持”和“再说吧”。前者在手机 PageView 与宽屏 NavigationRail 两种导航结构下都能切换到设置页，再通过 `SettingsPageController` 滚动定位“支持开发”卡片；后者直接关闭。纸张资源保存为 `assets/images/cyber_begging_paper.png`，保持正视平面与透明背景，运行时单独绘制阴影。
- 实现已适配整理后的 `pages/home/`、`pages/settings/`、`pages/legal/` 目录。新增一次性状态、控制器通知、动画操作和减少动态效果回归；本功能 4 项测试、欢迎页/捐赠卡/应用 smoke 共 4 项测试通过，相关文件静态分析无问题；全项目分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### 平板双页布局开关与顶部信息拆分

- 阅读设置新增仅平板可见的“双页布局”开关，手机不渲染该选项；偏好默认开启并通过 `reader_tablet_two_page_enabled` 供本地与书源阅读器共享持久化。只有最短边至少 600、横屏且宽度至少 720 的视口才进入 spread，关闭后回退单页并分别按文本锚点/offset 恢复位置，书源侧同时失效分页缓存。
- 双页顶部信息按 leaf 分工：左页左上只显示章节标题，右页右上只显示时间和电量；空白、补位和章节边界 leaf 保留对应角色但不显示虚假页码。下一页/上一页的跨书脊活动层级继续由 `ReaderPageCurlSpread` 动态控制。
- 验证：页面迁移与阅读器定向套件 128 项通过；全量测试 284 项通过；全项目静态分析仅保留 3 条既有 `cacheExtent` 弃用提示，无新增 warning/error。

### 页面目录按功能域重构

- `lib/pages` 从平铺结构归档为 `home`、`library`、`book_sources`、`reader`、`reading_stats`、`settings` 和 `legal` 七个功能域；controller、widgets、themes、about 与私有 `parts/` 就近归档，跨域引用统一改为 `package:xxread/pages/...`。
- 文件名统一遵循页面 `*_page.dart`、控制器 `*_controller.dart`、多组件 `*_widgets.dart`、私有拆分 `*_part.dart`。关键迁移包括 `source_search_page.dart`、`sourced_book_widgets.dart`、`home_mobile_chrome.dart` 和 `home_mobile_top_bar.dart`；公开页面类/API 未做无关扩大重命名。
- 搜索页原有两个真实 NUL 分隔符改为等价 Dart 转义 `\u0000`，避免 Git 将源码误判为二进制；搜索分页去重语义不变，相关测试已覆盖。

### 平板双页仿真翻页跨书脊层级修复

- 根因不只是固定 `Row` 的绘制顺序：经典折页原先只在单个半页矩形内绘制，因此右页 forward 即使位于上层也无法跨书脊；left leaf 的 backward 还会被固定后绘制的右页压住。
- 新增共享 `ReaderPageCurlSpread`：左右 leaf 用带稳定 key 的固定 `Positioned` 保持物理位置，coordinator 单独发布当前活动装订边，下一页把右 leaf 放到最后绘制，上一页把左 leaf 放到最后绘制。协调中的经典 shader 同时放开内部裁剪并把绘制边界扩展到对侧 leaf；本地文件与在线书源阅读器均接入同一实现，手机单页路径不变。
- 新增双向活动层级与重排后手势连续性回归，并扩展两条真实平板阅读器测试确认共享 compositor、24px 中缝和右页外缘 forward。上述 4 项定向测试与 page-curl 全套 24 项均通过；全项目静态分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### 平板双页仿真翻页独立纸背

- 修复双页右页向左翻时把当前右页镜像当作纸背的问题。折页公共组件新增可选 `outgoingBackPage`，把活动纸张正面、纸张背面和翻页后的实时底页分离：8/9 向前翻时依次使用 9、10、11；向后翻时左 leaf 的纸背使用上一 spread 右页。本地文件与在线书源阅读器均按相同规则接线，手机单页不传纸背并保持原有镜像 source 行为。
- 经典折页 shader 新增第二张 sampler；折叠区域先执行既有纸张反射，再对独立背页纹理补一次 X 反转，因此无论装订边在左或在右，背页落到书脊另一侧后都保持正常阅读方向。纸背快照纳入预热、缓存保护和 provisional 原子替换；在线书源跨章的左右 boundary/blank slot 使用不同 identity，避免不同页眉与页码布局共用缓存。
- 新增非对称绿/品红纹理的像素级 shader 回归，直接验证左右两种装订边的 sampler 与方向；同时扩展本地、书源、同章与跨章测试，确认当前右页 N、纸背 N+1、底页 N+2，以及反向纸背/奇数页空白映射。
- 验证：page-curl、本地阅读器和书源阅读器三组定向回归共 48 项通过；单并发全量 295 项测试通过；全项目静态分析无 warning/error。

### 本地 TXT 打开转场与阅读器初始化隔离

- 真机帧数据确认本地 TXT 打开卡顿来自 UI/CPU 初始化尖峰，而非 GPU：封面转场仍在运行时，阅读器会并发完成 TXT 缓存恢复、当前与相邻章节同步分页、Android 系统栏重排，以及仿真翻页整页快照抓取。
- `BookOpenTransition` 现在在封面飞行期间只挂载轻量纸色占位，等 460ms 路由动画完整结束后的下一帧才创建目标阅读页；退出时保留已创建的阅读页，不影响反向缩回封面的既有路径。本地阅读器的无封面入口同样等待所属路由落定后再初始化章节依赖并应用系统 UI，避免同步分页或窗口 inset 变化进入转场帧预算。
- 新增封面飞行期间阅读页不挂载、TXT 初始化延后，以及 page-curl 快照准备不早于路由落定的回归覆盖。相关文件定向静态分析无问题；书籍打开转场、TXT 标题页与 page-curl 定向套件通过。仓库既有的平板右页边缘拖拽断言仍可能返回 `debugMotion == null`，已在同日日志单独记录，与本次打开转场隔离无关。

### 在线书源跨章翻页预取与分页复用

- 相邻章节预取改为逐章独立完成并立即进入会话缓存，不再等待前一章或后两章等其他并发请求全部结束；较远章节响应慢时，下一章仍可先生成真实预览页。
- 跨章前的阅读进度按章节、页码和书架状态生成不可变快照，按调用顺序在后台串行持久化；已预取章节可以立即提交，不再让 SharedPreferences/数据库写入阻塞翻页动画收尾。
- 分页模式为相邻章节维护有界布局缓存，并在当前视口稳定后提前生成下一章分页；横滑、无动画和仿真翻页在切章时复用同一份分页结果，避免预览和正式进入各做一次同步排版。
- 验证：相关文件静态分析无问题；新增“较远章节预取未完成也能显示下一章”和“进度写入未完成也能提交切章”两项回归均通过。三组在线书源阅读器定向套件共 30 项通过；另有 1 项当前本地 `d01182d` page-curl 状态机范围内的平板右页边缘拖拽旧断言仍返回 `debugMotion == null`，需在该手势链路单独处理。

### 主页悬浮导航文字双模式与选中态扩容

- 设置页“外观设置”新增“隐藏底部导航文字”开关，偏好由 `AppSettingsNotifier` 通过 `hide_home_navigation_labels_v1` 持久化，默认保持纯图标模式；切换后 `HomeShellPage` 通过 Provider 即时更新手机底部悬浮导航，宽屏 `NavigationRail` 不受影响。
- `HomeBounceNavigationItem` 共用一套选中、取消选中和按压状态机，在纯图标与“图标＋文字”之间执行 220ms 淡入/位移动画；文字隐藏后仍保留 Semantics 与 Tooltip。按参考界面比例，手机栏改为左右约 10px、最大 392px 的近满宽药丸，垂直内边距降为 4px；选中底板占单项槽宽约 86%–92%，纯图标高 54px、显示文字高 56px，并使用主题强调色浅染、27px 图标和 12.5px 粗体标签。外层阴影移到裁剪层之外，保持可见的悬浮层次。
- 新增导航文字默认值、恢复和持久化测试，扩展导航组件测试覆盖双模式切换、选中底板尺寸/填充动画、双向图标动画、按压反馈、高对比标签、窄屏长文字和真实手机宽度计算。相关 13 项定向测试与应用 smoke test 通过；改动文件静态分析无问题，全项目分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### 官方零预装书源与双重责任确认

- 明确产品边界：官方发行版不预装、不内置、不推荐任何第三方书源，也不运营官方书源目录；`BookSourceRegistry` 首次安装为空，书源 URL 只能由用户在本机主动输入，网络请求直接发送给所选独立服务。
- 首次欢迎页新增醒目的第三方书源边界说明，并把同意流程拆成“使用条款/隐私”和“第三方书源责任”两个必选确认；条款版本升级为 `2026-07-19.1`，已有用户下次启动需要重新确认。新增书源弹窗也必须单独确认有权访问和使用相关内容后才能连接。
- 新增 `SOURCE_POLICY.md`，说明独立书源运营者和用户的责任、官方项目可控制材料的权利报告渠道，以及 ORSP 兼容不代表内容合法或已获授权。欢迎页、协议持久化和书源添加门禁均补充组件回归。

### 仿真翻页按二进制证据重做 backward 与平板书脊

- 手机 backward 从“forward 几何连同书脊一起水平镜像”改为独立 incoming 通道：previous 作为展开 source、current 作为实时 underlay，forward/backward 各持有独立双轴 spring channel；方向只决定页源、完成目标和回调，物理装订边只由 leaf 的 `bindingEdge` 决定。
- 经典折页 shader 改为恢复稿的 `size + posA + posB + image` 控制流：顶/底交点执行 `max(0,x)`、装订侧整片保持 source identity 采样、curl polygon 只向自由边生成。手机前后翻都固定左装订；平板左 leaf 仅因物理中缝在右而做 canonical 坐标与 source UV 的成对镜像。
- backward 折线按起手后的位移逐帧驱动，起手高度固定参与对角斜率，移除会把折痕锁成竖线的 `followPointerEdge`。活动 source 冷缓存时先使用 `RepaintBoundary.toImageSync()` 临时纹理保证首帧跟手，图片准备完成后异步重抓并安全替换；提交时 X/Y 双轴都归位并吸附到精确 shader 端点，跨章回调等待期间不再冻结装订侧楔形或阴影缝。
- 中部 forward 识别方向后从右自由边的精确竖直折线立即启动 120ms 追手；前 55% 只推进 X，避免右缘近退化 curl 被细小 Y 抖动旋成异常薄片，随后再平滑接入真实 Y。提交弹簧进入端点最后 2–8 logical pixels 时提前量化到精确竖直 pose，避免 shader 在收尾前多画一两帧塌缩背面。
- 本地文件与在线书源的平板 page-curl 都使用 24px 固定中缝和两张半页 leaf：左外缘 backward / 右装订，右外缘 forward / 左装订，音量键、点击和提交按两页步进；左右 controller 通过共享 coordinator 串行提交。native 奇数页章节补空白右页以固定 spread 奇偶，并按文本 anchor 处理尺寸重排；在线书源跨章优先复用已预取内容生成真实目标 leaf，双页进度按最后可见页保存。该阶段仍是两个裁剪在各自半屏内的 leaf 动画；本日后续已由“平板双页仿真翻页跨书脊层级修复”升级为活动 leaf 跨中缝合成。
- 验证：最新 page-curl/几何定向回归 28 项通过，相关静态分析无 warning/error；全量测试当前仅有 2 项由并行中的书源责任提示/协议页面改动引起的无关失败。arm64 split release 已构建为 `2.0.4 / 14114`，逐摘要匹配共享 Origo 签名身份并覆盖安装到 Android 16 PKT110；`firstInstallTime` 保持 `2026-07-18 01:52:02`，`MainActivity` 获得焦点、进程存活且无 fatal 日志。用户真机确认中部向左起手闪跳问题已解决。

### 仿真翻页真实指针跟手、收尾与模块拆分

- Blutter 函数级证据确认旧版手势累计位移超过 18px 才激活，并把当时位置作为 activation point；激活后 `startEdgeUpdate` 每帧直接使用当前手指 X/Y 生成折线，不存在一次判定后永久锁定 horizontal/diagonal 的状态。当前 backward 已同步这套语义：水平起手会自然保持平卷，滑到一半再上下拉会立即连续转为斜卷。
- backward 松手不再读取 `DragEndDetails.velocity` 或做速度投影，只比较最终屏幕 X 是否越过 activation X；incoming 的提交与取消都以 X spring 为视觉主通道，并在前 84% 剩余横向行程内用 smoothstep 拉平 Y。到达自由边或装订边后持续保持精确竖直 shader 端点，避免右下角甩尾、停顿后突然合页以及终点后一两帧阴影复现。
- 修正边缘起手误用中部 120ms 自由边追赶：只有屏幕中部识别出的 outgoing 才追赶，手机下一页真实右边缘和平板左 leaf 真实外缘均直接逐帧跟手。`reader_shader_page_curl.dart` 从 1600 余行单体入口拆为稳定公共入口，以及 `widgets/src/page_curl/` 下的 API、状态机、快照缓存、绘制、收尾物理和内部类型模块，外部 import/API 不变。
- 高刷新率专项核验无需代码变更：Android 启动路径已请求同分辨率最高 display mode，PKT110 窗口为 `preferredDisplayMode=1`（1216×2640@120Hz），系统无应用级限帧；静止时动态降至 60/90Hz 属于系统策略，Flutter Surface 交互样本帧间隔中位数约 8.39ms。旧 Lightink 没有额外高刷申请，其顺滑差异来自手势几何和收尾轨迹。
- 验证：page-curl/几何定向回归 32 项通过，相关静态分析无问题。按用户要求使用完整当前工作区构建 arm64 split release `2.0.4 / 14117`，APK 与共享 Origo 密钥库证书 SHA-256 身份一致；已从 `14116` 覆盖安装到 PKT110，`firstInstallTime` 保持 `2026-07-19 15:19:11`，进程和 `MainActivity` 正常且启动日志无 fatal。

### v2.0.3 开发者产品推广与自愿捐赠真机包

- 应用版本升级为 `2.0.3+12113`；设置页新增“小元读书”“小元读书社区”推广卡和“支持开发”入口，微信二维码仅在弹窗中展示。捐赠文案明确完全自愿、不影响功能且不构成购买或服务承诺；README 同步增加支持项目说明与二维码。
- 完整静态分析仅保留 3 条既有 `cacheExtent` 弃用提示，单并发全量 233 项测试通过。三套 split release APK 构建成功并通过共享 Origo 证书身份校验；arm64 包为 `2.0.3 / 14113`。
- arm64 release 已覆盖安装到 PKT110，设备从 `2.0.2 / 14112` 升级为 `2.0.3 / 14113`，`firstInstallTime` 保持 `2026-07-18 01:52:02`，应用进程与 `MainActivity` 启动成功。设备验证时处于锁屏/Dozing，已唤醒但未绕过锁屏。

### v2.0.2 阅读纸页信息修正与真机包

- 应用版本升级为 `2.0.2+12110`。无动画、横向滑动、平板双页和经典折页重新把时间、章节标题与电量嵌入每张 `ReaderPaperPageLeaf`，随纸页运动；上下翻页继续使用固定视口信息栏。本地与书源阅读器共用同一组件和快照 revision 逻辑。
- 手机单页与平板左右页的章内页码距离屏幕外侧边缘至少 24px，避免圆角遮挡；TXT 独占章节标题页保留对应章节信息。正式 CHANGELOG、四语种应用内更新记录与 `.github/release-notes/v2.0.2.md` 已同步。
- 完整静态分析仅保留 3 条既有 `cacheExtent` 弃用提示，单并发全量 233 项测试通过。三套 split release APK 构建成功，版本码为 `14110 / 13110 / 16110`，均逐包通过共享 Origo 证书身份比对；真机覆盖安装尚待 ADB 设备重新连接。
- 本地曾尝试的仿真翻页几何大改（取消镜像 / 2.0.3 试验包）已整包撤回，源码回到 `2.0.2`（`5a743fc`）状态。

### v2.0.1 发布完成

- 应用版本升级为 `2.0.1+12109`，发布范围包含多书源发现筛选与上一页经典折页跟手优化。
- 上一页快照取消 140ms 延迟并与下一页同优先级预热；中部反向拖动取消 85ms 边缘追赶，直接跟随 pointer。反向折页使用 `followPointerEdge` 隔离纵向手抖，并把物理装订边映射为 canonical 右侧边界后钳制。
- 新增 `.github/release-notes/v2.0.1.md`，同步更新正式 CHANGELOG、四语种应用内更新记录与相关回归测试。精确发布源码通过本地化差异检查和全项目格式检查；完整静态分析仅保留 3 条既有 `cacheExtent` 弃用提示，单并发全量 230 项测试通过。
- `main` 提交 `351412b` 与注释标签 `v2.0.1` 已推送。GitHub Actions 跨平台发布运行 `29666987939` 全部成功；Android 三套 split APK 的配置签名身份验证通过，Release 已发布为 latest，包含三份 APK、Windows ZIP、Linux tar.gz 和 `SHA256SUMS.txt` 共 6 个资产。

### 多书源发现筛选与均衡聚合

- 发现页在推荐、分类和最新栏目默认聚合全部可用书源；当前栏目存在多个书源时显示“全部 / 单书源”筛选，筛选直接复用栏目缓存，不重复请求。切换到分类栏目后按当前来源自动选择首个分类。
- 推荐书架、分类和书籍继续保留来源归属；最新列表不再全局硬排不同书源的时间戳，而是以各源首项新鲜度确定首轮顺序，再保持源内排序轮流穿插，并限制每源首批最多 12 本，避免单源刷屏。
- ORSP 1.1 应用内协议说明与独立协议仓库同步补充多源聚合规则：ID 均为书源作用域、跨源结果必须标注归属、部分失败保留其他成功结果、跨源时间戳只作参考。新增发现页筛选和均衡合并回归测试。

### EPUB 图片后纯文字续页恢复全高

- 修正 EPUB 图片页后的纯文字续页仍按图片页约 `6/11` 文字高度分页，导致句子中途提前翻页、下半屏长期空白的问题。`NativeTextPaginator` 现支持独立 `firstPageHeight`：只有真正携带图片的第一张页面使用缩小文字区，后续页面自动恢复完整正文高度，并继续复用同一个 `ReaderTextLayout` 投影以保持 canonical/display offset 连续。
- 使用用户提供的《学习的逻辑》和《小岛经济学》原书复现：截图句子分别位于图片偏移 `4404` 之后，以及图片偏移 `280..986` 之间，完全命中旧的半高续页路径。按 4 种手机宽度、3 种正文高度和 5 种字号逐书扫描后，截图附近非图片续页恢复到约 `92%–98%` 可见文字利用率；图片所在页保留约 `6/11` 文字区属于设计行为。
- 本地分页缓存签名升级为 `native-line-v7`。新增“图片页首屏半高、续页全高”回归；分页、段落映射和完整本地阅读页共 19 项通过，相关 5 个文件静态分析无问题。

## 2026-07-19

### v2.0.0 发布准备

- 应用版本升级为 `2.0.0+12108`；基础构建号在 `1.2.4+12106` 上增加 2，arm64 split APK 对应版本码为 `14108`。
- 新增 `.github/release-notes/v2.0.0.md`，并同步更新正式 CHANGELOG 与应用内更新记录，覆盖顶部信息三态、多自定义阅读主题与图片背景、经典折页优化、EPUB 排版/目录和 Android 阅读常亮能力。
- 发布门禁：定向静态分析无问题；全项目分析仅保留 3 条既有 `cacheExtent` 弃用提示；单并发全量 226 项测试通过。
- 使用共享 Origo 配置构建三套 split release APK，版本码为 `14108 / 13108 / 16108`，均逐包通过签名证书 SHA-256 身份比对。arm64 包成功覆盖安装到 Android 16 PKT110，`firstInstallTime` 保持不变，应用进程与 Activity 启动且无 fatal 日志；设备处于需要凭据的锁屏状态，未绕过锁屏执行可视化手势检查。

### 仿真翻页收敛为经典折页

- 删除 `ReaderPageTurnStyle`、仿真样式持久化键与阅读设置中的样式选择入口；历史 `native_reader_page_turn_style` 偏好在下次读取阅读设置时清理。
- `pageCurl` 现在固定使用经典折页。移除圆柱 shader 资产、加载分支、圆柱 painter、圆柱专用落点与相关文案/测试，保留共享快照缓存、手势追赶、真实弹簧、装订边和连续翻页队列。

## 2026-07-18

### 多自定义阅读主题与图片背景

- 原单一 `custom` 阅读主题升级为有序主题库：每套主题拥有稳定 ID、名称、字体色、纸张色、控制栏色和可选背景图片；旧 `reader_custom_theme_v1` JSON 首次读取时自动迁移为新列表，现有用户选择不会丢失。
- “自定义”入口改为主题管理页，支持新增、编辑、删除、选择和拖拽排序；自定义主题按用户顺序直接出现在阅读设置横向列表中，管理入口显示当前主题数量。编辑仍提供实时预览、色板、十六进制输入和对比度提示，并新增图片上传、替换、移除与显示强度控制。
- JPG/PNG/WebP 背景图限制为 20 MB，并复制到应用私有 `reader_theme_backgrounds/` 目录，替换或删除主题时清理旧文件。背景合成层由本地阅读器、在线书源阅读器、分页纸页快照和主题预览共享；Web 当前保持安全不支持图片导入，颜色主题和多主题管理仍可用。
- 新增主题列表持久化/旧数据迁移/图片元数据/多 ID 调色板/管理页排序回归。相关定向静态分析无问题，单并发全量 227 项测试通过；完整项目分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### 阅读页顶部信息三态与纯页码页脚

- 原“阅读时显示系统状态栏”布尔偏好升级为共享 `ReaderTopBarStyle`：系统状态栏、阅读信息栏、完全沉浸。旧值自动迁移，原开启映射为系统状态栏，原关闭或无值映射为阅读信息栏；全局设置与阅读页设置共用同一选择器和持久化键。
- 本地文件与在线书源继续保留各自的内容加载和进度适配器，但顶部样式、系统 UI 控制、安全区预留、设置面板和阅读 chrome 只实现一份并由两条入口共同消费。Android 继续只显示顶部系统栏并隐藏导航栏；iOS 同步使用既有 reader UI bridge 控制沉浸状态和 Home Indicator。
- 阅读信息栏按翻页架构落位：无动画、横向滑动和平板双页/经典折页把时间、章节标题和电量刻入每张 `ReaderPaperPageLeaf`，随纸页滑动或卷曲；上下翻页仍使用固定视口信息栏。分页模式的分钟级状态 revision 重新参与纸页快照更新，TXT 独占章节标题页也保留对应章节信息。
- 章内 `当前页 / 总页数` 同样属于纸页内容：手机与单页位于右下，平板 spread 左页位于左下、右页位于右下；外侧水平内缩至少 24px，避免屏幕圆角遮挡。三态偏好迁移、安全区、页内顶部信息、左右页码位置和设置面板均有定向覆盖；相关文件静态分析无问题，单并发全量 227 项测试通过，全项目分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### 阅读时保持屏幕常亮

- 设置页原有“保持屏幕常亮”开关已从仅保存偏好改为真实平台能力：本地阅读器与在线书源阅读器进入时按 `keepScreenOn` 偏好持有常亮状态，退出最后一个阅读页时立即释放，应用恢复前台时重新应用。
- Android 原生桥使用窗口 `FLAG_KEEP_SCREEN_ON`，无需新增权限或第三方依赖；当前平台能力边界为 Android，其他平台保持安全无操作。
- 新增持有计数、即时偏好更新和最终释放 3 项定向测试；相关静态分析无问题，Android debug APK 构建成功。构建仍只有既有 Gradle、AGP、Kotlin 未来兼容性警告。

### EPUB 段落间距归一化

- 修正 EPUB 段落间距为 `0` 时仍固定保留整行空白：解析阶段生成的双换行现在只在显示投影层归一化为“一个结构换行 + 0–2 个附加空行”，因此 `0/1/2` 分别对应无空白行、一行空白和两行空白。
- 原始 EPUB 纯文本及 canonical UTF-16 offset 不变，书签、阅读进度和高亮定位不会因压缩显示换行而累计漂移；本地分页缓存签名升级为 `native-line-v6`。
- 新增 CRLF/LF、单硬换行保留、图片后前导段落分隔、offset 单调映射和非末页可见文字密度回归；段落投影、原分页器、文字流及在线书源兼容共 28 项通过，相关独立静态分析无问题。完整阅读页联调暂被同期系统顶栏/纸页接口未同步的工作区错误阻断，本次未改动该并行功能。

### 阅读导航主题与可折叠目录树

- 修正阅读导航虽然包裹阅读主题、内部文本却继续从外层 App `BuildContext` 取色的问题；面板内容现在在阅读主题的子上下文中构建，深色 App 配白色阅读主题时标题、目录和书签文字仍使用阅读主题前景色。
- 目录项移除左侧两位章节序号，改用缩进引导线、叶节点圆点和父节点折叠箭头表达 EPUB 多级目录；折叠会隐藏整条子树，搜索会带出匹配项的完整祖先路径，“当前”按钮会先展开父链再定位。
- `reader_navigation_sheet_test.dart` 共 5 项通过，覆盖反差主题、无序号、多级折叠、当前章节回展、搜索祖先路径和原有书签交互；目录组件及测试定向静态分析无问题。全项目分析仍被同期阅读器顶栏/纸页接口未同步的既有错误阻断，本次未改动这些并行文件。

### 仿真翻页响应与收尾优化

- 中部起手的“自由边追手”只保留给 forward：从右侧在活动快照就绪后用 85ms ease-out 追到持续更新的 pointer，之后恢复直接跟手。backward 不再复用追手延迟，方向确认后立即跟 pointer；若 forward 用户在追赶结束前松手，结算仍会先同步到最新 pointer。
- 上一页跟手专项修正：移除 backward 快照 140ms 延迟，current 后 forward/backward 同优先级预热；backward 几何使用 `followPointerEdge`，折线保持竖直，连续横纵手抖不会旋转整张纸的法线；手机左装订换算为 canonical 右边界钳制。几何与仿真组件 21 项定向测试通过，相关静态分析无问题。
- 后续修正上一页动画的装订边：原实现把反向运动镜像与物理书脊镜像绑定，导致手机 backward 的装订缝落到右侧。现新增独立 `ReaderPageBindingEdge`，手机前后翻均使用左装订；平板左 leaf 显式使用右装订、右 leaf 使用左装订。圆柱与经典折页 shader 分别以方向选择 source/target 纹理、以 leaf 配置选择装订缝位置。
- 仿真翻页中央起手门槛和横向意图判定收紧，快速甩动的速度投影更积极；完成/回弹弹簧提高刚度并缩短尾部收敛，减少手势开始与松手后的前摇、后摇。
- 点击与音量键触发的程序化仿真翻页改为有界 FIFO 串行请求；前一页尚未结束时继续触发不会再被静默丢弃，音量键自动连发也不会形成无限积压。前向目标快照在当前页后立即预热，移除一次无必要的逐帧等待。
- 装订缝仍作为 shader 的物理硬边界保留，但只属于活动翻页层。提交动画现在以 X 轴纸页离场为视觉完成条件，不再等待已经不可见的 Y 轴卷角弹簧；页面切换回调返回后立即撤销旧仿真层，消除手机屏幕左侧旧页阴影短暂停留。
- `reader_shader_page_curl_test.dart` 新增快速连续两次程序化翻页回归，确认请求按顺序执行且最终到达第二张目标页；仿真/几何/本地与书源阅读器定向 33 项通过，单并发全量 202 项通过。全项目静态分析仅保留 3 条既有 `cacheExtent` 弃用提示。默认并发全量测试曾因阅读设置共享状态使 2 项水平翻页断言偏一页，两项分别复跑与单并发全量均通过，和本次仿真状态机修改无关。

### “上下翻页”预分页列表重构

- 原“上下滚动”统一重命名为“上下翻页”（简中/繁中/英文/日文同步），本地文件与在线书源不再把整章正文直接塞入长滚动视图，而是先用既有分页器生成等高页面，再交给 `ScrollablePositionedList` 竖向滑动。
- 新增共享 `ReaderViewportChromeMetrics` 和中心可见项算法：固定顶部章名、底部章/页进度参与正文可用高度计算；状态以视口中心命中的页为准，减少跨页和跨章时的抖动。
- “按章节滚动”开启时使用当前章的页级索引列表并保留左右滑动切章；关闭时使用章节级可定位列表，每章内部仍由等高页单元组成。目录点击可直接定位章节，滑动则反向更新章名、页码、目录当前项、书签上下文和持久化进度。
- 引入 `scrollable_positioned_list 0.3.8`，补充固定视口留白、中心页换算、本地阅读竖向宿主、书源目录跳转与章/页状态回归测试；全量 199 项测试通过，`flutter analyze --no-pub` 仅保留 3 条既有 `cacheExtent` 弃用提示，本次实现无新增问题。
- 后续修正 EPUB 等页面之间的大块空白：原实现把每个 item 设为整屏高并在每页重复加入固定章名/页码留白，现改为列表外层一次性 `Padding + ClipRect` 阅读窗口，item、分页、缓存、跳转与恢复统一使用窗口 `contentHeight`。正文不会再滚到固定章名和页码下方；TXT 独占章节标题页明确保留。固定窗口与标题页定向回归通过，单并发全量 204 项通过；静态分析仅保留 3 条既有 `cacheExtent` 弃用提示。arm64 release `1.2.4 (14106)` 已用共享 Origo 证书构建并逐指纹验证一致，成功覆盖安装、启动到 PKT110。
- 修正本地阅读“上下翻页”无法轻点呼出控制栏：在线书源原先把 `GestureDetector` 放在 `SelectionArea` 内部，本地阅读却只在选择层外监听，轻点会被文本选择手势先消费。新增共享 `ReaderVerticalPagingSurface`，两套阅读器统一使用内部轻点识别；回归同时确认竖向拖动不误开控制栏、中间轻点正常呼出。单并发全量 204 项通过，静态分析仍仅有 3 条既有 `cacheExtent` 弃用提示。
- 下拉书签与上下翻页的最终手势仲裁已记录在 `docs/superpowers/specs/2026-07-18-pull-bookmark-vertical-paging-interaction.md`：采用顶缘候选、语义起点和 leading overscroll 的同手势边界移交，当前仅完成设计记录，尚未接入代码。
- 当前工作树已构建 arm64 split release APK `1.2.4 (14106)`；APK 签名证书与 Windows 共享配置身份逐摘要比对一致，并成功覆盖安装、启动到 PKT110（Android 16），应用数据未清除。构建仅有 Gradle/AGP/Kotlin 未来兼容性警告。

### TXT 章节标题页与正文分离

- 新增共享 TXT 章节解析器，识别“第 X 章 / Chapter X / Part X / 序章”等标题行后，单独保存标题并让正文范围跳过标题行、标题后的空行及章末空白，解决章节标题在目录字段和正文中重复的问题。
- 识别章节携带 `isNeedSplitTitle`：分页模式在正文页前插入特殊第 0 页，使用正文主色、约 1.8 倍字号（28–34）居中并略偏上绘制标题；正文继续走 `ReaderTextLayout → NativeTextPaginator`。无章节结构 TXT 不强制生成文件名标题页。
- 小 TXT JSON 缓存与大 TXT UTF-8 偏移索引统一升级到版本 2，解析缓存键升级为 `txt-parser-v5`，分页缓存升级为 `native-line-v5`，避免旧缓存继续携带重复标题正文。
- TXT 分章、独立标题页组件和真实本地阅读页首屏共 6 项定向测试通过，覆盖中英文标题识别、标题去重、无结构 TXT 回退、字号边界、主色继承、居中布局，以及标题页为第 1/2 页且正文不混入首屏；相关文件定向静态分析无问题。

### 自定义阅读主题、下拉书签与点击动画

- 阅读主题横向列表最右侧新增“＋ 自定义”卡片，进入独立主题编辑页；用户可分别设置字体颜色、阅读背景色和控制栏颜色，通过实时纸页预览、预设色板、十六进制输入及 WCAG 正文对比度提示完成调整。自定义主题使用 SharedPreferences JSON 持久化，并由本地阅读器和在线书源阅读器共享。
- 自定义主题的派生 surface、次级文字、边框和控件填充由统一主题工厂生成；纸页快照缓存键加入实际颜色指纹，修改同一个 `custom` 主题后不会复用旧颜色快照。编辑页预览不再提前污染当前已保存主题，只有“保存并使用”后才生效。
- 阅读设置新增“下拉书签”和“点击动画”开关。下拉书签仅接受屏幕顶部区域起手、纵向占优且超过阈值的手势，松手复用现有 Bookmark DAO 增删当前页书签，并在当前页已收藏时显示页缘标记；关闭开关不影响工具栏书签入口。
- 点击动画开启时，左右点击复用当前翻页模式：水平滑动使用 280ms 横滑，仿真模式调用当前圆柱/经典折页动画，无动画模式直接切页；关闭后左右点击一律直接刷新目标页。滑动手势和音量键翻页继续使用原有策略。
- 本次功能覆盖本地文件与在线书源两个阅读器，新增简体中文、繁体中文、英文和日文文案。定向静态分析无新增问题；设置、主题、下拉手势、本地阅读和在线书源共 29 项定向测试通过。全量复查期间工作区另有 TXT 章节标题页/纵向分页并行改动：其新增标题页测试仍有 1 项失败，静态分析另报 1 条无用 import 与 1 条未引用声明；这些并行项未在本功能中改写，既有 3 条 `cacheExtent` 弃用提示仍保留。

### v1.2.4 Android 发布准备

- 版本号更新为 `1.2.4+12106`，新增 `.github/release-notes/v1.2.4.md`、正式 CHANGELOG 与应用内更新记录。
- `codex/paper-leaf-experience` 已包含当前 `main` / `origin/main`；同步检查结果为 `Already up to date`。
- Android arm64-v8a、armeabi-v7a、x86_64 release APK 已重新构建；三份产物的 `versionName` 均为 `1.2.4`，split versionCode 分别为 `14106`、`13106`、`16106`，并逐一通过 `apksigner` 与配置证书 SHA-256 身份校验。未构建其他平台。

### 纸页化阅读与双仿真翻页

- 装订边后续修正：规范坐标中的左缘作为几何硬边界，倾斜折线的顶/底交点不能越过书脊；圆柱和经典折页 shader 各自保留不参与卷曲采样的装订缝，卷轴位置也被限制在 leaf 范围内。
- 平板 `pageCurl` 改为真正的双 leaf spread：右页只从屏幕最右自由边向前翻，左页只从屏幕最左自由边向后翻，正中 24px gutter 固定且不参与抓图变换或手势命中。分页按半页宽度重新计算，点击与音量键按整组两页推进。
- 经典折页后续手感修正：不再把页面下半区的所有起手都吸附到右下角；中部起手使用连续的右侧边锚点，纯水平左滑形成竖直推进的折线，只有真实斜拉时才产生对角轨迹。
- 本地阅读器和在线书源阅读器新增完整 `ReaderPaperPageLeaf`：正文、章节名、页码、时间和电量进入同一张纸页；无动画、横滑、双页和仿真翻页复用该 leaf，分页模式不再把可见页码钉在 viewport Overlay。
- 仿真翻页保留原圆柱 shader，并新增 clean-room 经典折页 shader。两种 renderer 共用镜像手势几何、速度投影和 Flutter `SpringSimulation`；反向翻页完成态通过像素采样确认会显示上一页，经典折页终点落在对侧书脊。
- 快照缓存键由页面身份、排版指纹和主题组成，动态时间/电量使用 content revision 更新；抓图先 current，再同优先级预热 forward/backward，DPR 同时受 2.5 上限和单张 8 MiB 预算约束，LRU 使用 48 MiB 总预算并防止旧 generation 异步回填。
- 保留 `NativeTextPaginator`，新增 `ReaderTextLayout` 显示投影，为首行缩进和段落间距建立显示 boundary 到原文 UTF-16 boundary 的映射；图片页、空白段、纯空白章节和跨章预览继续保持 canonical offset 连续。
- 阅读设置新增首行缩进、段落间距和圆柱/经典折页样式，两个阅读器共享持久化键；Android/iOS 新增只读电量通道，系统状态栏偏好与页内时间电量保持独立。
- 设计、缓存约束、clean-room 边界和验收矩阵记录在 `docs/reader-paper-leaf-experience-plan.md`。
- 装订边几何、自由边手势和双页中缝专项共 16 项定向测试通过；包含同期阅读器改动的全量测试 185 项通过。全项目静态分析仅保留 3 条既有 `cacheExtent` 弃用提示，本次相关实现无新增问题。
- 验证：本次新增代码静态分析无 warning/error（全项目仅保留 3 条既有 `cacheExtent` 弃用提示）；全量测试 174 项通过；Android arm64-v8a、armeabi-v7a、x86_64 release APK 构建成功，三份产物均通过 `apksigner` 且证书身份与配置一致。未构建其他平台，阴影强度和弹簧手感仍需 Android 真机观察。

### 在线书源补齐整书连续滚动

- 修复“阅读器统一”遗漏：在线书源的上下滚动模式现与本地阅读共用“按章节滚动”开关和持久化偏好。
- 本节记录的是旧的长正文滚动实现：开启时单章滚动、关闭时懒加载整书纵向内容流；现已由同日“上下翻页”预分页列表重构取代，持久化开关语义保留。
- 设置面板摘要、翻页模式面板和滚动状态同步反映当前策略；共享设置与在线阅读模式定向测试共 15 项、全量测试 152 项通过。变更文件静态分析无问题；全项目分析仅保留 3 条既有 `cacheExtent` 弃用提示。

### v1.2.1 发布

- 版本号升级为 `1.2.1+12103`，更新 `CHANGELOG.md`、应用内版本记录和 `.github/release-notes/v1.2.1.md`。
- 发布提交 `5e87f57` 已推送至 `main`，Tag `v1.2.1` 触发跨平台 Release 工作流；发布源校验、格式、静态分析、全量测试、Android/Windows/Linux 构建和 GitHub Release 发布全部成功。
- GitHub Release：`https://github.com/miloquinn/open-reading/releases/tag/v1.2.1`；包含 3 个分架构 Android APK、Windows x64 ZIP、Linux x64 tar.gz 和 `SHA256SUMS.txt`。
- Android APK 的自动签名身份校验通过，发布产物确认使用配置的签名证书。

### v1.2.2 在线阅读控制栏热修复

- 修复 1.2.1 整书连续滚动中的手势回归：在线书源的 `SelectionArea` 会赢得手势竞争，导致外层点击回调无法收到屏幕中间轻点。
- 连续滚动改用原始指针监听，仅在未移动、未长按且位于屏幕中间三分之一的轻点时切换控制栏；上下拖动与长按文字选择不会误触。
- 新增真实手势竞技场回归测试，修复前稳定失败、修复后在线阅读模式 12 项通过；隔离发布源码格式检查、静态分析和全量 153 项测试通过。
- 版本号 `1.2.2+12104`，发布提交 `9c0a373`，GitHub Release：`https://github.com/miloquinn/open-reading/releases/tag/v1.2.2`。
- Android、Windows、Linux 产物与 `SHA256SUMS.txt` 发布成功；Android APK 签名身份校验通过。

### 本地书籍格式支持基线（Lightink 对照）

- 新增 `lib/services/books/book_format_support.dart`：格式能力级别、阅读管线、选择器扩展名与 Lightink 对照说明的单一注册表。
- 新增 `docs/book-format-support.md`：约定 TXT/EPUB 走统一文本分页；ZIP/RAR 为容器；MOBI/AZW3/FB2/RTF/Office 目标为转纯文本后分页；PDF/漫画为专用渲染；并写明分阶段优先级。
- `book_import_source_service` / `book_import_service` 的 FilePicker 扩展名改为引用注册表，避免多处硬编码分叉。
- 产品目标：Open Reading 将来完整支持上述格式矩阵；ZIP/RAR 在实现前不进入选择器（`acceptInFilePicker: false`）。

### v1.2.0 发布准备

- 版本号 `1.2.0+10101`；正式更新说明写入 `CHANGELOG.md` 与 `.github/release-notes/v1.2.0.md`，应用内版本记录同步扩展。
- 通过推送 Tag `v1.2.0` 触发跨平台 Release 工作流，自动构建 Android / Windows / Linux 产物并发布 GitHub Release。

### 阅读器水平页边距与居中

- 本地阅读器和在线书源阅读器的水平页边距最小值由 8 调整为 0，设置滑块、持久化恢复和运行时更新统一使用 `0..48` 范围。
- 复查确认先前的宽屏容器居中只约束最大行宽，未解决手机端中文软换行把剩余宽度全部留在右侧的问题。
- 本地文件与在线书源正文现统一使用两端对齐；分页测量和最终绘制共用同一规则，滚动、无动画、水平滑动和仿真翻页路径全部覆盖。
- 删除上一版仅用于检查宽屏盒子坐标的测试 key 和失焦测试，改为加载实际中文字体验证非末行铺满可用宽度，并覆盖在线书源滚动与分页正文对齐。
- 清理已删除 Golden 测试遗留的 4 张 `test/failures/` 失败截图，并忽略该生成目录；现有 47 个 Dart 测试文件均由全量测试实际执行，因此全部保留。
- 相关阅读器定向测试 51 项、全量测试 150 项通过；`flutter analyze --no-pub` 无问题。

### GitHub Actions 自动化升级

- 日常 CI 增加锁定依赖、国际化生成一致性、覆盖率产物、Android debug 与 Web release 冒烟构建；Pull Request 保留中等级别起失败的依赖安全审查。Web 构建因现有 JavaScript 64 位整数兼容问题暂设为提示性检查，不阻塞主质量门。
- 新增跨平台冒烟工作流，在相关代码变更、每周计划任务和手动触发时验证 Linux、Windows、macOS release 以及不签名的 iOS release；OpenHarmony 因依赖专用 SDK 暂不纳入托管运行器构建。
- 发布流程新增 Tag 与 `pubspec.yaml` 版本一致性、完整质量门、固定 Action 提交版本、Android APK 签名身份校验、发布说明源码检出和 SHA-256 校验清单。
- Flutter 应用锁文件改为纳入版本控制，所有 CI 与发布构建均强制使用锁定依赖，提高跨时间和跨平台的可复现性。

## 2026-07-17

### 音量键翻页真实接入

- Android 原生层已有的音量键事件桥正式接入本地阅读器和在线书源阅读器；音量减为下一页，音量加为上一页，并复用各翻页模式现有的无动画、水平滑动和仿真翻页路径。
- 全局“音量键翻页”开关与当前翻页模式共同决定是否拦截硬件按键：无动画、水平滑动和仿真翻页可用；上下滚动模式不拦截，音量键保持系统调音量行为。
- 翻页模式显示名称统一为“无动画”“水平滑动”，设置副标题同步说明仅适用于非滚动翻页模式。
- 音量键桥接、阅读器实际翻页和翻页模式回归共 16 项定向测试通过；全项目静态分析无新增问题，仅保留 3 条既有 `cacheExtent` 弃用提示。

### 无封面书籍统一生成封面

- 重做默认封面绘制器：简约样式只由书名与作者决定，不再使用文件格式、APP 图标或额外方形印记，因此同一本书从本地文件或在线书源进入时视觉一致。
- 本地导入在所有格式的元数据解析完成后统一补齐封面；书源在线加入书架和下载到本地时也会生成并保存 PNG，不再仅覆盖 TXT/PDF/MOBI 的部分分支。
- 新增共享 `GeneratedBookCover` 实时兜底，书架、书源发现/搜索、移动首页和统计页遇到历史空封面、文件损坏或网络封面加载失败时使用同一绘制器。
- 真实封面始终优先；书架中的书源书籍下载为本地文件后，仍可继续使用来源封面 URL，不会误生成替代封面。
- 封面生成、本地导入和书源书架共 9 项定向测试通过；相关文件静态分析无新增问题，仅保留 3 条既有 `cacheExtent` 弃用提示。

### 用户自定义字体

- 新增共享用户字体库：TTF/OTF 文件只导入一次，同时出现在 App 字体与阅读字体候选列表中。
- 从 App/阅读字体面板导入时只自动应用到当前字体域；字体管理页可改为另一字体域或同时用于两者。
- 原生平台字体保存在应用私有 `custom_fonts/` 目录，以 SHA-256 去重，并用独立运行时 family 防止同名冲突。
- 启动时恢复当前选中的用户字体；文件缺失或加载失败时安全回退到对应默认字体。
- 删除正在使用的字体会同步重置相关选择，阅读字体变化继续沿用现有分页签名和重排逻辑。
- Web 首版不提供持久化字体导入，界面会明确提示平台限制。
- 自定义字体服务与两套字体域的 8 项定向测试通过；全项目静态分析无新增问题，仅保留 3 条既有 `cacheExtent` 弃用提示。
- 全量测试共通过 115 项，仍有两个既有失败：Windows 路径分隔符断言和阅读导航面板 Golden 差异；均与本功能无关。
- 设置页社区入口新增 Telegram 官方频道，顺序为 GitHub、Telegram、QQ，相关文案统一维护在 ARB 国际化资源中。

### 应用内开源许可

- 设置页“关于”区域新增开源许可入口，可离线查看项目 AGPL-3.0、v1.0.0 及更早版本的历史 MIT 许可，以及 5 套内置字体的 SIL OFL 1.1 原文。
- 第三方 Flutter/Dart 依赖继续使用 Flutter 自动汇总的许可清单展示，避免手工维护依赖许可副本。
- 项目主许可与历史许可文件作为 Flutter 资源随应用打包；字体许可继续由 `assets/fonts/licenses/` 统一维护。
- 许可页定向静态分析无问题，相关页面/字体/更新日志回归共 10 项测试通过，Android debug APK 构建成功。

### 阅读器统一

- 本地阅读与在线书源阅读不再各自维护设置面板和控制栏。
- 两个入口共用 `ReaderSettingsStore`、完整阅读设置面板、翻页模式面板、阅读控制层和安全区计算。
- 在线书源删除旧的单一纵向边距运行路径，改为独立上边距和下边距。
- 本地文件和在线书源仍保留不同的内容获取、分页适配和进度保存逻辑。
- 阅读相关定向静态分析通过，相关 33 项测试通过。

### 阅读器首末行行距裁剪

- 本地阅读与在线书源阅读统一关闭首行上方、末行下方的行高 leading，使上下边距为 0 时正文从字形边缘贴合可用区域，行间距保持不变。
- 配套 strut 只保留字体、字号、字重和字形兜底，不携带 `height`；否则 strut 会绕过 `TextHeightBehavior` 把首末行 leading 加回。
- 本地与在线书源分页缓存版本分别升级到 `native-line-v3` 和 `book-source-line-v3`，旧排版缓存自动失效。
- 新增 4 项排版回归测试，覆盖裁剪量、行距、strut 约束和每页容纳行数。
- 使用原 release 证书构建并通过 `adb install -r` 覆盖安装到 Android 16 真机 PKT110；签名指纹一致、`firstInstallTime` 不变，应用数据与阅读位置保留，零边距正文贴合和仿真翻页均完成真机检查。

### 导入确认页安全区重做

- 手机端选中书籍后进入专注确认态：隐藏大块来源面板，书目列表独立滚动，并通过“选择文件”底部面板继续添加来源。
- 导入主操作从 `Scaffold.bottomNavigationBar` 移入页面自身布局，改为底部安全区内的整宽按钮，避免文件选择器返回后按钮被挤到状态栏。
- 页面忽略无关的键盘 inset，并对异常 `padding/viewPadding` 限幅；新增极端 760px 底部安全区回归测试。
- 导入页定向静态分析通过，控制器与页面共 8 项测试通过。

### 书源范围收敛

- 项目聚焦 Open Reading Source Protocol。
- 删除旧阅读书源兼容实现、扫描器、注册器、示例和对应测试。
- 原生书源协议版本为 1.1。

### 版本与真机

- 应用版本升级为 `1.1.1+10100`。
- 使用原 release 证书构建并覆盖安装到 Android 16 真机 PKT110。
- APK 版本和证书指纹均在安装前校验。
- 覆盖安装后 `firstInstallTime` 保持不变，确认应用数据未因本次更新清除。
- release 应用成功启动，未发现启动崩溃。

### Android 安装操作规则

- 已安装 release 包时，不使用 debug 签名直接覆盖。
- 真机更新默认使用原 release 证书和 `adb install -r`。
- 签名不一致或覆盖失败时必须停止，不得自动卸载应用。
- release 证书和密码保存在仓库外，不得提交到 Git。
- 构建工具可提示 Gradle、AGP 和 Kotlin 版本即将过期，后续需要安排升级，但当前不阻塞构建。

### Git 状态

- 阅读器统一提交：`dd5d04b`。
- 应用内版本历史提交：`36c4c59`。
- 原生书源协议范围收敛提交：`e09ba59`。
- `main` 已与 `origin/main` 同步；本轮未发布 GitHub Release。

## 已知验证注意事项

- 阅读器和在线书源定向测试已通过。
- 全量测试曾在 Windows 环境出现路径分隔符断言和导航面板 Golden 差异；这些问题与阅读器统一逻辑无直接关系，后续全量验证时应单独复查。
- 全项目静态分析存在少量既有 `cacheExtent` 弃用提示，需要在 Flutter 依赖升级时处理。

## 2026-07-19

### v2.0.0 正式发布

- 版本升级为 `2.0.0+12108`，相对上一版本构建号增加 2。
- 阅读主题支持多套自定义主题、背景图片、选择、删除和拖拽排序，并完成旧单主题数据迁移。
- 仿真翻页只保留经典折页；移除圆柱卷页样式选择、持久化、渲染分支、shader 及相关设置代码。
- 全量 226 项测试通过；静态分析仅保留 3 条既有 `cacheExtent` 弃用提示。
- 使用共享 Origo release 签名生成并核验三套 Android APK；arm64-v8a 包覆盖安装到 Android 16 真机 PKT110，版本为 `2.0.0 (14108)`，应用数据保留且启动无致命错误。设备受凭据锁屏限制，未绕过锁屏执行手势验收。
- 发布提交为 `7f77ce5`，格式修复提交为 `e542910`；`main`、`origin/main` 与 `v2.0.0` 标签最终均指向 `e542910`。
- GitHub Actions 发布运行 `29653675418` 成功，Android、Windows、Linux 产物及 `SHA256SUMS.txt` 已发布到 GitHub Release `v2.0.0`，并确认为 Latest。

### 阅读主题描边与全局排序修复

- 阅读设置横向主题卡片改为先裁剪背景、再在最上层绘制同圆角描边，修复选中卡片四角描边被背景覆盖、断裂或错位的问题。
- 主题管理页改为同时展示预设与自定义主题；“白天”“晨雾”“护眼”等预设主题也可通过右侧手柄参与拖拽排序，自定义主题继续支持新增、编辑和删除。
- 新增 `reader_theme_order_v1` SharedPreferences ID 列表，两个阅读器启动时共同恢复完整主题顺序；缺失、新增、重复或已经删除的主题 ID 会自动归一化。
- 定向静态分析通过；主题模型、顺序存储、管理页、阅读设置及两个阅读器接线共 34 项定向测试通过。

### 阅读统计详情页视觉与模块重构

- 阅读统计详情页统一为首页的书卷风格：大字号衬线标题、雾蓝主卡、暖白圆角卡片、单一蓝色强调和低饱和辅助色，移除原有高密度玻璃渐变表达。
- 原 `detailed_stats_page.dart` 的页面 UI 按公共样式、总览、图表、热力图、书籍排行和成就拆分到 `pages/detailed_stats/`，入口文件只保留状态、数据加载、顶部栏和页签壳层。
- 新增 412×915 手机尺寸回归测试，实际渲染并滑动检查四个页签；统计模块静态分析与页面测试均通过。
- Android 独立预览 debug 包编译成功，但真机预览受已安装更高版本号和设备侧 sqflite debug 依赖异常阻断；复查确认设备仍安装正式版 `2.0.4 (14116)`。本次未改动相关首页半成品代码，也未执行 release 构建。

### v2.0.5 Android 真机构建与安装

- 应用版本提升至 `2.0.5+12118`，arm64-v8a release APK 使用共享 Origo release 身份完成签名，APK 与配置证书指纹一致。
- release APK 已通过 `adb install -r` 覆盖安装到 Android 真机 PKT110；设备确认安装版本为 `2.0.5 (14118)`，应用成功启动并保持运行。

## 2026-08-02

### 阅读书源原生网络会话

- 阅读书源请求改为按书源维护独立 Cookie 会话，支持静态 Cookie、`Set-Cookie` 域/路径/Secure/过期校验，以及浏览器一致的 301/302/303/307/308 重定向语义；跨站重定向会移除敏感请求头。
- DNS 固定连接从只尝试首个地址改为 IPv4 优先并逐地址回退，单地址连接失败不再直接导致整个书源不可用；GET 瞬态连接失败会进行有限重试。
- 源级请求头支持 `source.getKey()`、`source.bookSourceUrl` 等常见取值表达式，发现页把连接、重定向和 HTTP 状态错误转换为本地化提示，不再向用户暴露内部运行时名称。
- 网络策略、请求会话、发现页定向回归共 47 项通过；相关文件静态分析无问题。未执行签名或分发构建。

### 兼容书源导入与发现双布局

- 兼容书源批量导入改为本地解析、去重后一次写入，不再用全局静态兼容扫描提前禁用整条书源；能力由现有规则组声明，规则语法在实际使用对应功能时按需校验。
- 使用 `shuyuan.json`（6,008,449 字节）实测 1,048 个书源约 0.29 秒解析完成，1,047 个保持可启用；使用 `shareBookSource.json`（22,049,828 字节）实测 3,880 个书源约 0.54 秒解析完成，3,863 个保持可启用。测试只解析内存数据，未写入用户书源库。
- 发现页新增可记忆的“标准布局 / 列表布局”切换；列表布局按书源惰性构建目录，单源展开频道，选择后聚焦现有分页书单，并可通过“更换”返回目录。
- 书源列表卡片与详情弹窗统一清洗简介中的 `<br>`、转义换行、HTML 实体、多余空白和不可见字符，不修改原始书源数据。
- 简介清洗、布局偏好恢复、列表展开/频道聚焦以及现有发现页和兼容运行时定向测试通过；未执行签名或分发构建。

### 发现频道空白修复

- 修复频道请求异常被发现页吞掉并显示为空分类的问题；首次加载失败现在展示具体错误和重试入口，首屏列表规则零匹配也会报告书源规则可能已过期。
- 兼容请求与参考实现保持一致，缺省补充浏览器 User-Agent；允许书源为公网 IP 虚拟主机设置静态 Host，Cookie 和传输控制头仍禁止。
- 对截图中的 101言情、123笔趣阁、147小说、175看书进行了真实配置探测；确认频道名来自本地静态配置，不代表远端仍可访问。当前测试网络中这些请求返回 HTTP 400，而 `123笔趣阁` 的频道 URL 通过 curl 独立验证已返回 404，属于源地址过期而非解析器空列表。
- 新增聚合源常见 `.lst-item`、`a.1`、`span.0`、`img@_src` 规则回归，以及频道错误可见/重试回归；发现页与兼容运行时共 37 项测试通过，相关静态分析无问题。

### 书籍打开动画清理与响应优化

- 保留经典封面、极简淡入、纸面浮现和侧页推入四种动画及各自的快速/优雅二级节奏；默认节奏改为快速，已保存的优雅选择继续恢复，旧双页展开配置安全降级为极简淡入。
- 删除本地与在线阅读器重复的开场切换和延时重播逻辑，统一为“阅读主题底色交接一次、正文首帧就绪后透明度从 0 到 1 一次”；快速正文渐显为 240ms，优雅为 720ms，经典封面动画继续保留并等待正文就绪后交接。
- 启动阶段预热并缓存阅读主题；首页/书库将主题读取与书籍查询并行，本地打开继续让主题准备与文件修复、存在性检查重叠。主题切换会立即刷新缓存，并阻止旧的启动读取覆盖新选择，消除深色主题入口的白色中间帧。
- 书籍转场合并监听器改为生命周期内复用，减少路由逐帧构建期间的临时分配；转场继续只使用透明度、位移和快照等合成友好属性。
- 动画、设置、主题缓存、TXT、在线书源、首页和设置入口共 77 项定向测试通过；动画相关入口静态分析无问题。

### 开书空白与交互锁死修复

- 正文就绪门禁从整页透明改为只控制正文层；阅读主题背景、加载反馈、顶部/底部控制栏和返回路径从路由首帧起保持可用，慢加载不能再把阅读器变成不可操作的空白页。
- 删除路由级整页 `TickerMode` 暂停，只在正文局部暂停高成本动画；翻页快照仍遵守 `ReaderTransitionWorkScope`，控制栏展开动画不再被转场状态冻结。
- 本地阅读器的初始位置占位层下移到正文与控制栏之间，位置恢复即使异常也不会无限盖住控制栏；已完成路由的状态监听增加下一帧安全确认，避免错过完成事件或在首帧提前放行重工作。
- 慢加载反馈延迟由 650ms 缩短为 220ms，本地与在线书源阅读器一致。经典封面动画及快速/优雅正文交接保持不变。
- 动画、慢加载退出、翻页快照、在线书源、本地 TXT、首页继续阅读和设置入口共 92 项定向测试通过；目标静态分析无错误或警告，仅保留本地阅读器 7 条既有代码风格提示。

### 换源搜索第二轮性能优化

- 换源搜索默认并发由 6 提升到 12，每个来源的搜索预算限定为 6 秒；优先调度 ORSP、已完整验证的阅读书源、配置响应时间较低的阅读书源，再按自定义顺序和名称稳定排序。
- 默认首轮只检查优先级最高的 60 个来源，累计找到 8 个候选后暂停；页面提供“继续查找全部来源”，续查时排除已经完成的来源并保留已有候选。
- 取消与超时令牌贯通 ORSP Dio 和阅读书源 HTTP 传输层，能够中止在途网络请求并尽快释放 worker；新搜索不再等待旧订阅完全退出。
- 大型书源注册表的 JSON 解码、阅读书源兼容扫描和运行门禁过滤移入后台 isolate；换源结果继续按 120ms 窗口批量刷新并原位追加，降低 Debug 模式主 isolate 卡顿。
- 换源、普通搜索、阅读书源运行时、书架与阅读器相关 86 项回归通过；15 个触达文件静态分析无问题。未执行签名或分发构建。

### v2.4.6 发布准备

- 公开更新内容统一归入“更多书源”，覆盖大型书源库快速导入、原生规则执行、发现页双布局与按需加载、书源搜索管理和简介清理；公开文案不使用内部参考项目名称。
- 版本更新为 `2.4.6+260802001`，基础构建号已按 Asia/Shanghai 日期规则占用；本地 Android 三 ABI 签名构建、包元数据、V2 完整签名、证书身份与 SHA-256 均已验证，arm64-v8a 交付包已复制到 `output/releases/v2.4.6/`。
- 书源核心 11 个文件 107 项回归通过，书源管理选择模式隔离复跑通过；全项目静态分析无 error/warning、保留 55 条既有 info，格式检查 419 个文件零变更。正式 Tag、私有发布流水线与公开 Release 验证待完成。

### 私有开发与公开 Release 分离

- 后续源码、验证和发布 Tag 迁移到私有仓库 `miloquinn/open-reading-neo`；公开仓库 `miloquinn/open-reading` 保留截至 `v2.4.5` 的公开源码和历史版本。
- 发布流水线从私有 Tag 构建、签名并部署，使用审批保护且限于公开仓库的 `PUBLIC_RELEASE_TOKEN` 写入公开 Release；Release Notes 必须由版本文件显式提供，不再从私有提交自动生成，避免泄露内部提交信息。
- 公开仓库原有 Release workflow 必须保持禁用，避免镜像 Tag 触发旧源码重复构建；本地默认上游切到私有仓库，公开远程禁止 Git push。
- 私有 PR checks 在 Linux 测试前把锁定的 `flutter_js 0.8.7` 自带 QuickJS 共享库目录加入 `LD_LIBRARY_PATH`，避免规则脚本用例因 Runner 未搜索到已下载的 `.so` 而误报失败。
- 当前 GitHub 套餐不支持私有仓库 Environment required reviewer；`release` Environment 已建立但没有审批保护。发布前置 job 会在任何平台构建前验证跨仓库 Token，macOS 凭据迁入前保持 `MACOS_RELEASE_ENABLED=false`。
