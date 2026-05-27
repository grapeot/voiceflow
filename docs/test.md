# 测试与验收策略

测试代码在 Xcode target 内：`src/VoiceFlow/VoiceFlowTests/`（单元）、`src/VoiceFlow/VoiceFlowUITests/`（UI）。仓库根目录没有 `tests/` 文件夹。

## Agent / 日常验证

**默认只跑 unit test。** 除非用户明确要求 UI test，否则只执行：

```bash
./scripts/test_unit.sh
```

`test_unit.sh` 会 **跳过** `LiveWebSocketIntegrationTests`（不会连真实 WebSocket，也不读 `.env`）。

只有用户主动要求跑 UI test、或明确说跑完整测试 suite 时，才执行：

```bash
./scripts/test_all.sh
```

### Simulator 自适应 pinning

`test_unit.sh` 和 `test_all.sh` 会自动：

1. 在本机 `.voiceflow/simulator-udid` 记录一台匹配的 iPhone 17 Pro（iOS 26.3.1）UDID
2. 第一次运行时发现并 boot 这台 Simulator（较慢，正常）
3. 后续运行复用同一 UDID 和已 boot 的 Simulator，优先 `test-without-building`；若无可用测试产物则自动 `build-for-testing` 后再测

手动预热（可选）：

```bash
./scripts/pin_simulator.sh
```

覆盖默认设备或 destination：

```bash
export VOICEFLOW_SIMULATOR_NAME="iPhone 17 Pro"
export VOICEFLOW_SIMULATOR_OS="26.3.1"
export VOICEFLOW_TEST_DESTINATION="platform=iOS Simulator,id=<UDID>"  # 完全跳过 pinning
export VOICEFLOW_TEST_REBUILD=1  # 强制先 build-for-testing 再测
```

`.voiceflow/` 是本地状态目录，已 gitignore，不会进仓库。

### 其他验收命令

visionOS build（无 UI test）：

```bash
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO build
```

隐私扫描：

```bash
rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]+)' .
rg --files -g '*.m4a' -g '*.wav' -g '*.caf'
```

预期：凭据模式零匹配；仓库内无提交音频样本（测试用临时文件除外）。

## 单元测试（VoiceFlowTests）

Swift Testing + mock。当前覆盖包括但不限于：

- AppState 初始状态、语言偏好持久化
- Keychain token / OpenCode password 保存、清除（OpenCode 清除保留 URL/username）
- AI Builder / OpenCode 连接测试与发送（含 mock HTTP、`URLProtocol`）
- OpenCode URL 校验（HTTPS、Tailscale HTTP、拒绝 remote HTTP）
- 录音主路径（mock recorder/transcriber/clipboard）
- 录音诊断事件与安全摘要（不含 token/transcript）
- TranscriptHistory 双向导航、保存/重发录音
- Deep link 解析、`voiceflow://record` 触发录音、未知 URL 忽略
- Multipart 上传 body 格式
- **V1 实时转写**：`RealtimeMessageParser`、`TranscriptDeltaReducer`、`TranscriptEpochMerger`、recovery caption（录音中无 modal）、`AudioChunkEncoder`、WAV PCM roundtrip、mock live session

共享 HTTP mock 的 suite 使用 `@Suite(.serialized)`。

## Live WebSocket 集成测试（opt-in）

针对 AI Builder Space 真实 endpoint 的回归测试，用于开发时检查 wire format 与 auth。默认 **不运行**。

### 前置条件

1. 复制 `.env.example` → `.env`（已在 `.gitignore`，勿提交）
2. 在 `.env` 填入 `AI_BUILDER_TOKEN`（或 `VOICEFLOW_AI_BUILDER_TOKEN`）
3. **若 token 曾出现在聊天、截图或日志中，请先在 AI Builder Space 轮换密钥**

### 启用与运行

