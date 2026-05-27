# Working Notes

## Changelog

### 2026-05-26

- 增加自适应 Simulator pinning：`scripts/lib/simulator.sh` 在本机 `.voiceflow/simulator-udid` 记录 UDID，测试脚本复用已 boot 的 Simulator，并优先 `test-without-building`。
- 新增 `scripts/pin_simulator.sh` 用于手动预热；`test_unit.sh` / `test_all.sh` 接入 pinning 与 rebuild fallback。
- 更新 `docs/test.md`：Agent 默认只跑 unit test，除非用户明确要求 UI test。
- 将 Settings 的语言和外观偏好写入产品范围：默认跟随系统，同时允许用户手动选择 English / 简体中文、System / Light / Dark。
- 将 deep link 作为发布后的最后阶段：注册 `voiceflow://record` 类 URL，供 Shortcuts、Action Button 或桌面快捷方式直接启动录音。
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
- 增加可选 OpenCode 发送路径：Settings 保存自托管 server URL、username 和 Keychain password，Record tab 可把当前转写发送到 OpenCode。
- OpenCode client 使用 Basic Auth，先 `POST /session` 创建会话，再 `POST /session/{id}/prompt_async` 异步发送 transcript prompt。
- UI test 模式覆盖 OpenCode 配置保存、遮罩显示和清除，不需要真实 OpenCode server。
- OpenCode server URL 增加安全校验：远程 server 必须使用 HTTPS，HTTP 只允许 localhost / loopback，避免 Basic Auth 和 transcript 通过远程明文连接发送。
- 新录音开始和新转写完成时会重置 OpenCode 发送状态，避免旧 transcript 的发送结果残留在 Record 页。
- 完成 Record / Settings GUI 对齐阶段：Record 改为固定状态区、录音控制区、大文本区和底部操作按钮；Settings 改为 label + rounded field 的表单节奏。
- UI tests 改为覆盖新 GUI 下的英文/中文 shell、token 保存、mock 录音流和 OpenCode 配置流；Record 转写框增加 accessibility value，OpenCode 按钮增加稳定 accessibility label。
- 增加录音诊断日志阶段：录音、权限、停止、空音频文件、转写上传、响应解析、剪贴板和 OpenCode 发送路径会记录 OSLog 安全摘要事件，只记录阶段、错误类型、字符数和音频字节数，不记录 token、转写文本、音频内容、文件路径、Authorization header 或原始响应正文。
- 新增内存 diagnostics seam 和单元测试，覆盖成功路径、缺少 token、权限拒绝、录音启动失败、停止失败、空音频、上传失败、响应失败、剪贴板跳过/失败、OpenCode 发送成功/失败，以及诊断事件不包含 fake token、OpenCode password 或转写文本。
- 完成 Settings 语言偏好阶段：新增 System / English / 简体中文 segmented picker，偏好写入 UserDefaults；System 使用主 bundle，English 和简体中文使用对应 `.lproj` bundle。
- Record / Settings / tab label 的用户可见文案改为显式 bundle 本地化，语言偏好变化后会重建 root SwiftUI subtree，确保运行时切换立即反映到界面。
- UI tests 增加语言偏好覆盖：英文系统切到中文、中文系统切到英文，并避免依赖语言切换后 tab bar accessibility 状态的瞬时变化。
- Review 后将录音错误、连接失败、剪贴板状态和 OpenCode 失败状态改为保存本地化 key，由视图按当前 bundle 解析，避免语言切换后保留旧语言文案。
- 为麦克风权限提示补齐 `InfoPlist.strings` 英文和简体中文资源；构建产物中已验证 `en.lproj` 和 `zh-Hans.lproj` 都包含 `InfoPlist.strings`。
- Record 页录音错误改为 alert 弹窗展示，不再占用顶部大标题状态区；`RecordingStatus` 去掉 `.error`，错误后恢复为 `idle`。（后续又恢复固定「VoiceFlow」标题 + 指示灯，状态文案不再作为大标题。）
- 录音失败 diagnostics 增加 `phase`、`errorDomain`、`errorCode`、`errorFourCC` 字段，便于定位 AVAudioSession 具体失败步骤。
- 修复录音启动失败：`setPreferredInputNumberOfChannels(1)` 在部分设备上返回 `NSOSStatusErrorDomain -50`（paramErr），现改为 best-effort preference，不再阻断录音；输出 WAV 仍固定 mono 48 kHz。
- 新增 `scripts/test_unit.sh`（只跑 VoiceFlowTests）和 `scripts/test_all.sh`（unit + UI）；关闭 launch UI test 的 `runsForEachTargetApplicationUIConfiguration`，避免重复启动 app。
- 完成 privacy review：工作区与 commit history 隐私扫描零命中；`.gitignore` 补充 `.venv/`；对外文档去掉内部实现来源表述；发布到 GitHub public repo `grapeot/voiceflow`。
- Record 页去掉「转写完成后会自动复制」常驻提示；转写成功后仍自动写入剪贴板，状态区只在复制成功/失败时显示结果。
- Record 页 OpenCode 说明移到「发送到 OpenCode」旁的 info 按钮，点击后弹窗展示。
- OpenCode 发送默认禁用；Settings 保存配置并通过连接测试后，Record 页发送按钮才可用。
- Settings 增加 OpenCode 连接测试；URL/username/password 变更后连接状态回到未测试。
- OpenCode HTTP 校验对齐 Tailscale：除 localhost/loopback 外，`*.ts.net` 主机也允许 HTTP；并在 Info.plist 为 `ts.net` 配置 ATS 例外（对齐 brainwave iOS），否则 URLSession 仍会被 `-1022` 拦截。
- Record 控制区对齐参考实现：左右 chevron 分别浏览更旧/更新历史；三点菜单只保留「保存录音」和「重发录音」，去掉与底部重复的复制/OpenCode 发送。
- 转写历史改为 index 导航（index 0 为最新）；录音完成后持久化 last-recording.wav 供保存到 Documents 和重发转写。
- 新增 unit/UI tests 覆盖双向历史导航、保存/重发录音，以及 Record 控制区新按钮。
- Settings OpenCode 清除改为只删 Keychain 密码，保留 server URL 和 username；清除按钮文案改为「Clear Password / 清除密码」。
- 连接测试失败时在 Settings 展示具体错误信息（`ConnectionStatus.detail`）。
- Settings 点击文本框外区域自动收起键盘（API token 与 OpenCode 字段均适用）。
- OpenCode 说明文案更新：URL/username 保留在本机，仅密码进 Keychain。
- 实现 deep link `voiceflow://record`：注册 URL scheme，根视图 `.onOpenURL` 切到 Record tab 并复用 `startRecording()`。
- README 补充 Shortcuts / Action Button 用法。
- 刷新 PRD/RFC/test/README/AGENTS：去掉过时的「实现阶段/待发布」表述，改为 V0 交付状态；明确外观偏好为剩余项。
- Record 页顶部恢复参考版 UX：固定显示「VoiceFlow」标题 + 状态指示灯，不再用大标题展示「正在录音…」等状态文案；剪贴板/OpenCode 结果仍显示在标题下方 caption 区。
- 新增 `RecordingStatusHeaderView`，指示灯颜色映射：录音中 green、请求权限/转写中 orange、空闲/完成 blue。
- UI tests 改为通过 `record.statusIndicator` accessibility value 断言录音状态，并验证「VoiceFlow」标题常驻。
- Record 页对齐 brainwave iOS：新增录音计时行（`RecordingTimerView`，`MM:SS`）；Start/Stop 按钮宽 120pt；布局增加 5% 计时区。
- 规划 V1 实时流式转写：更新 PRD/RFC，定义 WebSocket stream、Stop finalize、增量 text 显示与 failure recovery；参考 AI Builder Space WebSocket realtime 行为。
- Record 转写框右下角显示灰色小字字符数（`%d characters` / `%d 字`）。

