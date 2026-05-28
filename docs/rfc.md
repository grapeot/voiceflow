# VoiceFlow RFC

## 设计判断

VoiceFlow 的主路径是语音输入。V0 把录音、转写、自动复制、最近历史、可选 OpenCode 和 deep link 启动录音做可靠。OpenCode 不能阻塞语音输入主流程。

实现采用 SwiftUI + AVFoundation + URLSession + Security.framework，不引入第三方依赖。iOS、iPadOS 和 visionOS 共用 SwiftUI 代码和业务逻辑。

录音/转写底层 pipeline 从 2026-05-28 起抽到独立 SPM package `VoiceFlowKit`，住在同 repo 根目录（monorepo）。VoiceFlow app 通过本地 SPM 依赖引用 Kit。OpenCode iOS Client 等其他客户可通过远程 SPM 引用同一 GitHub repo（`https://github.com/grapeot/voiceflow.git`）拿 `VoiceFlowKit` product。Kit 的[生成内核](https://yage.ai/ai-software-engineering.html)定位、边界、给 AI 集成方的完整指南见 `skills/adding_voice_input_with_voiceflowkit.md`；本 RFC 只描述应用层结构。

公开仓库：https://github.com/grapeot/voiceflow（`master`）。

## 模块划分

仓库根作为 SPM package root；同时承载 VoiceFlow app 的 Xcode 工程。

```text
voiceflow/                       # repo root
  Package.swift                  # VoiceFlowKit SPM 入口
  Sources/VoiceFlowKit/
    VoiceFlowKit.swift           # 版本常量
    VoiceFlowConfig.swift        # 公开配置
    VoiceFlowClient.swift        # 公开 actor，入口
    VoiceFlowSession.swift       # 公开 actor，realtime 会话
    VoiceFlowMicrophone.swift    # 公开 mic 封装（iOS/visionOS only）
    VoiceFlowError.swift         # 公开 typed errors
    StreamCaption.swift          # 公开 caption 双层模型 + StreamCaptionStore
    Resources/PrivacyInfo.xcprivacy
    Internal/
      RealtimeTranscriptionClient.swift  # WS pipeline 主体
      RealtimeTranscriptEvent.swift      # 事件、错误、config 常量、URL builder、PCM writer
      RealtimeWebSocketSender.swift
      AudioRecorder.swift                # mic tap → PCM16 24kHz mono
      AudioChunkEncoder.swift            # PCM 分片 + 磁盘 cache
      AIBuilderClient.swift              # health endpoint test
      AIBuilderTranscriptionClient.swift # 一次性 transcribe
  Tests/VoiceFlowKitTests/
    VoiceFlowKitSanityTests.swift
    PublicFacadeSmokeTests.swift
    BulkProgressRegressionTests.swift  # PR #34 race coverage
  src/VoiceFlow/                 # app Xcode 工程
    VoiceFlow.xcodeproj          # 通过 ../.. 本地 SPM dep 引 VoiceFlowKit
    VoiceFlow/
      VoiceFlowApp.swift         # 根视图、onOpenURL、语言 bundle
      AppState.swift             # 状态字段、init/reset、recording lifecycle、deep link
      AppState+LiveSession.swift # session bridge、event consumer、heartbeat、bulk fallback
      AppState+OpenCode.swift    # OpenCode 密码、连接测试、send
      AppState+Diagnostics.swift # recordDiagnostic / 错误元数据格式化
      AppState+AIBuilderToken.swift # AI Builder token 存取与连接测试
      AppState+RecordingFiles.swift # 文件持久化、saveCurrentRecording
      AppState+StreamCaption.swift  # caption 双层状态机
      AppState+RecordingTimer.swift # 录音 elapsed timer
      AppState+TranscriptHistory.swift # copy、prev/next 导航
      Views/
        MainTabView.swift
        RecordView.swift
        SettingsView.swift
        Components/
          ColoredButtonStyle.swift
          KeyboardDismissOnTap.swift
          RecordingStatusHeaderView.swift
          RecordingTimerView.swift
      Models/
        AppLanguage.swift
        ConnectionStatus.swift
        DeepLink.swift
        OpenCodeSendStatus.swift
        RecordingTimerFormatter.swift
        TranscriptHistory.swift
        SavedRecordingInfo.swift
      Services/
        ClipboardService.swift
        KeychainStore.swift
        OpenCodeClient.swift     # VoiceFlow 专属"send to OpenCode"，不进 Kit
        RecordingDiagnostics.swift
        RecordingFileSaver.swift
      Resources/
        en.lproj/ / zh-Hans.lproj/
        Assets.xcassets
      URLScheme.plist
    VoiceFlowTests/              # 单元测试（Swift Testing，覆盖 app 行为）
    VoiceFlowUITests/            # UI 测试（XCUITest，-uiTestMode）
  scripts/test_unit.sh / test_ui_smoke.sh / test_ui_full.sh / test_ui_perf.sh / test_all.sh
```

`AppState` 通过 `import VoiceFlowKit` 持有 `VoiceFlowClient`（facade）实例。Live session 通过 `voiceFlowClient.startSession()` 拿到 `VoiceFlowSession`，事件通过 `session.events` AsyncStream 在 `AppState+LiveSession.swift` 里 drain；bulk 重发通过 `voiceFlowClient.transcribe(audioFile:)`；连接测试通过 `voiceFlowClient.testConnection()`。这是 PR #38 之后的状态 —— kit 内部 protocol（`RealtimeTranscribing` / `RealtimeConnectionPhase` / `AudioChunkEncoder` 等）已收回 internal，**只有** facade 是对外公开的稳定接口。

UI test 路径走 `VoiceFlowClient.makeStub(...)`（PR #38 新增的 public factory）：返回 offline client，commitAndStop 直接 emit `connected → idle` 并返回 canned 文本，不开真 WebSocket。Unit test 里如果要细粒度脚本化事件序列（emit recoveryFailed、setBulkResult mid-test），通过 `@testable import VoiceFlowKit` 拿到 internal init `VoiceFlowClient(config:, transcriber:)` 注入自己造的 mock，见 `VoiceFlowKitTestHelpers.swift`。

`AppState` 保存跨页面状态：录音状态、transcript、历史索引、tab 选择、token/OpenCode 配置与连接状态、剪贴板/OpenCode 发送状态、语言偏好、转写上下文（prompt / terms）、deep link 待处理标志。PR #40 之后 AppState 主文件从 1098 行降到 493 行，行为按职责拆到 7 个同型 extension（`AppState+LiveSession` / `+OpenCode` / `+Diagnostics` / `+AIBuilderToken` / `+RecordingFiles` / `+StreamCaption` / `+RecordingTimer` / `+TranscriptHistory`）。State 字段留在主类（SwiftUI 视图直接 bind `@Published` 投影），extension 只搬行为。

录音、API、剪贴板、Keychain 现在分两层：底层 audio/WS pipeline 在 `VoiceFlowKit`（SPM package），上层 app 业务行为在 `src/VoiceFlow/VoiceFlow/Services/`（Clipboard、OpenCode HTTP relay、RecordingDiagnostics、KeychainStore、RecordingFileSaver）。UI 不直接碰系统接口。

语言偏好、转写 prompt 与 terms 用 `UserDefaults`。AI Builder token 与 OpenCode password 只进 Keychain。OpenCode server URL 与 username 进 UserDefaults；清除 OpenCode 只删 password。

## VoiceFlowKit 公开 API

下面是 `VoiceFlowKit` 暴露给 host（VoiceFlow app 和未来的 OpenCode iOS Client）的 surface：

- `VoiceFlowClient`（actor）：入口。`init(config: VoiceFlowConfig)`，提供 `startSession()` / `transcribe(audioFile:onPartialTranscript:)` / `testConnection()` / `updateConfig(_:)`。
- `VoiceFlowSession`（actor）：实时会话句柄。`sendAudioChunk(_:)` 推 PCM，`ping()` 心跳，`commitAndStop(onPartialTranscript:)` 收口，`cancel()` 取消，`connectionPhase`（VoiceFlowConnectionPhase）读相位，`events`（AsyncStream<VoiceFlowEvent>）订阅事件。
- `VoiceFlowMicrophone`（class，iOS/visionOS only）：mic 封装。`requestPermission()` / `start(onPCMChunk:)` / `stop()` / `discard()`，`audioLevel`（AsyncStream<Float>）暴露 0..1 RMS。
- `VoiceFlowConfig`（struct）：`endpoint` / `tokenProvider` / `model` / `prompt` / `terms` / `loggerSubsystem`。注意：**没有** `language` 字段——backend 把语言提示当 prompt 拼接，用户自己在 prompt 里写。
- `VoiceFlowError`（enum）：`invalidEndpoint` / `missingToken` / `httpError(statusCode:)` / `sessionUnavailable` / `websocketError(_)` / `connectionLost(_)` / `audioConversionFailed` / `emptyTranscript` / `microphoneUnavailable` / `underlying(_)`。
- `StreamCaption` / `StreamCaptionStore`：双层 caption 模型（persistent + transient 3 秒闪现），数据结构层、不画 UI。

PR #38 之后，**只有** 上述 facade 类型对外公开。原本为 app 兼容而暴露的 `RealtimeTranscribing` / `RealtimeConnectionPhase` / `RealtimeTranscriptEvent` / `RealtimeTranscriptionError` 等 Internal 类型已收回 internal，不再属于 stable API。例外是 `AIBuilderConnectionTesting` / `AudioRecording` / `AIBuilderTranscribing` 三组 protocol + 实现 + Mock 仍为 public —— 它们承担 UI test 时的 DI 注入面（`VoiceFlowMicrophone` 是 `final class` 不可 mock，host 想 mock 录音得不到注入点，这是务实妥协）。

PR #38 同时新增 `VoiceFlowClient.makeStub(config:, liveTranscript:, bulkTranscript:)` public factory，作为 facade 一等公民的 stub mode：app 的 UI test launch flag 直接构造一个 stub client，行为完整（emit `connected → idle`、`commitAndStop` 返回 canned 文本）但不开 WebSocket。OpenCode 以后也能用。

## 转写上下文（prompt + terms）

Settings → Transcription 分组让用户设置两个值：

- **Context prompt**：自由文本，跟随每个 session.create 请求的 POST body 一起发到 backend，作为模型的上下文提示。
- **Terms**：英文逗号分隔的字符串，app 层 split + trim 后变 `[String]` 传给 `VoiceFlowConfig.terms`，库内部塞进 session.create payload 的 `terms` 字段。

两值都 UserDefaults 持久化。空字符串和纯空白 trim 后视为未设置，wire 上不出现这个 key。

详细 wire 格式：

```http
POST {endpoint}/v1/audio/realtime/sessions
Authorization: Bearer {token}
Content-Type: application/json

{
  "model": "gpt-realtime",
  "vad": false,
  "silence_duration_ms": 1200,
  "prompt": "...optional...",
  "terms": ["...", "..."]
}
```

库内部用 `RealtimeSessionContext` 结构传递这两个值，覆盖 `transcribeBulkPCM` 和 `beginLiveSession` 两条路径。OSLog 里 `session.create model=... hasPrompt=true promptChars=N termsCount=M` 可作 wire 诊断。

**模型 prompt-following 行为**：`gpt-realtime` 对纯指令型 prompt 反应弱，对"指令 + Example"形态响应强。Settings placeholder 已经体现这一点。详见 `skills/adding_voice_input_with_voiceflowkit.md` 的"接下来"段。这是模型行为不是 library 问题。

## 鉴权模型

AI Builder Space 使用 Bearer token，写入 Keychain，请求带 `Authorization: Bearer <token>`。token 不进日志或错误文案。

OpenCode 使用 Basic Auth。远程 server 必须 HTTPS；localhost、loopback 与 Tailscale（`*.ts.net`）允许 HTTP（`OpenCodeClient` 校验 + `URLScheme.plist` 中 `NSAppTransportSecurity` 对 `ts.net` 开 `NSIncludesSubdomains` / `NSExceptionAllowsInsecureHTTPLoads`，对齐 brainwave iOS）。拒绝 URL user-info。

OpenCode 发送前须保存配置且连接测试通过（`openCodeConnectionStatus == .success`）。

## Endpoint 策略

固定 AI Builder base：

```text
https://space.ai-builders.com/backend
```

转写：`POST /v1/audio/transcriptions`（multipart `audio_file`）。UI 不提供 endpoint 编辑。

## GUI

Record：顶部 VoiceFlow 标题 + 状态灯、录音计时（`MM:SS`）、控制区（左/右历史、Start/Stop 宽 120pt、保存/重发菜单）、大文本区、底部 Copy 与 Send to OpenCode（旁有 info 按钮）。

Settings：表单式 AI Builder token、只读 endpoint、OpenCode URL/username/password、连接测试与失败 detail、语言 segmented picker。点击文本框外收起键盘。

## 转写方案

### V0（已交付）：录完上传

48 kHz PCM16 mono WAV → 停止录音 → multipart `POST /v1/audio/transcriptions` → 完整文本写入 transcript 与历史 → 自动复制。

### V1（已交付）：WebSocket 实时 stream

目标：边录边发，Stop 只 finalize，文本随服务端 push 增量显示。主录音路径已从 V0 batch HTTP 切换为 WebSocket stream；`AIBuilderTranscriptionClient` 保留供 HTTP 单测与潜在 fallback，重发录音走 bulk WebSocket。

#### 协议与会话

```text
POST https://space.ai-builders.com/backend/v1/audio/realtime/sessions
Authorization: Bearer <token>

→ wss://space.ai-builders.com/backend/v1/audio/realtime/ws?ticket=<ticket>
  # WebSocket 升级不带 Bearer；ticket 来自上一步 HTTP 响应
```

默认 model：`gpt-realtime`（常量 `RealtimeTranscriptionConfig.defaultModel`）。

控制消息（JSON text frame，Student Portal realtime API）：

| type | 方向 | 含义 |
|---|---|---|
| `start` | client → server | 开始 live 段，可带 `model` / `vad` |
| `commit` | client → server | 提交已发送音频，请求 finalize |
| `stop` | client → server | 结束 realtime session |
| `session_ready` | server → client | WS 已就绪 |
| `transcript_delta` | server → client | 增量转写（`text` 字段） |
| `transcript_completed` | server → client | 一轮完整转写 |
| `session_stopped` | server → client | 会话结束 |
| `error` | server → client | 错误文案 |

音频（binary frame）：24 kHz PCM16 mono，按 ~0.5s（`chunkByteSize` = 24000 bytes）分片；Stop 时 flush 剩余 buffer → `commit` + `stop`。bulk 重发创建 session 时 `vad: false`，发完音频后 `commit` + `stop`。

#### 客户端模块

```text
Models/
  RealtimeTranscriptEvent.swift     # event / status / config / message parser / WAV helper
Services/
  RealtimeTranscriptionClient.swift # session + live handle + recovery coordinator
  RealtimeWebSocketSender.swift     # 串行 send 队列（对齐 OpenCode）
  AudioChunkEncoder.swift             # chunk 聚合 + AudioChunkCache 磁盘缓存
  AudioRecorder.swift               # AVAudioEngine tap 流式 PCM + stop 写 WAV
```

核心恢复机制（对齐 OpenCode iOS `RealtimeSpeechStreamer` + brainwave pending buffer）：

1. **AudioChunkCache**：所有 PCM 写入临时磁盘文件；断线后可从 offset 0 重放。
2. **RealtimeLiveSessionHandle**（actor）：
   - `appendAudioChunk`：先写 cache，再 send；send 失败 → `recover()`。
   - `recover()`：cancel 旧 session → 新建 ticket session → `start` → `replayCache` bulk 发送（20ms 轮询等待新数据，不按时序 sleep 模拟麦克风）。
   - `heartbeat()`：WebSocket ping；失败触发 recover。
   - `finalize()`：flush send 队列 → `commit` + `stop` → 等待 `session_stopped`（映射为 `status: idle`，30s 超时）；失败时 recover 后重试。
3. **isRecovering 门闩**：恢复期间暂停 live send，避免与 replay 交错。

`AppState` 集成（转写 UI 对齐 OpenCode iOS）：

- Start：`beginLiveSession`（非阻塞 WS）→ `AudioRecorder.startRecording` → `AudioChunkEncoder` → session.append；WS attach 在后台 Task；`transcript` 保持空，忽略录音/recover 期的 `transcript_delta`。
- Stop：stop mic → persist WAV → flush encoder → `session.finalize`（等待 recover）→ 仅在 finalize 阶段应用 WS 转写与 partial 回调 → history + clipboard。
- `streamConnectionPhase` 驱动状态灯：connected=绿、recovering/connecting/generating=橙、disconnected=红。
- 剪贴板：stream 期间 throttle（1s、同 hash 跳过）。
- Scene：background cancel session；active heartbeat。
- Resend：`PCM16WAVWriter.readPCM` → `transcribeBulkPCM`（同 WebSocket 协议，无实时 sleep）。

#### Failure recovery 矩阵

| 场景 | 检测 | 行为 | partial transcript |
|---|---|---|---|
| send/ping 失败 | URLSession 错误 | recover + 指数退避重试 + replay cache | UI 不更新；仅 caption |
| receive disconnect | receive 失败 / `.disconnected` | 录音中 recover；finalize 中断开：等待 recover 后重试 | UI 不更新 |
| Start 时 socket 慢 | session nil | mic/cache 先启动，deferred attach；cache 累积后 bulk 重放 | N/A |
| server `error` | JSON type=error | 录音中：caption only（无 modal）；phase→disconnected | 保留 |
| recover 持久失败 | 重试耗尽 `.recoveryFailed` | caption `record.error.streamDisconnected`；录音继续 | 保留 |
| finalize 超时/失败 | 30s 无 idle / 错误 | 若有 partial：ready + caption（无 modal）+ history/clipboard | 保留 |
| 正常 idle | status idle | history + auto copy（>3 字符） | 最终文本 |
| Resend | bulk 完成 idle | 同 V0 历史/clipboard | 替换为 bulk 结果 |
| Background | scenePhase | cancel session；回前台需重新录音 | 保留 |

#### UI

- 转写区 `TextEditor` 仅在 Stop 后 transcribing/finalize 阶段随 text delta 更新；录音与 recover 期间不消费 WS 转写（`RealtimeLiveSessionHandle.shouldNotifyUI` + `AppState` 双门闩）。
- 状态灯：connected=绿、recovering/connecting/generating=橙、disconnected=红。
- 录音中 transient 问题：caption `record.status.reconnecting` 或 `record.error.streamDisconnected`（非 modal）。

#### 测试

- 单元（`RealtimeTranscriptionTests` + 既有 AppState tests）：message parse、delta reducer、chunk 边界、WAV roundtrip、mock live session。
- UI spec（未默认执行）：mock stream 断言 indicator 颜色与 transcript 增长；见 `VoiceFlowUITests.testMockStreamingRecordingUpdatesTranscript`.

#### 与 V0 关系

主路径已切 V1 WebSocket。HTTP batch client 仍存在于 codebase 供测试/fallback 参考，不再用于 Record Stop 主流程。

## Record Tab 状态机

```text
idle -> requestingPermission -> recording -> transcribing -> ready
ready -> (start again) -> requestingPermission -> ...
```

录音错误通过 alert 展示（`recordErrorAlertKey`），`recordingStatus` 回到 `idle`。OpenCode 发送状态独立为 `OpenCodeSendStatus`，不并入录音状态机。

历史：`TranscriptHistory` index 0 为最新；`navigatePrevious` 更旧，`navigateNext` 更新。录音完成后持久化 `last-recording.wav`（Application Support）供保存到 Documents 与重发转写。

保存录音：`RecordingFileSaver` 把 `last-recording.wav` 复制到 Documents，文件名 `recording_yyyy-MM-dd_HH-mm-ss.wav`。`URLScheme.plist` 启用 `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`，使 Files → On My iPhone → VoiceFlow 可见。保存成功弹窗告知文件名与 Files 路径；iOS 无公开 API 可 deep link 到该目录，不提供文件预览或分享面板。标题下方 caption 保留路径提示。

## 录音诊断

`RecordingDiagnostics`（OSLog 或可注入 mock）在 token、权限、录音启停、音频大小、转写、剪贴板、OpenCode、deep link 等节点记安全摘要。单元测试断言不含 token/transcript。

## 剪贴板

转写成功后自动写入系统剪贴板；失败保留 transcript 并提示，可手动 Copy。

## OpenCode 发送

创建 session → `prompt_async` 发送 transcript。未配置时不阻塞主路径。Settings 可测试连接；失败显示 `ConnectionStatus.detail`。

## Settings Tab

必需：AI Builder token、Test Connection、只读 endpoint。

可选：OpenCode URL/username/password；Clear 只清 password。

已实现：语言 System / English / 简体中文。

未实现：外观 System / Light / Dark（仍跟随系统 color scheme）。

## 本地化

`en.lproj` 与 `zh-Hans.lproj`。运行时语言通过显式 bundle lookup；model 存 localization key 而非已翻译字符串。

## Deep Link

已实现 URL scheme `voiceflow`，入口 `voiceflow://record`。

`VoiceFlowApp` 根视图 `.onOpenURL` → `AppState.handleIncomingURL` → 切 Record tab → `consumePendingDeepLinkStartRecordingIfNeeded()` → `startRecording()`。未知 host/path 忽略；query 不使用。配置见 `URLScheme.plist` 与 README Shortcuts 说明。

## 数据保留

历史最多 5 条 transcript。临时 WAV 转写后清理；最近一次保留在 Application Support 供保存/重发。剪贴板不单独持久化。

## 错误处理

用户可见错误为本地化 key；连接失败可带 detail。诊断日志不含敏感内容。

## V0 交付清单

| 项 | 状态 |
|---|---|
| Record / Settings GUI 对齐 | 已完成 |
| 录音诊断日志 | 已完成 |
| 语言偏好 | 已完成 |
| 外观偏好（Light/Dark 手动） | 未实现 |
| Privacy review | 已完成 |
| GitHub `grapeot/voiceflow` | 已完成 |
| Deep link `voiceflow://record` | 已完成 |
| OpenCode 连接测试 gating / Tailscale HTTP | 已完成 |
| 历史双向导航、保存/重发菜单 | 已完成 |
| 录音计时 + Start/Stop 120pt | 已完成 |

后续优先：V1 WebSocket 实时转写（见 PRD/RFC V1 章节）；外观偏好；UI test suite 稳定跑通。

## 验证要求

日常：

```bash
./scripts/test_unit.sh
```

发布前或改 UI 后：

```bash
./scripts/test_all.sh
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO build
rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .
```

变更记录写 `docs/working.md`。

## 后续可选

- V1 WebSocket 实时转写（PRD/RFC 已写设计）
- Settings 外观偏好
- App Store 视觉截图自动化
- UI tests 在 CI 中默认可靠通过
