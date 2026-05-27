# VoiceFlow RFC

## 设计判断

VoiceFlow 的主路径是语音输入。V0 只需要把四件事做可靠：录音、转写、自动复制到剪贴板、保留最近历史。OpenCode 发送是可选增强，不能影响语音输入主流程。

当前阶段采用先文档、再实现的顺序。PRD 和 RFC 先固定目标边界，再按 GUI 对齐、录音诊断、语言选择、外观选择、隐私检查、GitHub 发布、deep link 的顺序逐步落地。这样可以避免一边改 UI 一边扩大产品范围。

实现上采用 SwiftUI + AVFoundation + URLSession + Security.framework，不引入第三方依赖。iOS、iPadOS 和 visionOS 共用 SwiftUI 代码和业务逻辑。

## 模块划分

当前源码结构以实际工程为准：

```text
VoiceFlow/
  VoiceFlowApp.swift
  AppState.swift
  Views/
    MainTabView.swift
    RecordView.swift
    SettingsView.swift
    Components/
      ColoredButtonStyle.swift
  Models/
    ConnectionStatus.swift
    OpenCodeSendStatus.swift
    TranscriptHistory.swift
  Services/
    AudioRecorder.swift
    AIBuilderClient.swift
    AIBuilderTranscriptionClient.swift
    ClipboardService.swift
    KeychainStore.swift
    OpenCodeClient.swift
  Resources/
    en.lproj/Localizable.strings
    zh-Hans.lproj/Localizable.strings
    Assets.xcassets
```

`AppState` 保存跨页面状态：AI Builder token 是否存在、连接测试状态、当前 transcript、最近历史、剪贴板复制状态、OpenCode 是否已配置、当前发送状态、语言偏好和外观偏好。录音、API、剪贴板、Keychain 逻辑放在 service 中，避免把 UI 状态和系统接口细节混在 SwiftUI view 里。

新增偏好应尽量保持轻量。语言偏好和外观偏好可以用 `UserDefaults` 保存，因为它们不是凭据。AI Builder token 和 OpenCode password 继续只进 Keychain。

## 鉴权模型

AI Builder Space 使用 Bearer token。用户在 Settings 输入 token 后，应用写入 Keychain。所有需要鉴权的 HTTP 请求都添加：

```http
Authorization: Bearer <token>
```

token 不进入 `UserDefaults`、日志、错误消息或崩溃上报。Keychain item 使用 app bundle identifier 作为 service，account 使用稳定 key，例如 `aiBuilderToken`。可访问性使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。

Settings 页面显示 token 是否已保存，并提供 Test Connection。连接测试使用低成本 authenticated endpoint。token 变化后连接状态回到未测试。

OpenCode 配置独立于 AI Builder token。OpenCode password 进入 Keychain；server URL 和 username 可以进入 UserDefaults。OpenCode client 必须拒绝远程 HTTP、URL user-info 和会泄露 Basic Auth 的配置。

## Endpoint 策略

应用内固定 AI Builder Space base endpoint：

```text
https://space.ai-builders.com/backend
```

UI 不提供 endpoint 编辑入口。调试版本如果需要覆盖 endpoint，应通过编译配置或 launch argument 完成，不进入公开用户设置。

API path 按 backend contract 拼接，例如 `/v1/audio/transcriptions`。VoiceFlow 的后端能力基于 AI Builder Space，所有转写请求都通过 Bearer auth 访问该后端。

## GUI 对齐

Record 页沿用参考实现的 V0 可用部分：顶部状态区，中间录音控制区，底部大文本区和固定操作按钮。V0 不复制参考实现中的自动修正、模型选择、SecondMind、Watch 或复杂菜单。

Settings 页沿用参考实现的表单节奏：每个字段由 label、输入控件或只读值、状态说明组成。AI Builder endpoint 只读展示；OpenCode 保持可选配置。语言和外观偏好放在 Settings 底部，使用紧凑的三段选择控件：System / English / 简体中文，System / Light / Dark。

GUI 对齐的验收标准是：Record/Settings 的主路径布局、按钮位置和表单组织与参考实现接近；现有 UI tests 可通过 accessibility identifiers 或稳定本地化文案找到控件；iOS test 和 visionOS build 串行通过。

## 转写方案

