# Skill: 给 iOS / visionOS App 加语音输入（用 VoiceFlowKit）

VoiceFlowKit 是一个 Swift Package，把"麦克风录音 + 实时转写"封装成几个 actor 类型。把它加进任何 iOS 17+ / visionOS 1+ app 后，你能在 ~50 行代码内得到一个能录音、能拿到逐字 partial transcript、能在停止时返回最终文本的语音输入组件。Backend 走 wss 到 AI Builder Space（OpenAI gpt-realtime），需要一个 token。

## 元数据

- **类型**: API Guide / Tutorial
- **适用场景**: 想在 iOS / visionOS app 里加"按住说话 → 出文字"或"按一下开始录音 / 再按一下停止 → 出文字"的功能
- **依赖**: SPM `https://github.com/grapeot/voiceflow.git`（公开 repo），minimum platforms iOS 17 / visionOS 1
- **不适用**: 离线转写（VoiceFlowKit 一律走 WebSocket）、非实时长录音批处理（虽然 `transcribe(audioFile:)` 能跑短文件，但 V0 只支持 WAV 输入）、macOS host（mic capture 没编译进 macOS target）
- **更新日期**: 2026-05-28

## 这个 skill 让你完成什么

读完之后，你能给一个现有的 SwiftUI app 加一个 "voice input" 组件，达成：

1. 用户在 Settings 里填一个 AI Builder Space token（你负责存 Keychain，库不管）
2. 录音 UI 上有一个 button：第一次按 → 开始录音 + 显示 partial transcript（每个新词出来就更新）；第二次按 → 停止录音 + 等几秒拿到 final transcript
3. 转写文本流向你的 textfield 或聊天 input

整个组件应该 ≤200 行 Swift 代码（不算 UI 样式）。如果你写到 500 行还没跑通，说明走偏了 —— 看下面的"参考实现"对照。

## Package 的形状

只有一个 product：`VoiceFlowKit`。它对外暴露这几个 actor / struct（所有都在 `import VoiceFlowKit` 之后可见）：

| 类型 | 干什么 |
|---|---|
| `VoiceFlowConfig` | endpoint + token 闭包 + 可选 prompt/terms。一个 config = 一次 session 的参数 |
| `VoiceFlowClient` | actor。`config` 给它 → 它给你 `VoiceFlowSession` 或一次性 `transcribe(audioFile:)` 调用 |
| `VoiceFlowSession` | actor。一次 live 录音会话。`sendAudioChunk` 喂 PCM、`ping` 保活、`commitAndStop` 拿 final 文本、`cancel` 中止并清理缓存、`abortPreservingAudio` 中止但保留已录 PCM；`events` 是 AsyncStream 拿 partial transcript 和连接相位 |
| `VoiceFlowPreservedAudio` | `abortPreservingAudio()` 返回的轻量句柄。公开 `id` / `byteCount`，可交给 `VoiceFlowClient.transcribe(preservedAudio:)` 重试识别，完成后用 `discardPreservedAudio` 清理 |
| `VoiceFlowMicrophone` | `@MainActor` final class。录音入口：`requestPermission` → `start(onPCMChunk:)` → `stop()`。给你的 onPCMChunk 闭包推 PCM16 24kHz mono chunk，你直接转给 session |
| `VoiceFlowEvent` | enum：`.partialTranscript(String)` / `.phaseChanged(VoiceFlowConnectionPhase)` / `.recoveryStarted` / `.recoveryFailed(message:)` |
| `VoiceFlowConnectionPhase` | enum：`.connecting / .connected / .recovering / .generating / .disconnected` |
| `VoiceFlowError` | enum：`.missingToken / .invalidEndpoint / .httpError / .sessionUnavailable / .websocketError / .connectionLost / .emptyTranscript / .microphoneUnavailable / .audioConversionFailed / .underlying(String)` |
| `VoiceFlowClient.makeStub(...)` | static factory。返回一个不开 WebSocket 的 stub client，行为完整（会 emit `connected → idle`、`commitAndStop` 返回 canned 文本）。给 UI test launch mode 和 SwiftUI Preview 用 |

工作模式只有两种：