## Lessons Learned

- 对外文档只描述 VoiceFlow 的最终产品状态，不记录任何实现来源或非产品上下文。
- V0 的主路径是语音识别和剪贴板输入；OpenCode 配置必须保持可选。
- 当前 Xcode 工程使用 file-system synchronized groups，新 Swift 文件放进 `src/VoiceFlow/VoiceFlow/` 后会自动进入 target。
- 独立 LSP 无法解析 Xcode 测试 target 的 `Testing` / `XCTest` 模块，测试文件以 target-aware `xcodebuild test` 为准。
- 独立 SourceKit 对 file-system synchronized groups 也可能看不到同 target 的新增 Swift 类型，当前以 `xcodebuild` 作为最终编译依据。
- visionOS simulator 的 generic destination 不可用，当前使用 `platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2`。
- multipart 上传测试使用 `URLProtocol` 拦截请求，验证 Bearer header、`/v1/audio/transcriptions` path 和 `audio_file` 表单字段，不依赖真实 AI Builder token。
- `URLProtocol` 拦截到的 request body 可能在 `httpBodyStream` 而不是 `httpBody`，测试需要同时读取两种形态。
- Swift Testing 默认并行运行；共享 `MockURLProtocol.requestHandler` 的测试需要 `@Suite(.serialized)`，否则不同 HTTP mock 会相互覆盖。
- SwiftUI 的 `\.locale` 会影响部分格式化和 SwiftUI 环境，但不会可靠地让 `Localizable.strings` 在运行时改查另一个语言 bundle；运行时语言偏好需要显式选择 `.lproj` bundle 并把所有用户可见文案走同一条 bundle lookup。
- SwiftUI `TabView` 在 root `.id(...)` 重建和语言切换后，UI test 中 tab bar 的 accessibility 查询可能短暂不稳定；语言偏好测试应验证用户可见结果，而不是把 tab bar 查询本身当成产品行为。
- 可见状态不要在 model 中保存已经翻译好的字符串；保存本地化 key 可以让当前语言 bundle 在下一次 render 时重新解析，也让错误状态和剪贴板状态跟随运行时语言切换。
- Xcode 生成 Info.plist 时，权限提示这类系统弹窗文案仍需要 `InfoPlist.strings` 做本地化，不能只依赖 build setting 中的英文默认值。
- `AVAudioSession.setPreferred*` 是 preference，不是 contract；把 `setPreferredInputNumberOfChannels(1)` 当硬 requirement 会在部分 input route 上触发 `-50 paramErr`。
- `xcodebuild test` 默认会跑 UI tests 并多次冷启动 Simulator app；日常迭代用 `-only-testing:VoiceFlowTests` 或 `./scripts/test_unit.sh`。
- OpenCode 发送应独立于转写主路径 gating：配置保存不等于可发送，连接测试通过后再启用发送按钮，避免误发到未验证 server。
- Tailscale MagicDNS（`*.ts.net`）可按私有网络处理，HTTP 不应与公网 remote HTTP 使用同一拒绝规则；应用层允许不够，还需 Info.plist `NSExceptionDomains`。
- iOS 要在 Files app 中浏览 app Documents，必须在 Info.plist 启用 `UIFileSharingEnabled`；仅有 `copyItem` 到 Documents 不够。
- 对 app sandbox 内的 file URL，不要直接塞给 `UIActivityViewController`；真机会报 `NSOSStatusErrorDomain -10814`。保存录音只需告知 Files 路径，iOS 无公开 API deep link 到 app Documents 目录。

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

