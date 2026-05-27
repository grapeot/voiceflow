# Working Notes

## Changelog

### 2026-05-26

- 创建 VoiceFlow 项目文档骨架。
- 明确 V0 只包含 Record 和 Settings 两个 tab。
- 确定 API token 使用 Keychain 保存，API 请求使用 Bearer auth。
- 将产品主目标调整为纯粹语音输入，OpenCode 发送改为可选增强。
- 明确转写完成后自动写入系统剪贴板，Universal Clipboard 由系统同步。
- 接入用户新建的 Xcode 工程，路径为 `src/VoiceFlow/VoiceFlow.xcodeproj`。
- 将测试文档中的 Xcode 命令统一到当前工程路径。
- 建立 Record / Settings 双 tab app shell，加入英文和简体中文本地化资源。
- 迁入现有 app icon 与 visionOS layered icon 资产。
- 增加基础 unit/UI tests，覆盖默认状态、OpenCode 可选性和中英文 UI shell。
- 增加 AI Builder token 保存、清除、遮罩显示和 mock 连接测试路径。
- 将 token 保存接入 Keychain，UI test 模式使用内存 store 和 mock client，避免真实 token 与真实网络。
- 验证 iOS test、visionOS build 和隐私扫描通过。
- 增加录音到转写的可测试主路径：48 kHz PCM16 WAV 录音配置、multipart `audio_file` 上传 client、mock 转写、自动复制和最近 5 条历史。
- Record tab 接入 Start / Stop / Copy / History 按钮，UI test 模式走 mock recorder、mock transcriber 和 mock clipboard，不需要真实麦克风或真实网络。
- Xcode 生成的 Info.plist 已加入麦克风权限说明。
- 麦克风权限请求在 iOS 17 / visionOS 1 及以上使用 `AVAudioApplication.requestRecordPermission`，旧系统才回退到 `AVAudioSession.requestRecordPermission`。

## Lessons Learned

- 对外文档只描述 VoiceFlow 的最终产品状态，不记录任何实现来源或非产品上下文。
- V0 的主路径是语音识别和剪贴板输入；OpenCode 配置必须保持可选。
- 当前 Xcode 工程使用 file-system synchronized groups，新 Swift 文件放进 `src/VoiceFlow/VoiceFlow/` 后会自动进入 target。
- 独立 LSP 无法解析 Xcode 测试 target 的 `Testing` / `XCTest` 模块，测试文件以 target-aware `xcodebuild test` 为准。
- 独立 SourceKit 对 file-system synchronized groups 也可能看不到同 target 的新增 Swift 类型，当前以 `xcodebuild` 作为最终编译依据。
- visionOS simulator 的 generic destination 不可用，当前使用 `platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2`。
- multipart 上传测试使用 `URLProtocol` 拦截请求，验证 Bearer header、`/v1/audio/transcriptions` path 和 `audio_file` 表单字段，不依赖真实 AI Builder token。
- 旧 iOS 工程未命中 `requestRecordPermission` 调用；当前不需要同步改旧 repo。

## Verification

### 2026-05-26 Token milestone

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .`：零匹配。

### 2026-05-26 Recording and transcription milestone

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .`：零匹配。

### 2026-05-26 Microphone permission API cleanup

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .`：零匹配。