V0 采用录完上传。流程是：本地采集音频、停止后生成 WAV、通过 multipart form 上传到 `/v1/audio/transcriptions`，返回文本后更新当前 transcript、写入历史，并自动复制到剪贴板。

实时转写作为后续阶段。实时方案需要先创建 realtime session，再使用返回的 websocket URL 发送 PCM16 mono audio frames。它对采样率、断线恢复、权限中断和 visionOS 麦克风行为要求更高，放在 V0 后可以降低第一版风险。

## Record Tab 状态机

Record tab 使用显式状态机：

```text
idle -> requestingPermission -> recording -> transcribing -> ready
ready -> sending -> ready
any -> error -> idle 或 ready
```

Start 只在 `idle`、`ready` 和可恢复错误状态可用。Stop 只在 `recording` 可用。转写成功进入 `ready` 时自动触发剪贴板写入。Copy 只依赖 transcript 非空。Send to OpenCode 只在 transcript 非空且 OpenCode 已配置时可用。

历史记录在一次成功转写后写入。手动编辑 transcript 不自动写历史，避免用户改一个字就污染历史。

## 录音诊断日志

录音失败需要能定位阶段。实现上新增一个轻量 diagnostics 层，优先用 `OSLog` 或可注入的 `RecordingDiagnostics` protocol。AppState 在以下节点记录事件：缺少 token、开始请求权限、权限拒绝、录音开始成功、录音开始失败、停止录音成功、停止录音失败、临时音频文件大小、开始转写、转写成功、转写失败、复制成功、复制失败。

日志字段只允许包含安全摘要：事件名、错误类别、本地化错误 key、布尔状态、字节数。禁止记录 token、Authorization header、完整 URL query、transcript、音频内容、真实本地路径、原始 API 响应正文。测试使用 mock diagnostics 断言关键失败路径有记录，并断言日志内容不会包含 fake token 或 transcript。

## 剪贴板与 Universal Clipboard

VoiceFlow 在每次成功转写后自动把 transcript 写入系统剪贴板。iOS、iPadOS 和 visionOS 都通过平台 pasteboard API 实现；Universal Clipboard 由 Apple 系统负责同步，应用侧只需要写入本机通用剪贴板，并避免使用自定义 pasteboard。

自动复制失败时，转写结果仍保留在 Record tab，并显示可读提示。用户可以点击 Copy 再试一次。剪贴板状态只展示结果，不记录剪贴板内容。

## OpenCode 发送

V0 的 OpenCode client 直连用户配置的 OpenCode server。发送流程是创建 session，再把 transcript prompt 异步发送到该 session。OpenCode 配置是可选项。未配置时，Record tab 仍然完整支持录音、转写、自动复制、历史回滚和手动复制。

OpenCode server URL 默认是 localhost。远程 server 必须使用 HTTPS。username 存在 UserDefaults，password 存在 Keychain。错误消息只展示类别，不展示凭据或响应正文。

## Settings Tab

Settings 包含四组配置。第一组是必需的 AI Builder Space 配置：API token 输入、保存/清除按钮、Test Connection、默认 endpoint 说明。默认 endpoint 只展示为只读说明文案，不是输入框。

第二组是可选的 OpenCode 配置。未配置时不显示错误，也不阻塞语音输入。

第三组是语言偏好：System、English、简体中文。默认 System。选择 System 时跟随系统语言；选择具体语言时，app 在 SwiftUI 环境中应用对应 locale。

第四组是外观偏好：System、Light、Dark。默认 System。选择 System 时不设置 `preferredColorScheme`；选择 Light 或 Dark 时在 app 根视图应用对应 color scheme。

token 输入使用 `SecureField`。保存时去掉首尾空白；空字符串不保存。清除 token 后，Record tab 的转写入口应进入未配置状态，历史、手动复制和设置页仍可用。

## 本地化

当前实现使用 `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings`。所有用户可见字符串都使用 localized key。key 使用英文语义名，例如 `record.start`, `settings.apiToken.title`。中文和英文翻译都在资源文件中维护。

语言偏好可以建模为：

```swift
enum AppLanguage: String, CaseIterable {
    case system
    case english
    case simplifiedChinese
}
```

