# VoiceFlow RFC

## 设计判断

VoiceFlow 的主路径是语音输入。V0 只需要把四件事做可靠：录音、转写、自动复制到剪贴板、保留最近历史。OpenCode 发送是可选增强，不能影响语音输入主流程。

实现上采用 SwiftUI + AVFoundation + URLSession + Security.framework，不引入第三方依赖。iOS、iPadOS 和 visionOS 共用一个 app target 或一套 shared source，具体 Xcode target 结构在工程创建时根据 Xcode 模板再定。

## 模块划分

建议源码结构如下：

```text
VoiceFlow/
  VoiceFlowApp.swift
  AppState.swift
  Views/
    MainTabView.swift
    RecordView.swift
    SettingsView.swift
    Components/
      RecordingControls.swift
      TranscriptEditor.swift
      HistoryControls.swift
      ConnectionStatusView.swift
  Models/
    TranscriptEntry.swift
    TranscriptHistory.swift
    RecordingState.swift
    OpenCodeConfig.swift
  Services/
    AudioRecorder.swift
    AIBuilderClient.swift
    ClipboardService.swift
    OpenCodeDispatchClient.swift
    KeychainStore.swift
  Resources/
    Localizable.xcstrings
    Assets.xcassets
```

`AppState` 只保存跨页面状态：AI Builder token 是否存在、连接测试状态、当前 transcript、最近历史、剪贴板复制状态、OpenCode 是否已配置和当前发送状态。录音、API、剪贴板、Keychain 逻辑放在 service 中，避免把 UI 状态和系统接口细节混在一个 view model 里。

## 鉴权模型

AI Builder Space 使用 Bearer token。用户在 Settings 输入 token 后，应用写入 Keychain。所有需要鉴权的 HTTP 请求都添加：

```http
Authorization: Bearer <token>
```

token 不进入 `UserDefaults`、日志、错误消息或崩溃上报。Keychain item 建议使用 app bundle identifier 作为 service，account 使用稳定 key，例如 `aiBuilderToken`。可访问性使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。

Settings 页面显示 token 是否已保存，并提供 Test Connection。连接测试使用一个低成本 authenticated endpoint，例如 embeddings 或 usage summary。测试成功后可以保存 token hash 与 endpoint hash 组成的签名，用来在重启后恢复“上次验证通过”的 UI 状态；token 变化后签名失效。

OpenCode 配置独立于 AI Builder token。它可以为空；为空时 UI 隐藏或禁用 Send to OpenCode。OpenCode 凭据如果存在，也进入 Keychain，不进入日志或错误消息。

## Endpoint 策略

应用内固定 AI Builder Space base endpoint：

```text
https://space.ai-builders.com/backend
```

UI 不提供 endpoint 编辑入口。调试版本如果需要覆盖 endpoint，应通过编译配置或 launch argument 完成，不进入公开用户设置。

API path 按 backend contract 拼接，例如 `/v1/audio/transcriptions`、`/v1/audio/realtime/sessions`。VoiceFlow 的后端能力基于 AI Builder Space，所有转写请求都通过 Bearer auth 访问该后端。

## 转写方案

V0 推荐先做录完上传。这样实现简单、状态少、错误恢复清楚，也更适合第一阶段验证。流程是：本地采集音频、停止后生成 WAV 或 M4A、通过 multipart form 上传到 `/v1/audio/transcriptions`，返回文本后更新当前 transcript、写入历史，并自动复制到剪贴板。

实时转写作为 Phase 2。实时方案需要先创建 realtime session，再使用返回的 websocket URL 发送 PCM16 mono audio frames。它对采样率、断线恢复、权限中断和 VisionOS 麦克风行为要求更高，放在 V0 后可以降低第一版风险。

## Record Tab 状态机

Record tab 使用显式状态机：

```text
idle -> requestingPermission -> recording -> transcribing -> ready
ready -> sending -> ready
any -> error -> idle 或 ready
```

Start 只在 `idle`、`ready` 和可恢复错误状态可用。Stop 只在 `recording` 可用。转写成功进入 `ready` 时自动触发剪贴板写入。Copy 只依赖 transcript 非空。Send to OpenCode 只在 transcript 非空且 OpenCode 已配置时可用。

