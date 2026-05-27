# VoiceFlow RFC

## 设计判断

VoiceFlow 的主路径是语音输入。V0 把录音、转写、自动复制、最近历史、可选 OpenCode 和 deep link 启动录音做可靠。OpenCode 不能阻塞语音输入主流程。

实现采用 SwiftUI + AVFoundation + URLSession + Security.framework，不引入第三方依赖。iOS、iPadOS 和 visionOS 共用 SwiftUI 代码和业务逻辑。

公开仓库：https://github.com/grapeot/voiceflow（`master`）。

## 模块划分

当前源码结构：

```text
VoiceFlow/
  VoiceFlowApp.swift          # 根视图、onOpenURL、语言 bundle
  AppState.swift              # 跨 tab 状态、录音/OpenCode/deep link
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
    AudioRecorder.swift
    AIBuilderClient.swift
    AIBuilderTranscriptionClient.swift
    ClipboardService.swift
    KeychainStore.swift
    OpenCodeClient.swift
    RecordingDiagnostics.swift
    RecordingFileSaver.swift
  Resources/
    en.lproj/ / zh-Hans.lproj/
    Assets.xcassets
URLScheme.plist               # CFBundleURLTypes、UIFileSharingEnabled、ATS ts.net 例外
scripts/test_unit.sh
scripts/test_all.sh
```

`AppState` 保存跨页面状态：录音状态、transcript、历史索引、tab 选择、token/OpenCode 配置与连接状态、剪贴板/OpenCode 发送状态、语言偏好、deep link 待处理标志。录音、API、剪贴板、Keychain 在 service 层；UI 不直接碰系统接口。

语言偏好用 `UserDefaults`。AI Builder token 与 OpenCode password 只进 Keychain。OpenCode server URL 与 username 进 UserDefaults；清除 OpenCode 只删 password。

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

V0 录完上传：48 kHz PCM16 mono WAV → multipart 上传 → 文本写入 transcript 与历史 → 自动复制。实时转写留后续。

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

后续优先：外观偏好；UI test suite 稳定跑通（部分用例已写，日常迭代以 `./scripts/test_unit.sh` 为主）。

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

- Settings 外观偏好
- 实时转写
- App Store 视觉截图自动化
- UI tests 在 CI 中默认可靠通过