System 模式不覆盖 locale；English 使用 `Locale(identifier: "en")`；简体中文使用 `Locale(identifier: "zh-Hans")`。UI tests 需要覆盖 launch argument 指定系统语言，以及 Settings 中手动切换语言后关键文案变化。

## 外观

外观偏好可以建模为：

```swift
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark
}
```

System 模式不设置 `preferredColorScheme`；Light 映射 `.light`；Dark 映射 `.dark`。RecordView、SettingsView 和 `ColoredButtonStyle` 应避免把所有颜色写死成只适合浅色模式的值。优先使用 `.primary`、`.secondary`、`.tint`、semantic background，以及集中定义的 action colors。

测试至少覆盖设置持久化和根视图可应用选择。视觉截图可以后置，但 iOS test 和 visionOS build 必须通过。

## Deep Link

GitHub repo 建好并完成首轮发布后，实现 deep link。建议注册 URL scheme：

```text
voiceflow://record
```

应用在 `VoiceFlowApp` 根视图处理 `.onOpenURL`。当收到 `voiceflow://record` 时，调用 AppState 的安全入口开始录音。该入口复用现有 `startRecording()`，因此 token 缺失、权限拒绝、录音启动失败都会走同一套状态和诊断日志。

deep link 不接受文本、token、server URL 或任意外部 payload。未知 host/path 直接忽略并记录安全摘要。测试需要覆盖 URL handler 对 `voiceflow://record` 的识别，以及 UI/集成层面确认 shortcut URL 可以触发录音 mock flow。文档需要说明 iOS Shortcuts 的用法：创建打开 URL 动作，填入 `voiceflow://record`，再绑定到 Action Button 或桌面快捷方式。

## 数据保留

V0 历史默认只保存最近 5 条 transcript。录音文件只作为转写请求的临时文件，转写成功或失败后都应清理。剪贴板内容不单独持久化；历史承担恢复和回滚职责。若未来需要长期录音管理，再引入文件库和用户可见删除机制。

语言偏好、外观偏好、OpenCode server URL 和 OpenCode username 可以保存在 UserDefaults。AI Builder token 和 OpenCode password 只能保存在 Keychain。

## 错误处理

错误消息面向用户，避免暴露 token、请求 header、完整 URL query 或底层堆栈。常见错误分为：未配置 AI Builder token、麦克风权限被拒绝、录音失败、转写失败、自动复制失败、连接测试失败、OpenCode 未配置、OpenCode 发送失败、deep link 无法开始录音。每类错误都有中英文文案。

诊断日志面向开发调试，只记录安全摘要。用户可见错误和诊断日志的粒度可以不同，但二者都不能泄露敏感内容。

## 实现阶段

Phase 0：更新 PRD/RFC，固定当前目标、范围和验收标准。

Phase 1：完成 Record 和 Settings GUI 对齐，更新 UI tests，串行跑通 iOS test、visionOS build 和隐私扫描，更新 `docs/working.md`，commit。

Phase 2：加入录音失败诊断日志，补单元测试和文档，串行验证后 commit。

Phase 3：实现语言偏好。默认跟随系统，同时支持 Settings 手动 English / 简体中文，补本地化测试和文档，串行验证后 commit。

Phase 4：实现外观偏好。默认跟随系统，同时支持 Settings 手动 Light / Dark，补测试和文档，串行验证后 commit。

Phase 5：完成 privacy review。检查真实 token、日志、音频文件、构建产物、私有路径、私有实现上下文；串行跑 iOS test、visionOS build 和隐私扫描。

Phase 6：新建 GitHub repo，使用 `master` branch push。

Phase 7：实现 deep link 启动录音，更新 README/PRD/RFC/test 文档，补测试，commit，发 PR 并 merge。

## 验证要求

每个非平凡阶段都更新 `docs/working.md`。Xcode 验证串行执行：

```bash
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build
rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .
rg --files -g '*.m4a' -g '*.wav' -g '*.caf'
```

提交使用仓库现有风格，并且 git 命令带 `GIT_MASTER=1`。GitHub 发布和 PR 操作串行执行。

## 待确认问题

1. GitHub repo 名称。
2. deep link URL scheme 是否沿用 `voiceflow://record`，还是为了避免未来和其他 app 冲突改成更明确的 public scheme。
3. 是否需要在 App Store / TestFlight 前补视觉截图自动化。
