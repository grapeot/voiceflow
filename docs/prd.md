# VoiceFlow PRD

## 目标

这个 repo 是两个产品并存：

1. **VoiceFlowKit**（Swift Package）——一个面向 AI 集成方的语音输入"生成内核"。让任何 iOS 17+ / visionOS 1+ app 的 host AI agent 通过读一份 skill 文件就能给宿主 app 加上"按一下录音 → 出文字"的能力。
2. **VoiceFlow**（iPhone / iPad / Apple Vision Pro app）——基于 VoiceFlowKit 的第一方语音输入工具。

下面所有 "目标 / V0 / V1 / 功能范围" 章节描述的是 **VoiceFlow app**。**VoiceFlowKit 的设计哲学和产品边界**单独在下一节展开，因为它是另一类产品（library / generative kernel），衡量标准和成功标准不一样。

### VoiceFlow app 的目标

VoiceFlow 是一个纯粹的语音输入工具。它要解决的是现有语音输入工具控制感不足的问题：用户只是想把话准确、快速地变成文字，产品就应该只做转写，不主动回答、不润色、不改写用户意图。

V0 的核心目标有两层。第一，语音识别准确率高、速度快，输出尽量贴近用户原话。第二，转写完成后自动把文本放进系统剪贴板，让用户可以立刻粘贴到任何 app。OpenCode 是可选增强配置，不配置也不影响 VoiceFlow 作为语音输入工具使用。

### VoiceFlowKit 作为生成内核的目标

