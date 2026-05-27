# VoiceFlow

VoiceFlow 是一个面向 iPhone、iPad 和 Apple Vision Pro 的语音输入工具。它把录音、转写、自动复制到剪贴板、历史浏览和可选 OpenCode 发送放在一个极简流程里。

Public repo: https://github.com/grapeot/voiceflow

## 产品边界

V0 只有两个 tab：Record 和 Settings。

Record：开始/停止录音、转写显示、自动复制、左右历史、保存/重发录音、手动复制；OpenCode 配置且连接测试通过后可发送。

Settings：AI Builder token（Keychain）、固定 endpoint 说明、可选 OpenCode（URL/username 保留在本机，password 在 Keychain）、语言偏好（System / English / 简体中文）。

外观仍跟随系统；Settings 手动 Light/Dark 尚未实现。

## Deep Link

```text
voiceflow://record
```

Shortcuts 中「打开 URL」→ 绑定 Action Button 或主屏幕。详见 README 与 `docs/rfc.md`。

## 开发状态（2026-05-26）

V0 核心功能已在 `master` 交付：录完上传转写、诊断日志、OpenCode gating、privacy review、deep link 等。剩余主要项：Settings 外观偏好；UI test suite 发版前需完整跑通。

## 仓库结构

```text
docs/                         # PRD、RFC、测试说明、变更记录
scripts/                      # test_unit.sh、test_all.sh、pin_simulator.sh
src/VoiceFlow/
  VoiceFlow.xcodeproj
  VoiceFlow/                  # App 源码
  VoiceFlowTests/             # 单元测试（Swift Testing）
  VoiceFlowUITests/           # UI 测试（XCUITest）
```

测试在 Xcode target 里，不在仓库根目录。日常与发版前：

```bash
./scripts/test_unit.sh    # 日常
./scripts/test_all.sh     # 发版前
```

## 隐私与凭据

仓库只保留 fake 示例。真实 token 存本机 Keychain；见 `.env.example`。

## 文档

- `docs/prd.md`：产品与 V0 交付状态
- `docs/rfc.md`：技术设计与模块结构
- `docs/test.md`：测试命令与覆盖范围
- `docs/working.md`：变更记录