- **Live streaming**（推荐，默认）：`client.startSession()` → 边录音边收 partial → `session.commitAndStop()` 拿 final。Latency 低，体验好。
- **Bulk**：`client.transcribe(audioFile: someWAV)` 一次性传一个 WAV 文件。VoiceFlow app 内部用它做"resend" —— 网络断了之后拿持久化的录音重传。
- **Preserved retry**：live session 卡住或用户主动终止时，`session.abortPreservingAudio()` 关闭 WebSocket 但保留 session 内部磁盘 PCM；之后 `client.transcribe(preservedAudio:)` 用同一段 PCM 重新识别，host 不需要自己复制 mic chunk。

## 集成步骤

### 1. 在 Xcode 加 SPM 依赖

File → Add Package Dependencies → URL `https://github.com/grapeot/voiceflow.git`。Dependency rule 选 `branch: master`（还在快速迭代，没打 SemVer tag）。勾选 `VoiceFlowKit` product，加到 app target。

如果你的 repo 在 Xcode Cloud 跑 CI，确保 `<your-project>.xcworkspace/xcshareddata/swiftpm/Package.resolved` 是被 git track 的 —— Xcode Cloud 关闭了自动依赖解析，必须有 lockfile。如果 `.gitignore` 里有 `Package.resolved`，改成 `/Package.resolved`（只忽略根目录）。

### 2. Info.plist 加麦克风权限

加 `NSMicrophoneUsageDescription`，描述简洁说明用途，例如："App uses the microphone to record voice input, which is transcribed to text."

如果走 INFOPLIST_KEY_ 系统：build settings 里加 `INFOPLIST_KEY_NSMicrophoneUsageDescription = "..."` 到 Debug + Release 两个 config。

如果想 TestFlight 上传时跳过 export compliance 提示：再加 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`。App 用的 HTTPS / Keychain 都是 OS 提供的，没自带加密原语。

### 3. 写一个 client factory

把 token、endpoint、prompt、terms 包成 `VoiceFlowConfig`，再构造 `VoiceFlowClient`。Token 默认从你 app 自己的 Keychain 或 Settings 里读。

```swift
import VoiceFlowKit

private func makeVoiceFlowClient() throws -> VoiceFlowClient {
    let token = aiBuilderToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw VoiceFlowError.missingToken }

    let endpoint = VoiceFlowConfig.defaultEndpoint // 或你自己的 base URL

    let config = VoiceFlowConfig(
        endpoint: endpoint,
        tokenProvider: { token },
        prompt: customPrompt.isEmpty ? nil : customPrompt,
        terms: termList   // [String]，逗号或分隔输入解析后
    )
    return VoiceFlowClient(config: config)
}
```

`tokenProvider` 是 `@Sendable () async throws -> String`。如果你想每次都重新从 Keychain 读（让用户清 token 时立刻生效），让闭包自己读 keychain；如果你希望整个 session 用同一个 token snapshot，让闭包闭包到一个本地变量（推荐）。

### 4. 写录音 + 转写主流程

最小版本（适合 chat composer 类 UI）：

```swift
@State private var microphone = VoiceFlowMicrophone()
@State private var session: VoiceFlowSession?
@State private var partialTranscript: String = ""
@State private var heartbeatTask: Task<Void, Never>?

func startRecording() async throws {
    guard await microphone.requestPermission() else {
        throw VoiceFlowError.microphoneUnavailable
    }
    let client = try makeVoiceFlowClient()
    let session = try await client.startSession()
    self.session = session

    // 1) 起一个 task 消费 partial transcript + 连接相位变化
    Task {
        for await event in await session.events {
            switch event {
            case .partialTranscript(let text):
                await MainActor.run { partialTranscript = text }
            case .phaseChanged(let phase):
                // 可选：根据 phase 改 UI（"connecting…"、"recovering…"）
                _ = phase
            case .recoveryStarted, .recoveryFailed:
                // 可选：UI hint "stream blip, retrying"
                break
            }
        }
    }

    // 2) Mic 把 PCM chunk 喂给 session
    try await microphone.start { chunk in
        Task { await session.sendAudioChunk(chunk) }
    }

    // 3) 12 秒心跳保活（避开 WS idle timeout）
    heartbeatTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(12))
            await session.ping()
        }
    }
}

