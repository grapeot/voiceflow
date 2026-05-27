# VoiceFlow

VoiceFlow 是一个面向 iPhone、iPad 和 Apple Vision Pro 的语音输入工具。它把录音、转写、自动复制到剪贴板和历史回滚放在一个极简流程里。OpenCode 发送是可选配置，不影响基础语音输入体验。

Public repo: https://github.com/grapeot/voiceflow

## 产品边界

V0 只有两个 tab：Record 和 Settings。Record 负责开始录音、停止录音、查看当前转写、自动复制到剪贴板、在最近历史中回滚、手动复制文本。Settings 保存 AI Builder Space API token，并提供可选 OpenCode 配置；AI Builder Space endpoint 使用应用内默认值，不在 UI 中开放修改。

应用默认按系统语言自动切换中文和英文。中文环境显示中文，其他环境默认英文；用户也可以在 Settings 中固定使用 English 或简体中文。

## Deep Link

VoiceFlow 注册 URL scheme `voiceflow`，支持从 Shortcuts、Action Button 或桌面快捷方式直接开始录音：

```text
voiceflow://record
```

在 iOS 快捷指令中新建「打开 URL」动作，填入上述地址，再绑定到 Action Button 或主屏幕即可。Deep link 只触发本地开始录音，不接受 token、文本或其他外部参数。

## 开发状态

VoiceFlow V0 已实现 Record / Settings 双 tab、Keychain token、录完上传转写、剪贴板自动复制、可选 OpenCode 发送，以及中英文界面。仓库代码与文档按可公开发布标准维护。

源码入口：`src/VoiceFlow/VoiceFlow.xcodeproj`

快速验证：

```bash
./scripts/test_unit.sh
```

## 隐私与凭据

仓库只保留 fake 示例。真实 token、`.env`、本地日志、构建产物和录音文件都不能提交。开发时把真实 token 存到本机环境或 App Keychain；示例配置见 `.env.example`。

## 文档

- `docs/prd.md`：产品目标、用户流程和 V0 范围
- `docs/rfc.md`：技术设计、API 鉴权、数据流和实现计划
- `docs/test.md`：测试与验收策略
- `docs/working.md`：变更记录和后续决策
