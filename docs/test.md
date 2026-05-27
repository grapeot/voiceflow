# 测试与验收策略

## 日常验证

源码入口：`src/VoiceFlow/VoiceFlow.xcodeproj`

日常开发优先 unit tests（mock，不依赖真实 token/网络/麦克风）：

```bash
./scripts/test_unit.sh
```

改 UI 或发版前再跑完整 suite：

```bash
./scripts/test_all.sh
```

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

共享 HTTP mock 的 suite 使用 `@Suite(.serialized)`。

## UI 测试（VoiceFlowUITests）

XCUITest，launch argument `-uiTestMode` 启用内存 Keychain 与 mock 服务。覆盖英文/中文 shell、token 保存、mock 录音流、OpenCode 配置、语言切换、Settings UX、deep link 启动录音等。

部分 UI test 在快速迭代中可能未每次跑通；发版前应执行 `./scripts/test_all.sh` 并修复失败项。

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
