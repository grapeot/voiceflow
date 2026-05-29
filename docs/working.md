# Working Notes

## OpenCode vs VoiceFlow — streaming/finalize comparison

Side-by-side of the two implementations (OpenCode reference: `opencode_ios_client` `AIBuildersAudioClient.commitAndStop`; VoiceFlow: `RealtimeTranscriptionClient` + `AppState`).

| Step | OpenCode | VoiceFlow (before this fix) | Gap |
|------|----------|----------------------------|-----|
| Start recording | Mic + disk cache first; WS attach in deferred `Task` | Same pattern via `beginLiveSession` + `handleCapturedPCMChunk` | Aligned |
| WS connect timing | After mic/cache; ticket POST then `wss?ticket=` | Same ticket flow | Aligned |
| During recording | Streams audio; **no live transcript UI** | Suppresses `textDelta` until finalize (`shouldNotifyUI`) | Extra state machine |
| Receive loop | **Synchronous** `while` inside `commitAndStop` on session actor | Split: background `receiveLoop` + `finalize` continuation + `TaskGroup` | Harder to reason about; race on `waitForFinalizeResult` (fixed in #23) |
| Stop / commit | `commit` → receive deltas → `transcript_completed` → `stop` → return on `session_stopped` | Same wire sequence; `sendCommit` defers `stop` until completed | Aligned after VAD-off + min-bytes guard |
| Partial transcript merge | `partialAccumulator += delta` (append only) | `TranscriptDeltaReducer` / `FinalizeTranscriptMergerState` **replaced** on `isNewResponse` | **Truncation root cause** — second epoch wiped first half |
| UI thread on partial | `Task { @MainActor in inputText = ... }` in ChatTabView | Finalize callback set `self.transcript` **directly** from WS actor | **Main-thread violations** on TextEditor / `@Published` |
| Return value | `finalTranscript ?? ""` from receive loop | `finalize()` returns `String` from accumulator (now `max(partial, completed)`) | VoiceFlow slightly safer when completed snapshot is shorter |
| Error handling | Single `catch` → one alert | Stream error + bulk fallback could each alert; teardown could race | Partially unified in #23; finalize path now single success/failure exit |

**Why porting felt harder than OpenCode:** VoiceFlow added live-transcript suppression, event indirection (`deliverLiveSessionEvent` → `Task` → `onEvent`), and split commit/wait across actors without consistently hopping to `@MainActor` for UI mutations. OpenCode keeps commit + receive + return in one synchronous loop with an explicit MainActor partial callback.

## Changelog

### 2026-05-28 (Stop 按钮 hit-test 修复)

- **Root cause**: `CapsuleButton` 已用 `.contentShape(.hoverEffect, Capsule())` 限制 visionOS gaze hover，但没有给普通 SwiftUI hit-test 显式设置 capsule 区域。Stop 是 secondary outline 胶囊，视觉中间区域透明；在真机/visionOS 交互里，点到文字或描边外的空白区域时容易表现为第一次 stop 没被接受。
- **Fix**: `CapsuleButton` 增加 `.contentShape(Capsule())`，让 primary / secondary / ghost 三种胶囊角色的整个视觉 pill 都能接收 tap，同时保留原有 hoverEffect shape + lift。
- **Regression**: 新增 `testStopButtonRespondsAcrossCapsuleHitArea`，用 XCUITest 点击 Stop 胶囊右侧区域（不是按钮文字中心）并验证录音进入 ready / copied 状态。
- **验收**: `./scripts/test_unit.sh` 通过；`VOICEFLOW_TEST_REBUILD=1 ./scripts/test_ui_full.sh` 通过（12 / 12 UI tests）。

### 2026-05-28 (AppState 拆分到同型 extension + docs/README/RFC/PRD/skill 重整)

跟随 PR #38 facade 收紧 + PR #40 AppState 拆分之后，再做两件事：

**PR #40 续：AppState 拆到 7 个同型 extension**。主文件 1098 → 493 行。按职责切：LiveSession（session bridge 主体）、OpenCode（设置 + 发送）、Diagnostics（错误格式化）、AIBuilderToken、RecordingFiles、StreamCaption、RecordingTimer、TranscriptHistory。State 字段留在主类（SwiftUI 视图直接 bind），extension 只搬行为。同步把 `Package.resolved` 的 gitignore 从全局 `Package.resolved` 改成 `/Package.resolved`，留出空间将来加远程 SPM 依赖给 Xcode Cloud 用。

**PR #41：skill + README + PRD + RFC（这条 changelog 所在的 PR）**。把 VoiceFlowKit 正式 framing 成给 AI 集成方的"[生成内核](https://yage.ai/ai-software-engineering.html)"。新增 `skills/adding_voice_input_with_voiceflowkit.md` —— 一份给 host AI 看的完整集成指南，包含 5 步流程、验收标准、9 条已知陷阱、reference impl 路径。

- `README.md`：完全重写，开头明确 "library + app" 双产品定位，加 Generative Kernel framing 段，把 facade 表面、reference implementations、Xcode Cloud SPM 注意事项都列出来。
- `docs/prd.md`：拆"VoiceFlow app 的目标"和"VoiceFlowKit 作为生成内核的目标"两节。后者按"核心套件 / 引导知识 / 杠杆工具集"三分法对应到具体模块。Skill 文件被 PRD 显式确认为一等公民交付物。加 PR #38/#40 的工程变更段。
- `docs/rfc.md`：模块划分章节列出 7 个 AppState extension；facade-only 表面在 RFC 里被明确化；删除对已删 `docs/Library.md` 的所有引用，换成 skill 路径或保留在 commit message / working.md 里。

### 2026-05-28 (AppState 切到 facade + Internal 可见性收紧)

**PR — `feat/facade-migration`**

PR #35 抽 VoiceFlowKit 的时候，为了让 VoiceFlow app 自己不大改，把 services 层的 protocol（`RealtimeTranscribing`、`AudioChunkEncoder`、`RealtimeConnectionPhase` 等等）都留成 public，AppState 直接抓内部协议在用。OpenCode 那边走的是干净 facade。结果是 kit 同时存在两套 public 表面：facade 给"新 host"，protocol 给"老 host"。等于 kit 内部不能演进，因为 VoiceFlow app 在抓内部细节。

这次 PR 把 VoiceFlow app 也切到 facade，把那些只为 app 兼容而 public 的 internal 类型改回 internal。

- `AppState` 接收 `voiceFlowClient: VoiceFlowClient?` DI 参数（之前是 `realtimeTranscriptionClient: RealtimeTranscribing?`）；prod 路径用 `VoiceFlowClient(config:)`，UI test mode 用新加的 `VoiceFlowClient.makeStub()`。
- `AudioChunkEncoder` 不再被 host 持有 —— mic chunk 直接喂 `VoiceFlowSession.sendAudioChunk(_:)`，session 内部不要求精确 chunk size。
- 事件消费从 callback 改成 `AsyncStream<VoiceFlowEvent>`。AppState 起一个 consumer Task 在 startRecording 里 drain，在 cancel/teardown 里取消。
- `handleStreamEvent` 状态机简化：facade 把 `.error` / `.disconnected` 这种细分合并进 `phaseChanged` 和 `recoveryFailed`，buffer-too-small 噪音在 kit 内部就过滤掉了，AppState 不再需要那段冗余的双重防线。
- `Sources/VoiceFlowKit/Internal/` 下原本为兼容 app 而 public 的类型改回 internal：`RealtimeTranscribing` / `RealtimeLiveTranscriptionSession` / `RealtimeConnectionPhase` / `RealtimeTranscriptEvent` / `RealtimeTranscriptionError` / `RealtimeTranscriptionConfig` / `RealtimeMessageParser` / `RealtimeSocketEvent` / `RealtimeSessionCreateResponse` / `RealtimeTranscriptionSupport` / `RealtimeServerStatus` / `RealtimeSessionContext` / `RealtimeAPIURLBuilder` / `TranscriptDeltaReducer` / `TranscriptEpochMerger` / `PCM16WAVWriter` / `AudioChunkEncoder` / `MockRealtimeTranscriptionClient` / `RealtimeTranscriptionClient`。
- **保留 public**：`AIBuilderConnectionTesting` / `AIBuilderClient` / `MockAIBuilderConnectionClient`、`AudioRecording` / `AudioRecorder` / `MockAudioRecorder`、`AIBuilderTranscribing` / `AIBuilderTranscriptionClient` / `MockAIBuilderTranscriptionClient`。这三组是 AppState 的 DI 注入面，本身就是测试基础设施（UI test 不能起真 mic / 真网络）。`VoiceFlowMicrophone` 是 final class，host 想 mock 录音得不到注入点 —— 留着这三组让现状 ergonomic，下次想做"facade-only"再处理。
- 测试改造：VoiceFlowTests / RealtimeTranscriptionTests / LiveIntegrationTestSupport 改 `@testable import VoiceFlowKit`（之前是普通 import）。新加 `VoiceFlowKitTestHelpers.swift`：`makeStubVoiceFlowClient(liveResult:, bulkResult:)` 返回 `(VoiceFlowClient, MockRealtimeTranscriptionClient)`，让 AppState 测试可以塞 client + 仍能 emit live event。
- `streamRecoveryIgnoresBufferTooSmallDuringRecording` 这个测试被删 —— 它测的是"app 看到 `.error` 时忽略 buffer-too-small"，现在这种 error 在 facade 边界内被 kit 过滤掉、根本不进 `events` stream，app code 没法再 emit 它来测试。但语义在 kit 内部仍受 `shouldNotifyUI` 保护。
- 删了两份只在本地维护的 working doc：`docs/Library.md`（PR 5 v1.0.0 release 计划被推翻 —— 还在快速迭代不打 SemVer tag）和 `docs/code_review_2026-05-28.md`（这次复盘的产物，已落地）。
- 验收：Kit 10 tests + app 60 unit tests + UI smoke 3 tests，全过。

### 2026-05-28 (VoiceFlowKit 抽取 + 转写上下文 UI)

**PR #35 — VoiceFlowKit 抽取**

- 把 services 层 7 个文件（`AIBuilderClient`、`AIBuilderTranscriptionClient`、`AudioChunkEncoder`、`AudioRecorder`、`RealtimeTranscriptionClient`、`RealtimeWebSocketSender`、`RealtimeTranscriptEvent`/models）从 `src/VoiceFlow/VoiceFlow/Services/` 搬到 `Sources/VoiceFlowKit/Internal/`。
- 新 SPM package 在仓库根：`Package.swift` + `Sources/VoiceFlowKit/` + `Tests/VoiceFlowKitTests/`。
- App 通过本地 SPM dep 引 `../..`（pbxproj 加了 `XCLocalSwiftPackageReference`）。
- 公开 facade：`VoiceFlowClient` / `VoiceFlowSession` / `VoiceFlowMicrophone` / `VoiceFlowConfig` / `VoiceFlowError` / `StreamCaption` / `StreamCaptionStore`。
- 内部 protocol 也保持 public（`RealtimeTranscribing` / `AudioRecording` 等），让 VoiceFlow AppState 无需重构。新 host（OpenCode）应该用 facade，protocol 是兼容层。
- 4 个 BulkProgress regression test（PR #34 修过的 race）从 Xcode test target 搬到 SPM tests target——之前 swift-testing 在 Xcode 不 discover，搬走后 discover 正常。
- 验收：9 Kit tests + 59 unit tests + 11 UI tests + 手动全功能 smoke，0 行为退化。

**PR #36 — 转写上下文 UI**

- Settings 加 "Transcription" 分组，含 prompt + terms 两个字段（UserDefaults 持久化）。
- `VoiceFlowConfig` 加 `prompt` + `terms` 字段。库内部用 `RealtimeSessionContext` 结构传递，覆盖 `beginLiveSession` 和 `transcribeBulkPCM` 两条路径。Wire payload `/v1/audio/realtime/sessions` POST body 包含 `prompt` + `terms` keys（空时不出现）。
- 拿掉 PR #35 临时引入的 `language` 字段——backend 把语言提示当 prompt 拼接，独立 language 字段是冗余。
- `InputCardSurface` ViewModifier 加进 SettingsView，所有输入框（API token、OpenCode 字段、prompt、terms）共用"深底浮起浅色卡片"视觉。详细规则见 `docs/design.md` 的 "Settings 输入控件视觉" 章节。
- 4 个 Swift 6 concurrency warning 全清。Core protocol 标 `Sendable`，mock 标 `@unchecked Sendable`。
- Mock 加 `lastLiveContext` / `lastBulkContext`，新 unit test 验证 prompt/terms 进 wire 完整。
- `createRealtimeSession` 加 OSLog summary（`hasPrompt`/`promptChars`/`termsCount`），便于诊断 wiring 是否通。
- 验收：9 Kit tests + 61 unit tests + 12 UI tests，手动确认 prompt 真的影响转写输出（用"指令 + Example"形态的 prompt）。

**剩余工作**：OpenCode 切到 VoiceFlowKit 已于 PR #3（`grapeot/opencode_ios_client#52`）完成。

### 2026-05-27 (UX 重做：暖琥珀 / 深墨与纸白双模式)

设计方向锁定在 GPT image 生成的候选 B（夜间深墨 + 暖琥珀）与候选 D（日间纸白 + 同色琥珀点缀）。Spec 在 `docs/design.md`。

**新增**

- `DesignTokens.swift`：色板（夜/日双值，`Color(light:dark:)` 自动跟随 colorScheme）、字号、间距、尺寸常量集中。整个 app 不再出现 `Color.blue / .red / .gray.opacity(0.3)` 之类的 ad-hoc 写法。
- `WaveformView`：屏幕唯一视觉锚点。`.idle / .active / .generating` 三种模式，Canvas + TimelineView 驱动，36 根条形 bars。本版用合成动画（不接真实 audio level，AppState 还没暴露），但状态绑定到 `recordingStatus` + `streamConnectionPhase`，颜色按状态切换。
- `CapsuleButton`：替换 `ColoredButtonStyle`。胶囊形 + intrinsic 宽度，三种 role（primary / secondary / ghost），高 56pt，文字 + icon 都自适应——彻底修了之前英文 "Start Recordi…" 被截断的问题。
- `GhostIconButton`：替换历史 chevron / info button。圆形 36pt tap target，18pt SF Symbol，`text.tertiary` 色，disabled 态自然弱化。
- `StatusText`：替换 `RecordingStatusHeaderView`。一行 14pt 状态文字，无色点。状态全靠文字 + 波形颜色承载。

**删除**

- `Views/Components/ColoredButtonStyle.swift`
- `Views/Components/RecordingStatusHeaderView.swift`
- `Views/Components/RecordingTimerView.swift`

**重写**

- `RecordView`：标题 "VoiceFlow" 删除；六块横向 stack 压缩成"计时器 / 状态 / 波形 / 转写 / 主按钮 / ghost 控件行"的纵向单列；Copy 和 Send-to-OpenCode 从底部主按钮区域降级到 more menu；🧠 emoji 删除（OpenCode 改用 `paperplane` SF Symbol）。
- `SettingsView`：保留 Form 结构（V2 再做完整 list 重做），换 token 色板、清除 `RoundedBorderTextFieldStyle` 改成 plain，文案克制化（"Test Connection" → "Test"，"Save Token" → "Save"）。Save / Clear 与 Test 拆成两行避免 SwiftUI Form 同行多 button 的 hit-test 坑（这是第一轮 UI test 失败的直接原因）。
- `MainTabView`：`tint(.accent)`、tab bar 用 `.ultraThinMaterial` 半透明、图标改 outline 版本（`mic` / `gearshape`），选中态由系统填色。

**本地化**

en/zh 两套 `Localizable.strings` 同步更新：`record.start` "Start Recording" → "Record"；`record.status.recording` "Recording..." → "Listening" / "聆听中"；`record.transcript.placeholder` "Your transcription will appear here." → "Speak." / "开始说话。"；`settings.testConnection` → "Test"；`settings.apiToken.save` → "Save"。所有 key 不变。

**UI test 更新**

- 删除 `app.staticTexts["VoiceFlow"]` / `app.buttons["Start Recording"]` 等基于显示文案的断言；改用 `record.startButton` / `record.stopButton` 等 stable accessibilityIdentifier。
- `record.statusIndicator` 不再存在（色点已删），`waitForRecordingState(.ready)` 的对应 fallback 已撤。
- `testEnglishAppShell` 删除对独立 Copy / Send-to-OpenCode button 的断言（它们现在在 more menu 里），改为断言 `record.moreButton` 存在。
- `testMockRecordingFlowShowsTranscriptAndClipboardStatus` 在 Stop 之后先 tap `record.moreButton` 再 tap `record.sendOpenCodeButton`。
- `testChineseAppShell` 删除对顶部 "复制" 按钮的断言，改为通过 identifier 验证 Settings 的 Test 按钮存在。

**测试结果**

- 59 / 59 unit tests passed
- 11 / 11 UI tests passed（full suite，~200s 墙钟）

**截图**

模拟器 iPhone 17 Pro / iOS 26.3.1 抓的中英文 × 日夜共 4 张，存在 `docs/screenshots/redesign_*.png` 并嵌入 `docs/design.md` 的"实施结果"一节。

**Spec 未做项（留给 V2）**

- 真实 audio level → WaveformView：需要在 `AudioRecorder` 加 metering，再把 level 经 AppState 暴露给 view。本 PR 用合成动画做"在场感"。
- Settings 重做成自定义 list（而非 Form）：风险高、改动大，本 PR 只动色板、字体、文案。
- 自定义 tab bar 或"无 tab + 右上 gear"：本 PR 保留系统 TabView，只做视觉融入（`.tint` + material）。
- 转写区改 `New York` 衬线字体：先用 SF Pro Text，观察后再升级。

### 2026-05-27 (代码审查与脚本去重)

- 审查记录：`docs/code_review_2026-05-27.md`
- `voiceflow_run_ui_suite` 合并三个 `test_ui_*.sh` 的重复逻辑
- `launchVoiceFlowApp` launch 后等待 `record.startButton`（降低冷启动 flake）
- `AppState` init 与 `resetForUITest` 共用 `applyUITestLaunchArgumentSeeds()`

### 2026-05-27 (UI 测试分层与修复)

**问题（优化前，`./scripts/test_all.sh`）**：13 条 UI（含 perf + Launch 截图），5 条失败；墙钟 ~382s。失败原因包括：`record.statusIndicator` 在 XCUITest 不可见、语言切换后未切回 Record tab、Stop 后 `transcribing` 中间态导致误判、OpenCode 文本框 append 而非替换。

**措施（Phases A–F，按当前代码落地）**

| Phase | 内容 |
|-------|------|
| A | `test_ui_smoke.sh` / `test_ui_full.sh` / `test_ui_perf.sh` / `test_ui.sh`；`test_all.sh` = unit + ui_full |
| B | `AppState.resetForUITest()` + Settings `uitest.resetState`（共享 app 暂缓，用例仍 per-launch 保证隔离） |
| C | 长文本粘贴辅助保留于 support；短 token/密码用 `typeText` |
| D | `VoiceFlowUITestsPerformance` 独立；perf 不进 smoke/full |
| E | 修复上述失败用例；`RecordingStatusHeaderView` 补 `accessibilityElement()` |
| F | OpenCode UI 收窄为密码路径；流式录音 UX 由 `testMockStreamingRecordingUpdatesTranscript` 覆盖 |

**耗时对比（同机 iPhone 17 Pro pinned，2026-05-27）**

| 命令 | 结果 | 墙钟 / 备注 |
|------|------|-------------|
| 优化前 `test_all` | 5 failed / 13 UI | **~382s** |
| `test_unit.sh` | 59 passed | **~3.6s** |
| `test_ui_smoke.sh` | 3 passed | **~50s** |
| `test_ui_full.sh` | 11 passed | **~208s**（套件内 ~196s） |
| `test_ui_perf.sh` | 2 passed | **~30s** |
| `test_all.sh`（现） | unit + full | **~212s** |

Agent 默认仍只跑 `test_unit.sh`；发版前 `test_all.sh` 或 `test_ui_full.sh`。

### 2026-05-27 (recovery UX copy audit)

- **i18n (en/zh)**: align stream recovery captions with silent auto-recover behavior — `record.status.reconnecting` uses "Auto-recovering" (en); `record.status.reconnected` → "Stream restored" / "流已恢复"; `record.error.streamDisconnected` drops outdated "tap Stop to finish" choice framing during recording.

### 2026-05-27 (Swift 6 AudioRecorder warnings)

- **Isolation**: `FinalizeTranscriptAccumulator` → `nonisolated struct` (Sendable value state inside `RealtimeLiveSessionHandle` actor); MainActor reserved for AppState UI only.
- **Fix**: `deliverLiveSessionEvent` marked `nonisolated`; live session handle wired via `LiveSessionHandleBox` to avoid captured-var warnings in `@Sendable` closures.
- **Fix**: `MockLiveSession` actor replaced with `nonisolated MockLiveSessionProxy` struct forwarding to `MockRealtimeTranscriptionClient` actor (invalid `nonisolated` actor init removed).
- **Fix**: `makeFinalizePartialHandler()` uses `Task { @MainActor [weak self] in guard let self ... }`.
- **Build**: `SWIFT_STRICT_CONCURRENCY = complete` on VoiceFlow + VoiceFlowTests targets; 59 unit tests pass.

### 2026-05-27 (structured compare + MainActor + append merge)

- **Comparison doc** (table above): truncation = replace-on-`isNewResponse` vs OpenCode append; main-thread bugs = finalize partial callback off MainActor.
- **Fix**: `FinalizeTranscriptAccumulator` — append deltas, prefer longer partial vs `transcript_completed` snapshot (OpenCode-style).
- **Fix**: `makeFinalizePartialHandler()` — all finalize `@Published` updates via `Task { @MainActor }`; bulk partial callback already MainActor.
- **Fix**: `completeStopTranscriptionSuccess/Failure` synchronous on `@MainActor` AppState (no spurious `async`).

### 2026-05-27 (finalize race + double alert)

- **Double alert root cause**: stream finalize failure called `presentRecordError`, then bulk fallback also failed → second alert; socket teardown errors during `.transcribing` also triggered alerts before transcript landed.
- **Transcript-after-alert race**: finalize partial callback used async `Task { @MainActor }` while success check read `self.transcript` immediately → false `tooShort` + bulk fallback while stream text still in flight.
- **Fix**: unified stop state machine (`transcription_finalize_*` logs), `finalize` returns `String`, suppress stream errors during teardown/transcribing, single `presentRecordError` only after stream+bulk exhausted, `TranscriptEpochMerger` in finalize for recover retries.
- New diagnostics: `transcription_finalize_started/stream_done/stream_failed`, `transcription_stream_error_ignored`, `transcription_stop_failed`.

### 2026-05-26 (disconnect stop + finalize regression)

- **Root cause (short recording failure)**: `waitForFinalizeResult` used `TaskGroup.next()` racing `sendCommit` against the idle continuation — commit returned immediately, group cancelled the waiter, finalize exited before transcript events arrived → `tooShort`.
- **Fix**: start continuation wait + timeout tasks first, then `await sendCommit()`, then `await group.next()` so finalize blocks until `session_stopped`/transcript.
- **Stop-after-disconnect**: align with OpenCode — `commit` only when `enqueuedAudioBytes >= 100ms`; defer `stop` until `transcript_completed`; recover + replay if session bytes lag cache; bulk fallback from `last-recording.wav` on stream failure/tooShort.
- **Swift 6**: replace `BulkTranscriptionProgress`/`MockRealtimeTranscriptionClient` `NSLock` with actor isolation; live test `EventCollector` → actor.
- **VAD off for live stream** (align OpenCode): session create + `start` use `vad: false`; client owns commit on stop, avoids server-side empty-buffer VAD commits.
- **UX captions** (en/zh): `record.status.reconnecting`, new `record.status.reconnected`, updated `record.error.streamDisconnected`; silently ignore recoverable `buffer too small` during recording.

### 2026-05-26 (WebSocket failure recovery)

- 对齐 OpenCode 静默恢复：录音中 transient disconnect 不弹 modal；caption `record.status.reconnecting` / `record.error.streamDisconnected`
- `TranscriptEpochMerger`：`transcriptSnapshot` + `streamEpoch`，recover 后 `isNewResponse` 不 wipe 断线前文本
- Start 顺序：mic + cache 先启动，WebSocket deferred attach；recover 指数退避重试（最多 5 次）
- Stop/finalize 等待 recover；finalize 失败保留 partial（ready + caption，无 modal）
- 单元测试 51 项通过（+5 recovery/epoch tests）；live tests 仍 opt-in skip

### 2026-05-26 (Swift 6 + ticket WebSocket fix)

- 实时转写改 ticket 流程：POST `/v1/audio/realtime/sessions` → `wss://.../ws?ticket=`（修复 Bearer 直连 WS 的 -1011）
- 协议：`start` / PCM16 24kHz / `commit` / `stop`；事件 `session_ready`、`transcript_delta`、`transcript_completed`、`session_stopped`
- `RealtimeTranscriptionConfig` sample rate 48k → 24k；单元测试 48 项通过
- Swift 6 strict concurrency：WAV header nonisolated helpers、`RealtimeConnectionPhase` 手写 `==`、`BulkTranscriptionProgress` 锁、mock `nonisolated(unsafe)`；`SWIFT_STRICT_CONCURRENCY=complete` build 通过

### 2026-05-26 (live WebSocket integration tests)

- 新增 opt-in live 集成测试 `LiveWebSocketIntegrationTests`（真实 ticket WebSocket，对齐 Swift 6 / -1011 fix）
- `scripts/test_live_integration.sh`：`TEST_RUNNER_*` + `.voiceflow/live-ws-opt-in`；默认 unit 脚本 skip 该 suite
- live 验证（2026-05-26）：session create 200，`session_ready` + heartbeat ~0.9s；静音 PCM + commit/stop ~0.7s
- `.env.example` 补充 token 变量说明与安全提示；`.env` 仍 gitignore

### 2026-05-26 (layout)

- Record 页去掉 GeometryReader 百分比高度（原先四段合计 100%，再加 spacing/padding 导致 Copy / OpenCode 按钮溢出 tab bar）；改为 flex 布局，transcript 区占剩余空间并 `.clipped()`
- Record tab 包一层 `NavigationStack`，与 Settings 一致，避免 safe area 处理不对称
- 录音计时器 top padding 16pt → 8pt；按钮区 bottom padding 20pt → 8pt

### 2026-05-26

- 创建 VoiceFlow 公开仓库与文档骨架（PRD / RFC / test / AGENTS）
- 建立 Record / Settings 双 tab 与中英本地化
- 接入 Xcode 工程、app icon 与 visionOS 资产
- AI Builder token 存 Keychain，支持连接测试
- 录音到转写主路径：48 kHz WAV 上传、自动复制、最近 5 条历史
- 可选 OpenCode 发送（session + prompt_async，Basic Auth）
- OpenCode URL 校验：HTTPS 必须、localhost 与 Tailscale `*.ts.net` 允许 HTTP
- OpenCode 连接测试通过后才启用发送按钮
- Record / Settings GUI 对齐参考实现
- 录音诊断 OSLog 与单元测试（不含 token / 转写正文）
- Settings 语言偏好：System / English / 简体中文
- Record 页 VoiceFlow 标题 + 状态指示灯；录音错误改 alert
- 修复部分设备 AVAudioSession paramErr 导致录音启动失败
- 历史 chevron 双向导航；三点菜单保存/重发录音
- 持久化 last-recording.wav；保存到 Documents（UIFileSharingEnabled）
- Settings OpenCode 清除仅删密码；连接失败显示 detail；点击空白收起键盘
- deep link `voiceflow://record` 启动录音
- privacy review 通过；发布到 GitHub `grapeot/voiceflow`
- Info.plist ATS 为 `ts.net` 加例外，修复 OpenCode HTTP `-1022`
- 保存录音后弹窗提示 Files 路径（On My iPhone → VoiceFlow）
- 录音计时 MM:SS；Start/Stop 按钮宽 120pt
- 转写框右下角显示字符数
- V1 实时流式转写设计写入 PRD / RFC（WebSocket、Stop finalize、增量 text）
- 新增 `test_unit.sh` / `test_all.sh` 与 Simulator pinning
- 单元测试 37 项；UI tests 在 `src/VoiceFlow/VoiceFlowUITests/`
- 删除脚手架占位：根目录 `tests/`、各目录 `.gitkeep`；文档标明测试在 Xcode target

### 2026-05-26（V1 实时流式转写）

- 实现 WebSocket 实时转写 + 断线恢复（disk cache replay，对齐 OpenCode iOS `RealtimeSpeechStreamer` 模式）
- 新增 `RealtimeTranscriptionClient`、`AudioChunkEncoder`、`AudioChunkCache`、`RealtimeWebSocketSender`
- `AudioRecorder` 改为 AVAudioEngine 流式 PCM；Stop 仍写 WAV 供保存/重发
- `AppState` 集成 live session、heartbeat、scene phase、stream 状态灯与 throttle 剪贴板
- 重发录音改 bulk WebSocket（`transcribeBulkPCM`）
- 单元测试 46 项（+8 RealtimeTranscriptionTests）；UI spec `testMockStreamingRecordingUpdatesTranscript` 已添加未执行

## Lessons Learned

- 对外文档只写 VoiceFlow 产品状态，不写内部实现来源
- OpenCode 必须可选，不能阻塞语音输入主路径
- Xcode synchronized groups：新 Swift 文件放进 `VoiceFlow/` 即进 target；以 `xcodebuild` 为准，LSP 可能看不到 test target
- 运行时语言切换要用显式 `.lproj` bundle，不能只靠 SwiftUI `\.locale`
- model 存 localization key，不存已翻译字符串
- `AVAudioSession.setPreferred*` 是 preference，失败不应阻断录音
- Tailscale HTTP 需应用层校验 + Info.plist ATS 例外两层都做
- 保存到 Documents 需 `UIFileSharingEnabled`，否则 Files app 不可见
- sandbox file URL 不要直接给 `UIActivityViewController`（真机 `-10814`）
- iOS 无法 deep link 到 app Documents 目录，只能文字指引用户去 Files
- 测试代码在 `src/VoiceFlow/VoiceFlowTests/`，不是根目录 `tests/`
- 共享 HTTP mock 的 Swift Testing suite 需 `@Suite(.serialized)`
- 日常只跑 `./scripts/test_unit.sh`；UI tests 发版前或用户明确要求再跑