```bash
cp .env.example .env
# 编辑 .env，填入真实 token

chmod +x scripts/test_live_integration.sh   # 首次
./scripts/test_live_integration.sh
```

脚本会：

- 设置 `VOICEFLOW_LIVE_WS=1` 与 `TEST_RUNNER_*` 变量（Xcode 会把 `TEST_RUNNER_` 前缀去掉后注入 test runner）
- 写入 `.voiceflow/live-ws-opt-in` 标记（备用：当 env 未注入时，测试从 `#filePath` 定位 repo 并读 `.env`）
- 从 `.env` 加载 token / endpoint
- 仅跑 `-only-testing:VoiceFlowTests/LiveWebSocketIntegrationTests`
- 使用与 `./scripts/test_unit.sh` 相同的 Simulator pinning

也可手动指定环境变量（token 不进 shell history 时可用）：

```bash
export VOICEFLOW_LIVE_WS=1
export VOICEFLOW_REPO_ROOT="$PWD"
export AI_BUILDER_TOKEN='your-token'
./scripts/test_live_integration.sh
```

强制 rebuild：`VOICEFLOW_TEST_REBUILD=1 ./scripts/test_live_integration.sh`

### 成本与行为

- **会消耗 AI Builder API credits**（创建 realtime session、建立 ticket WebSocket、可选 PCM 静音块、`commit` + `stop`）
- 无 token 或未设 `VOICEFLOW_LIVE_WS=1` 时，live suite 内测试立即 return（通过但不连网）
- 超时：握手 ~15s，finalize ~25s，避免 hang

### 覆盖项（`LiveWebSocketIntegrationTests`）

- POST session create + ticket WebSocket 握手
- `start` 控制消息后收到 `session_ready` / connected 状态
- WebSocket ping（heartbeat）
- 发送一帧 PCM16 静音 + `commit`/`stop`，期望 `generating` 或 `session_stopped`（idle）

Wire format 注释见 `RealtimeTranscriptionTests.swift` 内 `LiveWebSocketIntegrationTests` suite。

### 示例输出（live run 成功）

```
Running live WebSocket integration tests (consumes AI Builder API credits).
Endpoint: https://space.ai-builders.com/backend
◇ Suite LiveWebSocketIntegrationTests started.
✔ Test liveWebSocketHandshakeAndStartRecording() passed after 0.938 seconds.
✔ Test liveWebSocketAcceptsPCMChunkAndStopRecording() passed after 0.715 seconds.
✔ Suite LiveWebSocketIntegrationTests passed after 1.654 seconds.
```

Session create 响应示例（Bearer POST）：

```json
{"session_id":"ws_sess_...","ticket":"...","ws_url":"/backend/v1/audio/realtime/ws?ticket=...","expires_in":300}
```

## UI 测试（VoiceFlowUITests）

XCUITest，launch argument `-uiTestMode` 启用内存 Keychain 与 mock 服务。覆盖英文/中文 shell、token 保存、mock 录音流、OpenCode 配置、语言切换、Settings UX、deep link 启动录音等。

**V1 新增 spec（已实现，默认不执行）**

- `testMockStreamingRecordingUpdatesTranscript`：mock 流式转写后 transcript 非空、状态回到 ready、剪贴板 caption 出现。

仅在用户明确要求或发版前执行 `./scripts/test_all.sh`。

## 手工验证清单

- 首次启动 → Settings 保存 token → Test Connection
- Record 录音 → 停止 → 转写 → 自动复制
- 历史 chevron、保存/重发菜单
- OpenCode 配置、连接测试、发送（或 mock 环境验证按钮状态）
- 语言切换
- Shortcuts 打开 `voiceflow://record`（真机）
- 无 token / 无麦克风权限时的错误提示

## 文档与仓库验收

公开文档齐全：`README.md`、`docs/prd.md`、`docs/rfc.md`、`docs/test.md`、`docs/working.md`、`AGENTS.md`。`.env.example` 仅含 fake 示例。
