# VoiceFlow PRD

## 目标

VoiceFlow 是一个纯粹的语音输入工具。它要解决的是现有语音输入工具控制感不足的问题：用户只是想把话准确、快速地变成文字，产品就应该只做转写，不主动回答、不润色、不改写用户意图。

V0 的核心目标有两层。第一，语音识别准确率高、速度快，输出尽量贴近用户原话。第二，转写完成后自动把文本放进系统剪贴板，让用户可以立刻粘贴到任何 app。OpenCode 是可选增强配置，不配置也不影响 VoiceFlow 作为语音输入工具使用。

## V0 交付状态（2026-05-26）

已在 `master` 交付：Record / Settings 双 tab、GUI 对齐、Keychain token、录完上传转写、自动复制、双向历史导航、保存/重发录音、可选 OpenCode（含连接测试 gating）、录音诊断日志、语言偏好（System / English / 简体中文）、Settings 键盘收起与连接失败 detail、privacy review、GitHub 发布（https://github.com/grapeot/voiceflow）、deep link（`voiceflow://record`）。

尚未交付：Settings 外观偏好（System / Light / Dark 手动选择）。当前 UI 跟随系统日间/夜间模式。

## V1 规划：实时流式转写（下一阶段）

V0 采用「录完再上传」：Stop 之后才开始 multipart 上传整段 WAV，用户需等待上传与推理完成才看到完整转写。V1 目标是显著降低 Stop 后的感知延迟，并在录音过程中就把音频发给服务端。

### 产品行为

用户按下 Start 后，app 建立与 AI Builder Space 的 WebSocket 连接，边录边以固定时长分片（约 0.5s PCM）发送音频。用户说话时，转写区可以尽早出现服务端返回的 partial/final 文本片段。用户按下 Stop 时，本地不再模拟实时回放；而是把剩余音频 buffer 一次性发出，并发送 `stop_recording` 控制消息，要求服务端进入 generating 阶段并继续 stream 文本。

转写区的更新原则是「收到什么显示什么」：服务端每推一条 text delta，UI 立即 append（或在 `isNewResponse` 时替换当前轮次）。不做客户端打字机动画，也不人为按时间戳回放文本。

Stop 到首个可见文本的目标体验：亚秒级（取决于网络与服务端），而不是 V0 的「整文件上传 + 等待完整 JSON」。

### 失败恢复（产品要求）

- WebSocket 断开：显示断开状态，保留已收到的 partial transcript，允许用户手动 Copy；回到前台或重试时自动 reconnect。
- 录音过程中连接未就绪：缓冲音频，连接建立后按顺序 bulk 发送（不按时序 sleep 模拟麦克风）。
- 服务端 error 消息：回到 idle，保留 partial 文本，弹窗或 caption 提示错误。
- 会话正常结束（connected/generating → idle）：把最终 transcript 写入历史、自动复制剪贴板，与 V0 一致。
- 「重发录音」仍走 bulk 发送逻辑，不按录音时长做实时重放。

### V1 明确不做

- 不在 V1 引入转写模型选择 UI（可沿用 Settings 固定模型或后续再加）。
- 不改变 OpenCode 可选发送路径的定位。
- 不把 OpenCode 发送改成 stream prompt（仍发送最终 transcript 文本）。

### V1 成功标准

- 真机/模拟器上 Stop 后 1s 内通常能看到首个 stream 文本（网络正常时）。
- 录音过程中 audio chunk 持续发送，Stop 只触发 finalize，不阻塞在本地编码整段 WAV。
- partial transcript 在 disconnect/error 时不 silently 丢失；history/clipboard 在成功完成时仍自动更新。
- 有单元测试覆盖 WebSocket message parsing、append/replace 逻辑、chunk 发送边界；集成测试可用 mock WebSocket。

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

菜单中的「保存录音」是把最近一次录音导出到 app Documents（`recording_yyyy-MM-dd_HH-mm-ss.wav`），并在 Files → 我的 iPhone → VoiceFlow 中可见；不是内置录音库。保存后弹窗说明文件名与 Files 路径（iOS 无法一键跳转到该目录）。Deep link 只服务于直接开始录音，不扩展成通用自动化接口。

## 用户流程

首次启动时，用户进入 Settings，粘贴 AI Builder Space API token，点击 Test Connection。验证通过后回到 Record。OpenCode 配置可以跳过。语言默认跟随系统；用户可在 Settings 切换 English 或简体中文。

日常使用时，用户点击 Start Recording。应用请求麦克风权限，显示录音状态并采集音频。V0：用户点击 Stop 后上传整段 WAV 并等待转写。V1（规划）：Start 后即将音频分片 stream 到服务端，Stop 只发送 finalize 控制消息并继续接收 text stream，转写区随服务端推送增量更新。

用户可以手动复制文本；配置 OpenCode 并通过连接测试后，可发送到 OpenCode。发送成功或失败都有明确状态，文本和剪贴板内容保留。

用户可用左右 chevron 在最近 5 条转写间切换；三点菜单可保存 WAV 到 Documents 或重发最近一次录音做转写。保存后 app 弹窗告知文件名，并指引用户在 Files app 中进入 On My iPhone → VoiceFlow 查找。

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

V1 完成条件（规划）：WebSocket 实时 audio stream + incremental transcript display；Stop 后亚秒级开始出字；failure recovery 与 bulk resend 行为符合 PRD V1 章节；batch HTTP 转写路径可保留为 fallback 或移除（实现阶段决定）。
