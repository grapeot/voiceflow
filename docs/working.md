# Working Notes

## Changelog

### 2026-05-26

- 创建 VoiceFlow 项目文档骨架。
- 明确 V0 只包含 Record 和 Settings 两个 tab。
- 确定 API token 使用 Keychain 保存，API 请求使用 Bearer auth。
- 将产品主目标调整为纯粹语音输入，OpenCode 发送改为可选增强。
- 明确转写完成后自动写入系统剪贴板，Universal Clipboard 由系统同步。

## Lessons Learned

- 对外文档只描述 VoiceFlow 的最终产品状态，不记录任何实现来源或非产品上下文。
- V0 的主路径是语音识别和剪贴板输入；OpenCode 配置必须保持可选。