func stopRecording() async -> String? {
    heartbeatTask?.cancel(); heartbeatTask = nil
    _ = try? await microphone.stop()
    guard let session else { return nil }
    self.session = nil
    do {
        return try await session.commitAndStop { partial in
            Task { @MainActor in partialTranscript = partial }
        }
    } catch {
        await session.cancel()
        return nil
    }
}
```

这 ~50 行就是核心。Session 的 `events` 是冷 AsyncStream —— 必须在 mic 开始前 / 开始时起一个 Task 去消费，否则 partial transcript 会被丢。

如果你的 host UI 需要一个"强制终止语音识别 / 重试上一段录音"按钮，使用 preserved retry，不要在 app 侧重复缓存音频 chunk：

```swift
@State private var preservedAudio: VoiceFlowPreservedAudio?

func abortSpeechRecognition() async {
    heartbeatTask?.cancel(); heartbeatTask = nil
    _ = try? await microphone.stop()
    guard let session else { return }
    self.session = nil
    preservedAudio = try? await session.abortPreservingAudio()
}

func retryPreservedAudio() async -> String? {
    guard let preservedAudio else { return nil }
    let client = try! makeVoiceFlowClient()
    defer {
        Task { await client.discardPreservedAudio(preservedAudio) }
        self.preservedAudio = nil
    }
    let result = try? await client.transcribe(preservedAudio: preservedAudio)
    return result?.text
}
```

### 5. UI test mode 用 stub client

你的 UI test launch arguments 里通常会塞个 `-uiTestMode` flag。检测到这个 flag 时，把 prod 的 `VoiceFlowClient(config:)` 换成 `VoiceFlowClient.makeStub(...)`。Stub 不开 WebSocket，`commitAndStop` 直接返回 `liveTranscript` 参数指定的文本，`events` 也会按 `connected → idle` 顺序 emit。UI test 跑得快，不依赖网络。

```swift
private static func makeClientForTestsOrProd() -> VoiceFlowClient {
    let isUITestMode = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
    if isUITestMode {
        return VoiceFlowClient.makeStub(liveTranscript: "Mock transcription")
    }
    return try! makeVoiceFlowClient() // throws 在 prod 路径已经被 token guard 处理
}
```

## 验收标准

- [ ] App 启动后，用户在 Settings 里填一个 token 并保存到 Keychain（你的代码，库不管）
- [ ] 录音 UI 上按一下 button，能看到麦克风权限请求弹窗。Allow 之后开始录音
- [ ] 录音时说一句完整的话，能看到 partial transcript 实时显示在 UI 上
- [ ] 再按一次 button 停止录音。1-3 秒内 final transcript 出现，替代或追加到你的 input
- [ ] 录音中途断网然后恢复，UI 不应该崩。如果断 < 5 秒，session 自动 recover，录音继续；> 5 秒，`recoveryFailed` 事件 emit，你的 UI 应该提示并清理
- [ ] 录音中切到后台再切回前台，session 应该仍然能正常 finalize（VoiceFlow app 在 scenePhase `.background` 调 `session.cancel()` 是保守做法，可以学）
- [ ] Token 错或 endpoint 错时，`commitAndStop` throw `VoiceFlowError.missingToken` / `.invalidEndpoint` / `.httpError(statusCode:)`，UI 应该展示对应错误
- [ ] UI test launch mode 跑过：`makeStub()` 走通，不起 WebSocket，commitAndStop 在 ~100ms 内返回 stub 文本

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|---|---|---|
| `events` AsyncStream 是冷的 | 录音正常，partial transcript 不显示 | 起 consumer Task 必须在 mic 开始**之前或同时**，不能在 mic chunk 已经在飞之后才起 |
| 忘了 ping | 录音超过 15-20 秒就 disconnect | 起一个 12 秒间隔的 heartbeat task，stop 时记得 cancel |
| Token 是空字符串 | `commitAndStop` throw `.missingToken` 但不是 immediately | `tokenProvider` 闭包先 trim whitespace 再 return；空字符串等价于 nil |
| Token 在 session 中途被用户清空 | 行为不定 | `tokenProvider` 闭包要么 capture 一个 snapshot（推荐），要么 throw `.missingToken` 让 session 优雅失败 |
| Endpoint 没有 scheme | `commitAndStop` throw `.invalidEndpoint` | URL string 前面加 `https://` 再扔给 `URL(string:)` |
| App 在 macOS 编译失败 | `'VoiceFlowMicrophone' is unavailable` | `VoiceFlowMicrophone` 用 `#if os(iOS) || os(visionOS)` 守起来。如果是 cross-platform target，把所有 mic 相关代码包在条件编译里 |
| Mic chunk 大小不一致 | 录音正常但每个 partial transcript 延迟突然变大 | 库内部不要求精确 chunk 大小，session 把 PCM 当 byte stream 处理。但 chunk 太大（>1s）会让 partial 间隔变长。`VoiceFlowMicrophone` 默认 chunk 已经合适，不要在 onPCMChunk 里自己缓冲 |
| `recoveryFailed` 之后还在 send audio | session 静默丢弃，UI 看上去"卡住" | 收到 `.recoveryFailed` 就 stop mic 并 `session.cancel()` |
| 不写麦克风权限描述 | App store reject | Info.plist 里 `NSMicrophoneUsageDescription` 必填 |
| Xcode Cloud 报 SPM resolve failed | `Package.resolved` 没被 git track | `.gitignore` 把 `Package.resolved` 改成 `/Package.resolved`，commit xcworkspace 下的那份 lockfile |

