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

## Lessons Learned

- 对外文档只描述 VoiceFlow 的最终产品状态，不记录任何实现来源或非产品上下文。
- V0 的主路径是语音识别和剪贴板输入；OpenCode 配置必须保持可选。
- 当前 Xcode 工程使用 file-system synchronized groups，新 Swift 文件放进 `src/VoiceFlow/VoiceFlow/` 后会自动进入 target。
- 独立 LSP 无法解析 Xcode 测试 target 的 `Testing` / `XCTest` 模块，测试文件以 target-aware `xcodebuild test` 为准。