### 2026-05-26 Optional OpenCode send milestone

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。Xcode/actool 对 RealityDevice14,1 trait set 有 warning，但 build 退出 0。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .`：零匹配。

### 2026-05-26 OpenCode review fixes

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。Xcode/actool 对 RealityDevice14,1 trait set 有 warning，但 build 退出 0。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .`：零匹配。

### 2026-05-26 GUI parity and planning update

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。Xcode/actool 对 RealityDevice14,1 trait set 有 warning，但 build 退出 0。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .`：零匹配。
- `rg --files -g '*.m4a' -g '*.wav' -g '*.caf'`：零匹配。

### 2026-05-26 Recording diagnostics milestone

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。Xcode/actool 对 RealityDevice14,1 trait set 有 warning，但 build 退出 0。
- 五条 diagnostics 单元测试覆盖 success、missing token、permission denied、recording start/stop failure、empty audio、transcription upload/response failure、clipboard skipped/failed、OpenCode success/failure 和敏感文本排除。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .`：零匹配。
- `rg --files -g '*.m4a' -g '*.wav' -g '*.caf'`：零匹配。

### 2026-05-26 Language preference milestone

- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test`：通过。
- `xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build`：通过。Xcode/actool 对 RealityDevice14,1 trait set 有 warning，但 build 退出 0。
- 构建产物检查：`VoiceFlow.app/en.lproj` 和 `VoiceFlow.app/zh-Hans.lproj` 均包含 `InfoPlist.strings` 与 `Localizable.strings`。
- `rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .`：零匹配。
- `rg --files -g '*.m4a' -g '*.wav' -g '*.caf'`：零匹配。

### 2026-05-26 OpenCode gating and Record UI update

- `./scripts/test_all.sh`（VoiceFlowTests + VoiceFlowUITests）：通过。
- 单元测试覆盖：转写后仍自动复制、OpenCode 连接测试 gating、Tailscale HTTP 允许、remote HTTP 仍拒绝。
- UI tests 覆盖：转写后显示复制成功状态、OpenCode info 按钮、配置后需测试连接才能发送。
- Record 控制区 UI tests 覆盖左右历史按钮、保存/重发菜单项。

### 2026-05-26 Record controls history save resend

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- UI tests 本轮未跑；`testRecordingControlsExposeHistoryNavigationAndSaveResendMenu` 已加入但待后续单独验证。

### 2026-05-26 Settings OpenCode UX

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- 单元测试覆盖：OpenCode 清除仅删密码、连接失败 detail。
- UI tests 本轮未跑；新增 Settings UX 相关 UI test 待后续单独验证。

### 2026-05-26 Deep link record

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- 单元测试覆盖：`voiceflow://record` 解析、启动录音、未知 URL 忽略且不记录 query 内容。
- UI test 已加 `-uiTestDeepLinkRecord` 覆盖；本轮未跑 UI test suite。

