# 云端 TTS 服务商预设与分级配置

## 交互

设置与听书控制共用同一入口：我的语音 → 添加语音 → 服务商 → 配置。
配置首屏为模型、音色选择、API Key 和试听；保存并使用固定在底部。
音色页支持名称与 ID 搜索。名称、接口地址、手动模型/音色 ID、格式、失败回退及删除在高级自定义中。
豆包、MiniMax、OpenAI 原生预设均只需填入对应平台 API Key；开通权限及计费由各平台管理。
已有 OpenAI 兼容配置保持原值，不自动替换模型或音色。每个配置仍独立存储密钥。

## 已核对的官方资料（2026-09-16）

- 用户提供的豆包双向接口：https://docs.volcengine.com/docs/6561/2532486?lang=zh
- 本次接入的豆包单向 HTTP：https://docs.volcengine.com/docs/6561/2528925?lang=zh
- 豆包音色：https://docs.volcengine.com/docs/6561/1257544?lang=zh
- 豆包流式结束码参考：https://docs.volcengine.com/docs/6561/1598757?lang=zh
- MiniMax 当前接口与模型：https://platform.minimaxi.com/docs/api-reference/speech-t2a-http
- MiniMax 音色：https://platform.minimaxi.com/docs/faq/system-voice-id
- OpenAI 当前模型与音色：https://developers.openai.com/api/docs/guides/text-to-speech

豆包使用 seed-tts-2.0 与对应 2.0 音色、X-Api-Key 单密钥认证；HTTP 接口适合现有按段朗读，避免引入另一个长连接生命周期。
MiniMax 预设 speech-2.8-hd 与 speech-2.8-turbo，走原生 t2a_v2 与 hex 音频响应。
OpenAI 官方当前仍推荐 gpt-4o-mini-tts，优先提供 Marin / Cedar，并保留全部 13 个内置音色。

## 验证范围

协议测试覆盖请求头、模型、2 倍速映射、流式字节分界、SSE/JSON 帧、结束码、错误响应、音频大小限制及历史配置兼容。
界面回归覆盖分级导航、菜单选音色、试听不保存、密钥隔离、空值保留、延迟删除、保存失败重试、无效 URL 和小屏键盘。
真实付费 API 的鉴权、音质与实体设备连续播放需使用各平台有效凭据验证；本次不读取用户密钥、不发起付费合成。

验证结果：61 项回归测试通过（协议 5、配置界面 9、云端服务 14、听书控制 20、设置入口 13），分别在独立 Flutter 进程中顺序执行。定向静态分析无问题。
截图工具覆盖 390×844 浅色及 320×568 深色 1.4 倍字号；已人工查看配置、服务商与音色选择页。未执行平台发布构建或实体设备测试。

## 小米 MiMo 补充

新增小米 MiMo 原生预设，默认 `mimo-v2.5-tts`、冰糖、WAV；音色菜单包含冰糖、茉莉、苏打、白桦、Mia、Chloe、Milo、Dean 和集群默认音色。
采用 `/v1/chat/completions` 与 `api-key` 认证；朗读文本放入 assistant 消息，语速指导放入 user 消息，解码 `choices[0].message.audio.data`。拒绝截断、错误、空音频及超限响应。复用逐段预加载与独立密钥存储。
MiMo 文档提供自然语言语速指导，没有数值 speed 参数；实际倍速可能存在差异，配置页明确说明。声音设计与克隆模型需要额外输入，本次不作为开箱即用预设。

官方来源（2026-09-16 核对）：
- https://mimo.mi.com/docs/quick-start/usage-guide/audio/speech-synthesis-v2.5
- https://mimo.mi.com/docs/api/audio/tts

未进行真实付费合成或实体设备音质验证。