历史记录在一次成功转写后写入。手动编辑 transcript 不自动写历史，避免用户改一个字就污染历史。后续如果要保存手动编辑版本，可以加显式 Save Current。

## 剪贴板与 Universal Clipboard

VoiceFlow 在每次成功转写后自动把 transcript 写入系统剪贴板。iOS、iPadOS 和 visionOS 都通过平台 pasteboard API 实现；Universal Clipboard 由 Apple 系统负责同步，应用侧只需要写入本机通用剪贴板，并避免使用自定义 pasteboard。

自动复制失败时，转写结果仍保留在 Record tab，并显示可读提示。用户可以点击 Copy 再试一次。剪贴板状态只展示结果，不记录剪贴板内容。

## OpenCode 发送

V0 把 Send to OpenCode 定义成一个独立 client：`OpenCodeDispatchClient`。它只接收纯文本和 OpenCode 配置，不知道 UI 状态，也不持有录音状态。

OpenCode 配置是可选项。未配置时，Record tab 仍然完整支持录音、转写、自动复制、历史回滚和手动复制。已配置时，Record tab 提供 Send to OpenCode。

发送接口需要在实现前最终确认。如果使用 AI Builder Space 提供的 OpenCode dispatch endpoint，client 使用 Bearer token 调用该 endpoint。如果直连用户自托管 OpenCode server，则 Settings 需要增加 server URL 和对应鉴权配置。两种方式只能选一种作为 V0 默认路径，避免 Settings 同时出现两套配置。

## Settings Tab

Settings 包含两组配置。第一组是必需的 AI Builder Space 配置：API token 输入、保存/清除按钮、Test Connection、默认 endpoint 说明。默认 endpoint 只展示为只读说明文案，不是输入框。

第二组是可选的 OpenCode 配置。未配置时不显示错误，也不阻塞语音输入。配置字段要等发送方式确认后再定，优先保持最少字段。

token 输入使用 `SecureField`。保存时去掉首尾空白；空字符串代表清除 token。清除 token 后，Record tab 的转写入口应进入未配置状态，历史、手动复制和设置页仍可用。

## 本地化

使用 `Localizable.xcstrings`。所有用户可见字符串都使用 localized key。key 使用英文语义名，例如 `record.start`, `settings.apiToken.title`。中文和英文翻译都在资源文件中维护。

测试中至少覆盖两个 locale：`zh-Hans` 和 `en`。UI snapshot 可以后置，V0 先用 launch argument 或 XCTest 检查关键按钮文案存在。

## 数据保留

V0 历史默认只保存最近 5 条 transcript。可以先用 `UserDefaults` 存 Codable 数组，因为数据量小且结构简单。录音文件只作为转写请求的临时文件，转写成功或失败后都应清理。剪贴板内容不单独持久化；历史承担恢复和回滚职责。若未来需要长期录音管理，再引入文件库和用户可见删除机制。

## 错误处理

错误消息面向用户，避免暴露 token、请求 header、完整 URL query 或底层堆栈。常见错误分为：未配置 AI Builder token、麦克风权限被拒绝、录音失败、转写失败、自动复制失败、连接测试失败、OpenCode 未配置、OpenCode 发送失败。每类错误都有中英文文案。

## 实现阶段

Phase 1：创建 SwiftUI iOS/visionOS 工程骨架，加入两个 tab、本地化资源、KeychainStore、Settings token 保存和连接测试。

Phase 2：实现录音、停止、临时音频文件生成、上传转写、当前 transcript、自动复制和历史回滚。

Phase 3：确认 OpenCode 配置和发送方式，实现可选 Send to OpenCode、发送状态和失败重试。

Phase 4：补齐 XCTest、iOS build、visionOS build、隐私扫描和 README 使用说明。

## 待确认问题

1. OpenCode 采用 AI Builder Space dispatch endpoint 还是直连用户自托管 server。
2. V0 是否接受先做录完上传，再做实时转写。
3. 历史是否需要跨 app 重启保留；RFC 当前建议保留最近 5 条。
4. OpenCode 可选配置需要哪些最少字段。
5. App bundle identifier、icon 和 TestFlight/App Store 分发策略。