### 2026-05-26 Transcript character count

- Record 转写框右下角显示字符数；英文 `%d characters`，中文 `%d 字`。
- `./scripts/test_unit.sh`：通过。

### 2026-05-26 V1 realtime streaming design docs

- 更新 PRD/RFC：V1 WebSocket 边录边发、Stop finalize、text delta 增量显示、failure recovery 与 bulk resend 约束。
- 文档-only PR；无代码变更。

### 2026-05-26 Record timer and control parity

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过（37 tests）。
- 新增 `RecordingTimerFormatter` / `RecordingTimerView`；`AppState` 在录音期间每秒更新 `recordingTimerText`。
- Start/Stop 按钮宽 120pt，对齐 brainwave iOS `RecordingControls`。
- UI tests 未跑。

### 2026-05-26 ATS Tailscale ts.net exception

- 对齐 brainwave iOS：在 `URLScheme.plist` 为 `ts.net` 增加 `NSExceptionAllowsInsecureHTTPLoads` + `NSIncludesSubdomains`，修复 OpenCode 连接 `http://*.ts.net` 时 ATS `-1022`。
- 单元测试断言构建产物 Info.plist 含 ts.net ATS 例外。
- `./scripts/test_unit.sh`：通过。

### 2026-05-26 Save recording confirmation simplification

- 去掉 Quick Look 预览与「Open in Files」按钮；保存后仅弹窗 + caption 指引用户手动打开 Files → On My iPhone → VoiceFlow。
- `./scripts/test_unit.sh`：通过。

### 2026-05-26 Save recording preview fix

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- 修复保存后「Open in Files」：`UIActivityViewController` + sandbox URL 在真机报 `-10814`；改 `.quickLookPreview`，alert dismiss 后延迟再弹出。

### 2026-05-26 Save recording Files UX

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- 单元测试覆盖：`RecordingFileSaver` 复制/缺失源文件、保存确认状态、无持久化音频时不保存。
- UI tests 已更新保存确认弹窗；本轮未跑。

### 2026-05-26 Record status indicator light

- `./scripts/test_unit.sh`（VoiceFlowTests）：通过。
- UI tests 已更新（`record.statusIndicator` + 「VoiceFlow」标题断言），本轮未跑。

### 2026-05-26 Documentation refresh

- 更新 PRD/RFC/test/README/AGENTS，反映 V0 已交付项与剩余项（外观偏好）。
- 移除 RFC 中已完成的 Phase 0–7 路线图与已决「待确认问题」。