VoiceFlowKit 按 [generative kernel](https://yage.ai/ai-software-engineering.html) 的思路设计：交付物不是一个隐藏底层细节的"开箱即用 SDK"，而是一套让宿主 AI 在用户 app 里高质量"自己组装"语音输入能力的内核。

按那篇文章里的三分法对应：

- **核心套件**：`Sources/VoiceFlowKit/` 里的 facade（`VoiceFlowClient` / `VoiceFlowSession` / `VoiceFlowMicrophone` / `VoiceFlowConfig` / `VoiceFlowError` 等）。这是宿主 AI 没办法在 prompt 里"现编"出来的底层 —— WebSocket ticket flow、PCM16 编码、partial transcript 合并、recover 重连。
- **引导知识**：`skills/adding_voice_input_with_voiceflowkit.md`。这是给 host AI 看的、不是给人看的集成手册。内容覆盖 5 步集成流程、验收标准、9 条已知陷阱、reference implementations 在哪里读。Skill 是一等公民，跟代码一起 ship、一起 review、一起更新。
- **杠杆工具集**：`VoiceFlowClient.makeStub(...)`（offline stub client，让 host 的 UI test launch mode 不依赖网络也能跑通）、`VoiceFlowAudioMetering.normalizedLevel(fromPCM16LE:)`（如果 host 想自己接 AVAudioEngine 而不用我们的 mic，也能算出一致的 0..1 level）、`StreamCaption` / `StreamCaptionStore`（双层 caption 状态机给 host 做 "reconnecting…" / "stream restored." 这种 UX）。这些都是"AI 在概念上能想到，但自己实现繁琐易错"的部分。

为了让 host AI 能可靠组装，设计上有几条硬约束：

- **错误透传，不包装**：`VoiceFlowError` 把 HTTP status code、WebSocket detail、底层 reason string 都直接 surface 出来。Host AI 看到 `.httpError(statusCode: 401)` 立刻知道是 token 问题，看到 `.connectionLost("ticket POST timed out")` 立刻知道是 ticket 阶段就挂了 —— 不是抛一个 `.apiFailure`。
- **暴露细粒度控制**：actor `VoiceFlowSession` 把 `sendAudioChunk` / `ping` / `commitAndStop` / `cancel` / `connectionPhase` / `events` 全部公开。Host 如果想用自己的 mic 不用 `VoiceFlowMicrophone`、想做自定义心跳 cadence、想消费 partial transcript 同时还想自己监听 phase change，都不需要 hack。
- **skill 文件覆盖真实陷阱**：已知陷阱必须来自实际踩过的坑（OpenCode pilot + VoiceFlow 自身开发的迭代教训），不靠想象凑数。每条陷阱配具体表现 + 应对。

成功标准：一个完全没看过 VoiceFlow 这个 repo 的 host AI agent，读完 `skills/adding_voice_input_with_voiceflowkit.md` 之后，能在 host 的 SwiftUI app 里加完整可用的语音输入 button，单次 prompt 内完成（不需要回头查 kit 源码、不需要 trial-and-error）。如果做不到，skill 还不够好。

## V0 交付状态（2026-05-26）

已在 `master` 交付：Record / Settings 双 tab、GUI 对齐、Keychain token、录完上传转写、自动复制、双向历史导航、保存/重发录音、可选 OpenCode（含连接测试 gating）、录音诊断日志、语言偏好（System / English / 简体中文）、Settings 键盘收起与连接失败 detail、privacy review、GitHub 发布（https://github.com/grapeot/voiceflow）、deep link（`voiceflow://record`）。

尚未交付：iOS / iPadOS 的 Settings 外观偏好（System / Light / Dark 手动选择）。当前 iOS 跟随系统日间/夜间模式；**visionOS 不在这个偏好的范围内** —— visionOS native app 没有 Light/Dark 概念，Apple 用 glass 材质自适应环境光。Vision Pro 上 Settings → Appearance 里那条 Light/Dark 子标题是 "Compatible Apps Appearance"，只影响 iPad/iPhone compatibility app（不是 visionOS native build），对我们这种 native visionOS target 完全无效。VoiceFlow 在 visionOS 上 pin 到 Light 配色，与 Vision Pro 默认 glass UI 一致。

## V1 交付状态（2026-05-26）

已交付 WebSocket 实时流式转写，含断线恢复：

- Start 先 `POST /backend/v1/audio/realtime/sessions` 取 ticket，再连 `wss://.../backend/v1/audio/realtime/ws?ticket=...`，边录边发 ~0.5s PCM16 24 kHz 分片。
- **录音与 recover/replay 期间**：不消费、不显示 `transcript_delta`（对齐 OpenCode iOS：WS 可收包但不更新转写 UI）。
- Stop 才 finalize（flush + `commit` + `stop`），此后在 transcribing 阶段随 `transcript_delta` 增量显示并最终写入历史。
- 断线/ send 失败：磁盘 cache 静默重连并重放全部已录 PCM（不对齐时间轴 sleep）；录音中不更新转写区；caption 提示重连/断开。
- 录音中 transient disconnect：不弹 modal；caption `record.status.reconnecting` / `record.error.streamDisconnected`；状态灯绿/橙/红不变。
- Start 顺序：mic + cache 先启动，WebSocket deferred attach（不阻塞录音）。
- recover 带指数退避重试；Stop 等待 recover 后再 finalize。
- 单元测试 51+ 项（含 epoch merger 与 recovery caption 测试）。

## 工程变更（2026-05-28）：VoiceFlowKit 抽取 + 转写上下文 UI

两个连续 PR（#35、#36）落地。

**PR #35（VoiceFlowKit 抽取）**：V1 的录音/转写底层 pipeline 抽到独立 SPM package `VoiceFlowKit`，位于仓库根目录。VoiceFlow app 通过本地 SPM 依赖引用 Kit。对**产品行为零影响**——上面所有 V0 / V1 交付状态保持不变，UI 不变、UX 不变、wire protocol 不变。

**PR #36（转写上下文 UI）**：Settings 新增"Transcription"分组，含两个新字段：

- **Context prompt**（上下文提示）：自由文本，转写前传给模型作上下文参考（可以写人物、项目、话题、语言、格式指令等）。
- **Terms**（术语字典）：英文逗号分隔的术语列表，要求模型原样保留。

两个值通过 UserDefaults 持久化、随每次实时和重新转写请求一起发到 backend。Settings 的所有输入框（API token、OpenCode 配置、prompt、terms）现在统一使用"输入卡片"视觉（深色背景上浮起浅色卡片），明确告诉用户哪里可以输入。详细视觉规则见 `docs/design.md`。

PR #36 一并完成的清理：

- 拿掉原 PR #35 引入的 `language` 字段——后端把语言提示作为 prompt 拼接，单独 language 字段是冗余。如果用户想指定语言，自己在 prompt 里写。
- Swift 6 concurrency warnings 全清。

**产品意义**：未来 OpenCode iOS Client 等其他客户可以通过远程 SPM 依赖（GitHub repo `grapeot/voiceflow`）拿同一份 pipeline，避免两边各自实现各自修 bug。架构细节见 `docs/rfc.md` 的"模块划分"章节；面向 AI 集成方的完整集成指南见 `skills/adding_voice_input_with_voiceflowkit.md`。

**用户使用提示**（prompt 写法）：模型对**短指令** prompt（如 "Output in all caps"）响应弱；要让 prompt 真的改写输出格式，需要带**示例**——比如 `Transcribe every word in ALL CAPS. Example: THIS IS A TEST.`。Settings 的 placeholder 已经体现这种 instruction+example 形态。这不是 library 的 bug，是 `gpt-realtime` 模型的 prompt-following 行为特征。

## 工程变更（2026-05-28 续）：facade 收紧 + AppState 拆分

两个连续 PR（#38、#40）落地，对**产品行为零影响**。

**PR #38（facade 迁移 + Internal 可见性收紧）**：PR #35 抽包时为了让 VoiceFlow app 自己不大改，把 services 层 protocol（`RealtimeTranscribing` / `RealtimeConnectionPhase` / `AudioChunkEncoder` 等）都留成 public。这次把 VoiceFlow app 也切到 facade（`VoiceFlowClient` / `VoiceFlowSession` / `VoiceFlowEvent`），并把那些只为 app 兼容而 public 的 Internal 类型改回 internal。kit 现在对外只暴露一套表面（facade），OpenCode 没动。同时新增 `VoiceFlowClient.makeStub(...)` public factory，让宿主在 UI test launch mode 下用 offline stub。

**PR #40（AppState 同型 extension 拆分）**：`AppState.swift` 从 1098 行降到 493 行（-55%）。按职责切到 7 个 extension 文件：LiveSession（live bridge 主体）/ OpenCode / Diagnostics / AIBuilderToken / RecordingFiles / StreamCaption / RecordingTimer / TranscriptHistory。State 字段留在主 AppState（SwiftUI 视图直接 bind），只搬行为。同时把 `Package.resolved` gitignore 从全局忽略改成只忽略根目录 —— 为将来加远程 SPM 依赖后 Xcode Cloud 能正确 resolve 做准备。

## V1 规划：实时流式转写（原规划，已实现）

V0 采用「录完再上传」：Stop 之后才开始 multipart 上传整段 WAV，用户需等待上传与推理完成才看到完整转写。V1 目标是显著降低 Stop 后的感知延迟，并在录音过程中就把音频发给服务端。

### 产品行为

用户按下 Start 后，app 通过 Bearer token 创建 realtime session 并建立 ticket WebSocket，边录边以固定时长分片（约 0.5s、24 kHz PCM）发送音频。录音与断线恢复期间转写区保持空白（或用户已有草稿），不随服务端 push 变化。用户按下 Stop 时，flush 剩余 buffer 并发送 `commit` + `stop`，此后在 transcribing 阶段消费 `transcript_delta` / `transcript_completed`，增量更新转写区直至 `session_stopped`。

转写区仅在 Stop 之后的 finalize 阶段随服务端 push 更新；录音与 recover 期间忽略 WS 转写事件（对齐 OpenCode iOS `commitAndStop` 才读 recognition 的模式）。录音期不输出是有意的质量权衡——实时输出时远端每次只看到零散语音片段、缺后文语境，识别质量下降，所以把识别质量留到 Stop 后一次拿满。finalize 阶段的更新是逐 delta 打字机：远端来一个 delta 就显示一个 delta，文字逐段长出，而不是后台静默 accumulate 完整段再一把显示。

Stop 到首个可见文本的目标体验：亚秒级（取决于网络与服务端），而不是 V0 的「整文件上传 + 等待完整 JSON」。

### 失败恢复（产品要求）

- WebSocket 断开：录音中不更新转写区；不弹 modal；状态灯变红/橙，caption 显示「正在重连」或「流已断开」；后台 cache replay 重连。
- 录音过程中连接未就绪：先开 mic + 磁盘 cache，WebSocket 在后台 attach；cache 按顺序 bulk 重放（不按时序 sleep）。
- 服务端 error / 持久重连失败：录音中只显示 caption，不 interrupt 录音。
- Stop / finalize：等待 recover 完成后再 commit；finalize 失败但已有 partial 时进入 ready 并保留文本（caption 提示，无 modal）。
- 会话正常结束（connected/generating → idle）：最终 transcript 写入历史并自动复制，与 V0 一致。
- 「重发录音」仍走 bulk 发送逻辑，不按录音时长做实时重放。
- 救援保证：只要已录过音（本地音频文件存在），「保存音频」与「重放音频」就始终可用，不被 `transcribing`/转写卡死状态锁死。这是转写卡住时的抢救手段——「重放音频」会关闭当前（可能已挂死的）WebSocket 会话，用已落盘的音频重新转写一遍。

### V1 明确不做

- 不在 V1 引入转写模型选择 UI（可沿用 Settings 固定模型或后续再加）。
- 不改变 OpenCode 可选发送路径的定位。
- 不把 OpenCode 发送改成 stream prompt（仍发送最终 transcript 文本）。

### V1 成功标准

- 真机/模拟器上 Stop 后 1s 内通常能看到首个 stream 文本（网络正常时）。
- 录音过程中 audio chunk 持续发送，Stop 只触发 finalize，不阻塞在本地编码整段 WAV。
- partial transcript 在 disconnect/error 时不 silently 丢失；history/clipboard 在成功完成时仍自动更新。
- 有单元测试覆盖 WebSocket message parsing、append/replace 逻辑、chunk 发送边界；集成测试可用 mock WebSocket。

## 用户

第一类用户是高频使用语音输入的人。他们需要把口述内容快速变成可粘贴文本，并且希望工具忠实转写，不擅自进行问答、总结或润色。

第二类用户是跨设备工作的人。他们希望在 iPhone、iPad 或 Vision Pro 上完成语音识别后，通过 Universal Clipboard 在 Mac 上直接粘贴。

第三类用户是 OpenCode 用户。他们希望在需要时把转写文本发送给 OpenCode，但这只是可选路径。

第四类用户是 iPhone 重度快捷操作用户。他们可以通过 Shortcut、Action Button 或桌面快捷方式打开 `voiceflow://record`，直接开始录音。

## 平台

V0 支持 iOS、iPadOS 和 visionOS。三端共享 SwiftUI 代码和业务逻辑，视觉布局优先保持简单一致。visionOS 先采用窗口式表单和录音界面，不做空间化交互。

## V0 功能范围

应用只有两个 tab。

Record tab 包含开始录音、停止录音、录音状态、转写文本显示、自动复制到剪贴板、左右 chevron 浏览最近历史、手动复制文本、三点菜单中的保存录音与重发录音。用户配置 OpenCode 并通过连接测试后，Record tab 额外显示发送到 OpenCode 的入口。历史只保存在本机，默认保留最近 5 条。

Settings tab 包含 AI Builder Space API token 输入、保存状态、连接测试结果和默认 endpoint 说明。endpoint 固定为 AI Builder Space 默认地址，不提供编辑入口。Settings 还包含可选 OpenCode 配置（server URL、username、Keychain password）；清除操作只删除 password，URL 和 username 保留。OpenCode 连接测试失败时展示具体错误信息。

Settings tab 包含语言偏好：System、English、简体中文；默认 System。iOS / iPadOS 外观偏好（System / Light / Dark）列入 V0 范围但尚未实现。visionOS native build 不需要这个偏好 —— visionOS 系统没有 Light/Dark 概念（Settings → Appearance 里那条 Light/Dark 只对 Compatible Apps，即 iPad/iPhone compatibility 模式有效）。

Deep link：`voiceflow://record` 已注册。打开 app 后切到 Record tab 并复用现有开始录音流程；不接受 token、文本或其他外部 payload。

## 明确不做

V0 不包含文档编辑器、自动修正按钮、自定义 prompt 按钮、转写模型选择、Apple Watch app、网页登录、账号系统、云端历史同步、录音库长期管理和复杂工作流编排。

菜单中的「保存录音」是把最近一次录音导出到 app Documents（`recording_yyyy-MM-dd_HH-mm-ss.wav`），并在 Files → 我的 iPhone → VoiceFlow 中可见；不是内置录音库。保存后弹窗说明文件名与 Files 路径（iOS 无法一键跳转到该目录）。Deep link 只服务于直接开始录音，不扩展成通用自动化接口。

## 用户流程

首次启动时，用户进入 Settings，粘贴 AI Builder Space API token，点击 Test Connection。验证通过后回到 Record。OpenCode 配置可以跳过。语言默认跟随系统；用户可在 Settings 切换 English 或简体中文。

日常使用时，用户点击 Start Recording。应用请求麦克风权限，显示录音状态并采集音频。V0：用户点击 Stop 后上传整段 WAV 并等待转写。V1（规划）：Start 后即将音频分片 stream 到服务端，Stop 只发送 finalize 控制消息并继续接收 text stream，转写区随服务端推送增量更新。

用户可以手动复制文本；配置 OpenCode 并通过连接测试后，可发送到 OpenCode。发送成功或失败都有明确状态，文本和剪贴板内容保留。

用户可用左右 chevron 在最近 5 条转写间切换；三点菜单可保存 WAV 到 Documents 或重发最近一次录音做转写。保存后 app 弹窗告知文件名，并指引用户在 Files app 中进入 On My iPhone → VoiceFlow 查找。

快捷启动：在 Shortcuts 中创建「打开 URL」动作，地址填 `voiceflow://record`，绑定到 Action Button 或主屏幕。token 缺失或麦克风不可用时显示本地化错误，不静默失败。

## 双语要求

App UI 默认使用系统语言。用户可在 Settings 中手动选择 English 或简体中文。所有用户可见字符串进入本地化资源，不硬编码在 SwiftUI view 中。

## 外观要求

iOS / iPadOS 当前跟随系统日间/夜间模式。visionOS native build 没有这一回事 —— visionOS 系统没有 Light/Dark 切换（Settings → Appearance 里的 Light/Dark 只针对 Compatible Apps，即 iPad/iPhone compatibility 模式，对 native visionOS target 无效），app 在 visionOS 上 pin 到 Light 配色，与 Vision Pro glass UI 一致。计划中的 iOS Settings 外观偏好（System / Light / Dark）尚未实现；落地后 Record 和 Settings 应使用语义颜色，保证浅/深模式下对比度足够。

## 录音诊断要求

录音失败需要能定位阶段：权限、录音启动/停止、空音频、上传转写、响应解析、自动复制、OpenCode 发送。诊断日志只记录安全摘要，不记录 token、转写文本、音频内容或原始 API 响应。

## 安全与隐私

API token 与 OpenCode password 存在 Keychain。OpenCode server URL 和 username 存在 UserDefaults。仓库只包含 fake 配置示例。

转写走 AI Builder Space；OpenCode 发送前用户能看到当前文本。deep link 不携带外部 payload。

## 发布要求

代码、文档、测试按可公开发布标准维护。公开仓库：`grapeot/voiceflow`，默认分支 `master`。

## 成功标准

V0 完成条件：iOS / visionOS 模拟器可构建；Record / Settings 可运行；token Keychain 保存与连接测试；录音转写与自动复制；历史导航与保存/重发；OpenCode 可选且 gating 正确；语言偏好；隐私扫描无真实凭据；deep link 可用并有单元测试。外观手动选择为剩余项。

V1 完成条件（规划）：WebSocket 实时 audio stream + incremental transcript display；Stop 后亚秒级开始出字；failure recovery 与 bulk resend 行为符合 PRD V1 章节；batch HTTP 转写路径可保留为 fallback 或移除（实现阶段决定）。
