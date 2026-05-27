# VoiceFlow Agent Notes

本项目工作语言是中文。面向用户的 App 文案需要中英文双语，随系统语言自动切换。

## 项目定位

VoiceFlow 是面向 iOS 和 visionOS 的语音记录 app。仓库内容按可发布到 GitHub 的标准处理，因此所有文档、示例、测试和代码都只能包含可公开的信息。

## 目录结构

- `docs/prd.md`：产品需求和 V0 范围
- `docs/rfc.md`：技术方案和 V0 交付状态
- `docs/test.md`：测试策略和验收命令
- `docs/working.md`：每日变更记录和经验教训
- `src/VoiceFlow/VoiceFlow.xcodeproj`：Xcode 工程
- `src/VoiceFlow/VoiceFlow/`：App 源码
- `src/VoiceFlow/VoiceFlowTests/`：单元测试
- `src/VoiceFlow/VoiceFlowUITests/`：UI 测试
- `scripts/`：`pin_simulator.sh`、`test_unit.sh`、`test_ui_smoke.sh`、`test_ui_full.sh`、`test_ui_perf.sh`、`test_all.sh`

不要新建仓库根目录 `tests/`；测试只放在上述 Xcode target 中。

## 硬性规则

1. 不提交真实 token、`.env`、录音文件、日志、构建产物或设备私有配置。
2. 对外文档只描述 VoiceFlow 的最终产品状态，不写内部来源、私有项目、私有账号或不可公开的历史上下文。
3. V0 只保留 Record 和 Settings 两个 tab，不加入编辑器、第二大脑、多模型选择、自动修正、自定义按钮或 Watch 功能。
4. Settings 只允许用户输入 AI Builder Space API token。默认 endpoint 由应用固定，不在 UI 中开放修改。
5. 每次非平凡变更后更新 `docs/working.md`，记录完成内容、验证结果和影响后续实现的决策。
6. 初始化或修改 Xcode 工程后，`xcodebuild build` 和 `xcodebuild test` 必须串行执行。

## 推荐实现方向

优先构建一个小而清晰的 SwiftUI app。可以复用经过确认的实现模式：Keychain 存 token、Bearer auth 注入、AVFoundation 录音、系统剪贴板写入、SwiftUI 双语资源、actor 化 API client。具体文件复制必须先经过隐私检查。