## 边界

库不做的事：

- **UI**：你自己画 mic button、状态指示、错误提示
- **Token 存储**：你用 Keychain 或别的方式，传给 `tokenProvider` 闭包
- **Prompt 输入控件**：你自己做 prompt + terms 的 input UI；库只接受最终的 String / [String]
- **Backend 选择**：endpoint 默认是 AI Builder Space (`https://space.ai-builders.com/backend`)。要换 backend 需要确认对方实现了同样的 wire 协议（POST `/v1/audio/realtime/sessions` 拿 ticket，wss `/v1/audio/realtime/ws?ticket=...` 走 PCM16）

库管的事：

- WebSocket 连接、重连、ticket flow
- PCM16 24kHz mono 编码 + chunk 序列化
- Partial transcript 累积、合并、commit 后 finalize 等待
- Bulk 文件转写（同样走 WS pipeline，只是 host 一次性喂完）
- Caption 双层状态（`StreamCaption` / `StreamCaptionStore` —— 如果你想要"reconnecting…"/"reconnected"这种用户提示）

## 参考实现

把这两个文件读一遍能省你很多猜测：

1. **OpenCode iOS Client** 是一个 chat app，把 VoiceFlowKit 装在了 chat composer 上（按 mic 录音 → 转写完直接进 input field）：
   - `OpenCodeClient/OpenCodeClient/AppState.swift` 的 `makeVoiceFlowClient()` / `startRealtimeSpeechSession()` / `testAIBuilderConnection()`
   - `OpenCodeClient/OpenCodeClient/Views/Chat/ChatTabView.swift` 的 `toggleRecording()` / `startSpeechHeartbeat()`
   - 私有 repo（仅供 reference），public PR link: `grapeot/opencode_ios_client#52`

2. **VoiceFlow** 是 VoiceFlowKit 的 "first party" app，把它做成完整的 voice memo recorder（录音 + 历史 + resend + 转 OpenCode）：
   - 同 repo `src/VoiceFlow/VoiceFlow/AppState.swift`（lifecycle 主流程）
   - `src/VoiceFlow/VoiceFlow/AppState+LiveSession.swift`（live session bridge 完整 reference）
   - `src/VoiceFlow/VoiceFlow/Views/RecordView.swift`（UI 怎么 bind）

如果你的场景跟 OpenCode 类似（chat input），抄 OpenCode；如果你想做"专门录长音频"的产品，抄 VoiceFlow。

## 接下来

- 想自定义 prompt 让模型输出更有结构（比如全大写、bullet 形式）：见 `docs/working.md` 的 "prompt-following" 段。注意 `gpt-realtime` 对**短指令型**的 prompt 反应弱，对**指令 + Example**形态响应强。
- 想做 visionOS 适配：iOS code 多数能直接跑（VoiceFlowKit 已支持），但 UI 要 `WindowGroup` 改 `ImmersiveSpace` 还是 `WindowGroup` 视设计决定。这本 skill 不覆盖 visionOS UI 设计。
