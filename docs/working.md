# Working Notes

## Changelog

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
