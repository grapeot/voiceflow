# VoiceFlow 代码审查（2026-05-27）

范围：UI 测试优化合并（PR #29）后的可维护性与测试基建。不含产品功能扩展。

## 结论摘要

PR #29 把 agent 默认路径从「全量 UI、常失败」收成「unit ~4s + 按需 smoke/full/perf」，方向正确。当前主要技术债集中在：UI 用例列表双处维护风险、共享 app 尚未启用、`resetForUITest` 异步边界、以及 Xcode DerivedData 陈旧导致假性 30s 主线程阻塞。

## 测试基建

### 已改善

- 分层脚本与 `parallel-testing-enabled NO` 保留，单元 mock 稳定。
- 失败根因已对齐到可观测元素（`record.startButton` / `record.stopButton`、剪贴板 caption），不再依赖不可见的 status 圆点。
- Perf 与 Launch 截图移出默认路径，避免 smoke 被 `measure`×5 拖慢。

### 待关注

| 项 | 说明 | 建议优先级 |
|----|------|------------|
| 用例清单唯一来源 | 列表在 `scripts/lib/test_ui_common.sh`；改 smoke/full 时只改一处 | 已 OK，需在 review 时自觉同步 |
| 共享 app | `resetForUITest` + `uitest.resetState` 已就绪，用例仍 per-launch | 中：稳定后再切共享 app，可再省 ~30–40% full 时间 |
| `resetForUITest` 异步 | Settings 按钮里 `Task { await }`，XCTest 若依赖 reset 需 sleep | 低：共享 app 启用前用 launch 隔离即可 |
| DerivedData 陈旧 | 修改 UITest 后偶发 30s snapshot 超时、用例逻辑未执行 | 高：文档已写 `VOICEFLOW_TEST_REBUILD=1`；脚本可在 rebuild fallback 前检测 |
| `test_ui_*.sh` 重复 | 三个脚本仅 suite 名不同 | 高：合并为 `voiceflow_run_ui_suite`（本次 PR2 做） |

## 应用代码

### AppState.resetForUITest()

逻辑完整：取消 live session、清 Keychain/Defaults、再按 launch argument 种子。与 init 里 `-uiTestResetPreferences` 分工清楚（冷启动 vs 热重置）。

改进点：`applyUITestLaunchArgumentSeeds()` 与 init 内种子代码重复，后续可抽一个 `private func seedUITestFixtures()` 供两处调用，减少 drift。

### Settings `uitest.resetState`

仅 `-uiTestMode` 可见，不污染正式发布。文案英文即可（测试专用）。

### RecordingStatusHeaderView

`accessibilityElement()` 让 status 圆点进入 a11y 树，利于 VoiceOver 与备用断言；主路径仍应用 button identifier。

## UI 测试用例集

- OpenCode UI 收窄为密码保存/连接/清除：与单元测试分工合理。
- `testSettingsLanguagePreferenceOverridesSystemLanguage` 在 zh 模拟器 locale 下断言「开始录音」而非英文，符合「System = 跟随系统」语义。
- `testRecordingControlsExposeHistoryNavigationAndSaveResendMenu` 对 resend 只断言回到 ready，不强制第二次剪贴板文案（避免与节流逻辑打架）。

可选后续：为 stream recovery caption 加一条 smoke 级 UI（断线 caption 出现），依赖 mock 注入 disconnect。

## 文档与 Agent 路径

`docs/test.md`、`AGENTS.md`、`working.md` 已与脚本一致。Agent 默认 `test_unit.sh` 的约束应继续保持。

## 本次 PR2 采纳项（高 ROI）

1. **`voiceflow_run_ui_suite`**：合并三个 `test_ui_*.sh` 的重复 shell。
2. **`launchVoiceFlowApp` 启动等待**：launch 后等待 `record.startButton`，降低冷启动抖动。
3. **本文档**：供后续 housekeeping 对照。

## 刻意推迟

- Xcode Test Plan（`.xctestplan`）替代 bash `-only-testing`：Xcode GUI 友好，Agent/CI 仍以脚本为准，暂不引入双轨。
- 共享 app 默认开启：需先证明 `resetForUITest` 与 XCTest 时序稳定。
- 删除 `uitest.resetState`：保留给调试与下一阶段的共享 app 实验。
