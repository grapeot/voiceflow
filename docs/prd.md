# VoiceFlow PRD

## 目标

VoiceFlow 是一个纯粹的语音输入工具。它要解决的是现有语音输入工具控制感不足的问题：用户只是想把话准确、快速地变成文字，产品就应该只做转写，不主动回答、不润色、不改写用户意图。

V0 的核心目标有两层。第一，语音识别准确率高、速度快，输出尽量贴近用户原话。第二，转写完成后自动把文本放进系统剪贴板，让用户可以立刻粘贴到任何 app。OpenCode 是可选增强配置，不配置也不影响 VoiceFlow 作为语音输入工具使用。

当前实现阶段还要补齐四个产品体验要求：Record 和 Settings 的 GUI 达到 V0 可用布局；录音失败时提供可诊断但不泄露隐私的日志；中英文界面既能跟随系统，也能由用户手动选择；日间和夜间模式既能跟随系统，也能由用户手动选择。

## 用户

第一类用户是高频使用语音输入的人。他们需要把口述内容快速变成可粘贴文本，并且希望工具忠实转写，不擅自进行问答、总结或润色。

第二类用户是跨设备工作的人。他们希望在 iPhone、iPad 或 Vision Pro 上完成语音识别后，通过 Universal Clipboard 在 Mac 上直接粘贴。

第三类用户是 OpenCode 用户。他们希望在需要时把转写文本发送给 OpenCode，但这只是可选路径。

第四类用户是 iPhone 重度快捷操作用户。他们希望通过 Shortcut、锁屏按钮或 Action Button 触发 VoiceFlow 直接开始录音，减少打开 app 后再点一次 Start 的操作成本。

## 平台

V0 支持 iOS、iPadOS 和 visionOS。三端共享 SwiftUI 代码和业务逻辑，视觉布局优先保持简单一致。visionOS 先采用窗口式表单和录音界面，不做空间化交互。

## V0 功能范围

应用只有两个 tab。

Record tab 包含开始录音、停止录音、录音计时或录音状态、转写文本显示、自动复制到剪贴板、最近历史切换、回滚到历史版本、手动复制文本。用户配置 OpenCode 后，Record tab 额外显示发送到 OpenCode 的入口。历史只保存在本机，默认保留最近 5 条，后续可以扩展为可配置数量。

Settings tab 包含 AI Builder Space API token 输入、保存状态、连接测试结果和默认 endpoint 说明。endpoint 固定为 AI Builder Space 默认地址，不提供编辑入口。Settings 还包含可选 OpenCode 配置；未配置时，VoiceFlow 仍然可以完成录音、转写、自动复制和历史回滚。

Settings tab 还包含两个用户偏好。语言偏好提供 System、English、简体中文三个选项；默认 System，跟随系统界面语言。外观偏好提供 System、Light、Dark 三个选项；默认 System，跟随系统日间/夜间模式。两个偏好都应使用紧凑、明确的 segmented 或 switch-like 控件，放在 Settings 页面底部，避免干扰 token 配置主流程。

发布到 GitHub 后，最后补充 deep link 能力。VoiceFlow 应注册一个公开 URL scheme，用于从 Shortcuts 或 Action Button 打开 app 并直接开始录音。V0 deep link 只支持启动录音这一件事，不加入复杂命令路由。

## 明确不做

V0 不包含文档编辑器、自动修正按钮、自定义 prompt 按钮、转写模型选择、Apple Watch app、网页登录、账号系统、云端历史同步、录音文件长期保存和复杂工作流编排。

这些功能会显著增加产品解释成本和隐私边界。V0 先把单一路径做可靠。Deep link 也只服务于直接开始录音，不扩展成通用自动化接口。

## 用户流程

首次启动时，用户进入 Settings，粘贴 AI Builder Space API token，点击 Test Connection。验证通过后回到 Record。OpenCode 配置可以跳过。语言和外观默认跟随系统；如果用户有固定偏好，可以在 Settings 底部切换。

