# VoiceFlow PRD

## 目标

VoiceFlow 是一个纯粹的语音输入工具。它要解决的是现有语音输入工具控制感不足的问题：用户只是想把话准确、快速地变成文字，产品就应该只做转写，不主动回答、不润色、不改写用户意图。

V0 的核心目标有两层。第一，语音识别准确率高、速度快，输出尽量贴近用户原话。第二，转写完成后自动把文本放进系统剪贴板，让用户可以立刻粘贴到任何 app。OpenCode 是可选增强配置，不配置也不影响 VoiceFlow 作为语音输入工具使用。

## V0 交付状态（2026-05-26）

已在 `master` 交付：Record / Settings 双 tab、GUI 对齐、Keychain token、录完上传转写、自动复制、双向历史导航、保存/重发录音、可选 OpenCode（含连接测试 gating）、录音诊断日志、语言偏好（System / English / 简体中文）、Settings 键盘收起与连接失败 detail、privacy review、GitHub 发布（https://github.com/grapeot/voiceflow）、deep link（`voiceflow://record`）。

尚未交付：Settings 外观偏好（System / Light / Dark 手动选择）。当前 UI 跟随系统日间/夜间模式。

## 用户

第一类用户是高频使用语音输入的人。他们需要把口述内容快速变成可粘贴文本，并且希望工具忠实转写，不擅自进行问答、总结或润色。

第二类用户是跨设备工作的人。他们希望在 iPhone、iPad 或 Vision Pro 上完成语音识别后，通过 Universal Clipboard 在 Mac 上直接粘贴。

第三类用户是 OpenCode 用户。他们希望在需要时把转写文本发送给 OpenCode，但这只是可选路径。

第四类用户是 iPhone 重度快捷操作用户。他们可以通过 Shortcut、Action Button 或桌面快捷方式打开 `voiceflow://record`，直接开始录音。

## 平台

V0 支持 iOS、iPadOS 和 visionOS。三端共享 SwiftUI 代码和业务逻辑，视觉布局优先保持简单一致。visionOS 先采用窗口式表单和录音界面，不做空间化交互。

## V0 功能范围

应用只有两个 tab。

Record tab 包含开始录音、停止录音、录音状态、转写文本显示、自动复制到剪贴板、左右 chevron 浏览最近历史、手动复制文本、三点菜单中的保存录音与重发录音。用户配置 OpenCode 并通过连接测试后，Record tab 额外显示发送到 OpenCode 的入口。历史只保存在本机，默认保留最近 5 条。

Settings tab 包含 AI Builder Space API token 输入、保存状态、连接测试结果和默认 endpoint 说明。endpoint 固定为 AI Builder Space 默认地址，不提供编辑入口。Settings 还包含可选 OpenCode 配置（server URL、username、Keychain password）；清除操作只删除 password，URL 和 username 保留。OpenCode 连接测试失败时展示具体错误信息。

Settings tab 包含语言偏好：System、English、简体中文；默认 System。外观偏好（System / Light / Dark）列入 V0 范围但尚未实现。

Deep link：`voiceflow://record` 已注册。打开 app 后切到 Record tab 并复用现有开始录音流程；不接受 token、文本或其他外部 payload。

## 明确不做

V0 不包含文档编辑器、自动修正按钮、自定义 prompt 按钮、转写模型选择、Apple Watch app、网页登录、账号系统、云端历史同步、录音库长期管理和复杂工作流编排。

菜单中的「保存录音」是把最近一次录音导出到 Documents，不是内置录音库。Deep link 只服务于直接开始录音，不扩展成通用自动化接口。

## 用户流程

首次启动时，用户进入 Settings，粘贴 AI Builder Space API token，点击 Test Connection。验证通过后回到 Record。OpenCode 配置可以跳过。语言默认跟随系统；用户可在 Settings 切换 English 或简体中文。

日常使用时，用户点击 Start Recording。应用请求麦克风权限，显示录音状态并采集音频。用户点击 Stop 后，应用完成转写，把文本显示在 Record 页，并自动复制到系统剪贴板。

用户可以手动复制文本；配置 OpenCode 并通过连接测试后，可发送到 OpenCode。发送成功或失败都有明确状态，文本和剪贴板内容保留。

用户可用左右 chevron 在最近 5 条转写间切换；三点菜单可保存 WAV 到 Documents 或重发最近一次录音做转写。

快捷启动：在 Shortcuts 中创建「打开 URL」动作，地址填 `voiceflow://record`，绑定到 Action Button 或主屏幕。token 缺失或麦克风不可用时显示本地化错误，不静默失败。

## 双语要求

App UI 默认使用系统语言。用户可在 Settings 中手动选择 English 或简体中文。所有用户可见字符串进入本地化资源，不硬编码在 SwiftUI view 中。

## 外观要求

App 当前跟随系统日间/夜间模式。计划中的 Settings 外观偏好（System / Light / Dark）尚未实现；落地后 Record 和 Settings 应使用语义颜色，保证浅/深模式下对比度足够。

## 录音诊断要求

录音失败需要能定位阶段：权限、录音启动/停止、空音频、上传转写、响应解析、自动复制、OpenCode 发送。诊断日志只记录安全摘要，不记录 token、转写文本、音频内容或原始 API 响应。

## 安全与隐私

API token 与 OpenCode password 存在 Keychain。OpenCode server URL 和 username 存在 UserDefaults。仓库只包含 fake 配置示例。

转写走 AI Builder Space；OpenCode 发送前用户能看到当前文本。deep link 不携带外部 payload。

## 发布要求

代码、文档、测试按可公开发布标准维护。公开仓库：`grapeot/voiceflow`，默认分支 `master`。

## 成功标准

V0 完成条件：iOS / visionOS 模拟器可构建；Record / Settings 可运行；token Keychain 保存与连接测试；录音转写与自动复制；历史导航与保存/重发；OpenCode 可选且 gating 正确；语言偏好；隐私扫描无真实凭据；deep link 可用并有单元测试。外观手动选择为剩余项。