日常使用时，用户点击 Start Recording。应用请求麦克风权限，开始计时或显示录音状态并采集音频。用户点击 Stop 后，应用完成转写，把文本显示在 Record 页，并自动复制到系统剪贴板。只要用户的设备启用了 Apple Universal Clipboard，这段文本就可以在同一 Apple 账号下的其他设备上粘贴。

用户可以再次手动复制文本，也可以在配置 OpenCode 后点击 Send to OpenCode。发送成功后显示明确的成功状态；发送失败时显示可读错误，并保留文本和剪贴板内容。

如果用户对当前文本不满意，可以用历史按钮查看最近记录，并把某条历史恢复为当前文本。历史恢复只影响当前文本框，不删除原历史。

发布后的快捷启动流程是：用户创建 iOS Shortcut，动作设置为打开 VoiceFlow 的录音 deep link。之后用户可以把这个 Shortcut 绑定到 Action Button、锁屏控件或桌面快捷方式。触发后，VoiceFlow 打开并直接进入录音流程；如果 token 缺失或麦克风权限不可用，应用显示正常的本地化错误，不静默失败。

## 双语要求

App UI 默认使用系统语言。中文简体环境显示中文，其他环境默认英文。用户也可以在 Settings 中手动选择 English 或简体中文。所有用户可见字符串都进入本地化资源，不允许硬编码在 SwiftUI view 中。

语言选择生效后，Record、Settings、状态消息、错误消息、连接测试结果、OpenCode 发送状态、deep link 触发后的提示都应使用同一语言策略。测试至少覆盖英文、简体中文和 System 默认路径。

## 外观要求

App 默认跟随系统日间/夜间模式。用户也可以在 Settings 中手动选择 Light 或 Dark。Record 和 Settings 的颜色应使用语义颜色或集中定义的主题颜色，确保浅色和深色模式下按钮、文本框边框、禁用态、成功态、错误态都有足够对比度。

外观设置只影响本机 UI，不影响录音、转写、剪贴板、OpenCode 发送或 deep link 行为。

## 录音诊断要求

当录音后直接失败并提示用户重传时，产品需要能定位失败发生在权限、录音启动、停止生成文件、音频文件为空、上传转写、响应解析、自动复制还是 OpenCode 发送。诊断日志只记录事件阶段、错误类别、是否有 token、音频文件大小这类安全摘要。日志不得记录 token、完整请求 header、转写文本、音频内容、真实本地路径或原始 API 响应正文。

## 安全与隐私

API token 存在 Keychain。录音和转写文本默认只保存在本机内存或本机轻量持久化中。仓库只包含 fake 配置示例，不包含真实凭据。

VoiceFlow 的转写后端基于 AI Builder Space。应用不上传录音文件到除 AI Builder Space 转写服务以外的第三方。发送到 OpenCode 前，用户应能看见即将发送的文本。

OpenCode 凭据和 AI Builder token 不进入日志、错误消息、UserDefaults 或测试产物。deep link 不能携带 token、文本或任意外部 payload；它只触发本地开始录音动作。

## 发布要求

代码、文档、测试和示例都按可公开发布到 GitHub 的标准处理。完成 GUI、录音诊断、双语选择、外观选择和隐私检查后，新建 GitHub repo，用 `master` branch 推送。发布后再实现 deep link，并通过 PR 合入。

## 成功标准

V0 达到以下状态才算完成：iOS 模拟器可构建；visionOS 模拟器可构建；Record 和 Settings 两个 tab 可运行；Record/Settings GUI 满足 V0 布局要求；token 能保存到 Keychain；无 token 时录音和转写路径给出明确提示；有 token 时能完成连接测试；录音失败路径有隐私安全日志；转写结果自动进入剪贴板，并且可以手动复制和回滚；OpenCode 未配置时不影响语音输入主流程；OpenCode 已配置时可以发送文本；中英文 UI 可跟随系统并可手动选择；日间/夜间模式可跟随系统并可手动选择；隐私扫描无真实凭据命中；GitHub repo 使用 master branch；deep link 可以从 Shortcuts 触发开始录音，并有测试覆盖。
