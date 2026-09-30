# Append 模式设计：转写区从「槽位」变成「文档」

状态：已定稿（2026-09-29 鸭哥确认），进入实现。
日期：2026-09-29。基线：master `969c877`。

## 首屏结论

1. 追加（Append）模式让转写区变成一个持续生长的文档：每次录音转写完成后，新文本接到现有文本下方而不是覆盖它；再按 Start 可以接着录。
2. 逐字流式出字的策略和录完才出字的策略走同一套模型：新文本先出现在现有文本下方的「待合并块」里（流式增量填、批量一次填），完成时才并入文档，现有文本任何时刻都不会被流式快照覆盖。
3. 模式开关是 session 级设置（不持久化），放在 Record 屏 ⋯ 菜单里，随时来回切；转写区工具条在 Copy 左边新增垃圾桶按钮，把当前内容 push 进历史栈并清空文本框，左右箭头可恢复。

关键决策一览：

| 决策 | 结论 | 一句话理由 |
|---|---|---|
| 开关位置 | Record 屏 ⋯ 菜单（Replace / Append 两项，checkmark 标记当前项） | 它是 session 级设置不是全局设置；预期两种工作流来回切，放在动作发生的地方 |
| 开关持久化 | 不持久化，内存态，App 重启回到 Replace | session 语义：跟当前工作会话走，不落 UserDefaults |
| 默认值 | Replace（现状） | 不改变存量用户肌肉记忆，公开产品零行为回归 |
| 追加的分隔 | 单个换行，无时间戳、无视觉分隔线 | 粘贴出去是一篇干净文档 |
| 追加中的历史 | 左右箭头 = 文档快照的撤销/重做 | 零新增 UI，复用最熟悉的手势 |
| 开新文档 / 清空 | 工具条垃圾桶按钮（Copy 左边），两种模式都可用 | 当前内容 push 进历史栈并清空；左箭头即撤销，不需要确认弹窗 |
| 待合并块期间 | 文档非空时编辑器只读 | 流是权威的，且编辑后无法可靠拆分「文档 + 块」 |
| 彻底失败 | 已上屏的部分文本并入文档保留 | 可见文本不被静默丢弃，与 PRD finalize 失败保留 partial 一致 |

## 现状：replace 发生在三个地方

今天每次识别结果覆盖之前的，是三处代码叠加的行为：

1. 按 Start 时 `transcript = ""` 无条件清空（`src/VoiceFlow/VoiceFlow/AppState.swift:566`）。
2. Stop 后转写成功，`completeStopTranscriptionSuccess` 用最终文本整体赋值 `transcript = text`（`src/VoiceFlow/VoiceFlow/AppState+LiveSession.swift:605`）。
3. 重发录音成功后同样整体覆盖（`src/VoiceFlow/VoiceFlow/AppState.swift:713` 起的 resend 路径）。

转写区在用户的感知里是「一个槽位」：每次录音产出一条文本，旧的进 5 条历史环形队列（`src/VoiceFlow/VoiceFlow/Models/TranscriptHistory.swift`），左右箭头在槽位之间切换。

「直接改成 append」不成立的原因：流式策略在 finalize 阶段推送的是**本次录音的累计文本**，不是整个转写区的文本（服务端不知道转写区里还有之前的内容）。把它套进现有 `applyStreamedTranscript`（`AppState+LiveSession.swift:266`），前缀检查必然失败，走 replace 分支，把已有文档整个抹掉。所以设计核心是两层模型，见下节。

## 核心：文档 + 待合并块

转写区拆成两层：

- **文档（document）**：稳定文本。idle/ready 时完全可编辑，与今天语义一致。
- **待合并块（pending chunk）**：正在进行中的那条转写，显示在文档下方。

所有策略都只写待合并块，合并动作只有一个：

| 策略 | 块怎么填 | 说明 |
|---|---|---|
| GPT Live | 录音中 live 增量填，Stop 后 finalize 继续填 | 现有 partial 机制不变，目标从 `transcript` 改为块 |
| GPT Realtime | Stop 后 finalize 增量填 | 录音中不出字是既有设计，不变 |
| Grok Batch | 转写完成一次填入 | 无流式 |
| Local Qwen3-ASR | 转写完成一次填入 | 无流式 |

这就是 delta 与 batch 的兼容方式：模式不感知策略，只感知「块完成了没有」。流式是增量填块（复用 `applyStreamedTranscript` 的 append-delta / replace-whole 逻辑，作用域从整个转写区缩小到块），批量是一次填块；合并、历史、剪贴板、失败语义全部共用同一条路径。

合并规则：

1. 分隔符是单个换行；文档末尾已有换行则不补。无时间戳、无空行、无视觉分隔——粘贴出去就是一篇连续文档。
2. 空块（低于现有 usability 门槛，`isUsableTranscript`）不合并，文档不动，等价于今天的失败路径。
3. 彻底失败（流 + bulk fallback 全挂）时，若块里有已上屏文本，仍并入文档保留；块为空则文档不动。GPT Live 录音中用户看到的 live 文本不会被悄悄丢掉。
4. 合并成功时：剪贴板自动复制**整篇文档**（`copyTranscript` 本来就复制 `transcript`，零改动）；OpenCode 发送、Custom Action 同样作用于整篇文档，零新概念。

待合并块期间编辑器只读，复用现有 `isLocked` 机制（与 Custom Action 运行中同一套）。理由：块在流式填充时，用户在中间编辑会被下一帧快照整体覆盖（`applyStreamedTranscript` 的 replace 分支），今天的实现里这种编辑本来就是无效的；只读把这个事实显性化，同时保护文档前缀不被编辑和流式写入交叠。

## 四种策略下的行为矩阵（追加模式）

| 阶段 | GPT Live | GPT Realtime | Grok Batch / Local |
|---|---|---|---|
| 录音中 | 文档冻结在上，live 文本在下方生长 | 转写区不变（既有设计） | 转写区不变 |
| Stop 后 transcribing | finalize 快照继续填充下方块 | 流式 delta 填充下方块 | 等待，无流式 |
| 成功 | 块并入文档，整篇进剪贴板，文档快照入历史 | 同左 | 同左（一次并入） |
| 彻底失败 | 已上屏块保留并入，文档前缀不动 | 同左 | 文档不动，错误提示如今天 |

视觉上追加模式最有说服力的时刻是 GPT Live：按 Start 再开口，旧文档停在上方，新话逐字在下方长出来。

## 开关与界面：切换为什么是自然的

### 模式开关在 ⋯ 菜单里，是 session 级设置

- 位置：Record 屏 ⋯ 菜单顶部，Replace / Append 两个菜单项，当前项带 checkmark；录音中 / 转写中禁用（与策略相同，Start 时锁定本次录音）。
- **不是全局设置**：它不写 UserDefaults，是内存态，跟当前工作会话走；App 重启回到默认 Replace。理由：用户预期在两种工作流之间来回切（今天累积成文档、明天录零散片段），把它做成需要进 Settings 的全局默认值，切换路径就隔了一层。
- 菜单里其余项（Send to OpenCode / Save recording / Resend recording）保持原位，模式项与它们之间用 Section 分隔。

文案：

| Key | EN | ZH |
|---|---|---|
| `record.transcriptMode.replace` | Replace | 替换 |
| `record.transcriptMode.append` | Append | 追加 |

用 Replace / Append 而不是发明新词：这是用户自己在描述这个功能时用的词，菜单里一眼能对上。

### 垃圾桶按钮：清空当前内容并进历史

- 位置：转写区工具条，Copy 按钮左边（工具条现有结构 `[自定义动作] —— [Copy]`，新增后 `[自定义动作] —— [垃圾桶] [Copy]`），ghost 图标 `trash`，样式与 Copy 一致。
- 可见/可用条件：文本非空 + idle/ready + Custom Action 未在运行。录音中禁用（与 Copy 可见但垃圾桶禁用的差异是有意为之：清空正在进行中的文档会把「文档 + 块」的状态搅乱）。
- 动作：当前内容 push 进 `TranscriptHistory`（复用 `add` 的去重与 5 条上限），清空文本框。**两种模式都可用**：追加模式下是「结束这篇、开新的」；替换模式下是「归档当前文本、清空」——替换模式今天本来就没有任何手动清空手段，这个按钮顺带补上。
- 不需要确认弹窗：push 进了历史，左箭头即撤销。

### 追加模式下左右箭头 = 文档的撤销/重做

`TranscriptHistory` 机制完全复用，变的只是里面存什么：

- 每次合并成功、每次垃圾桶清空，推入的是**整篇文档快照**（替换模式存的是单条转写，语义不变；两种模式在代码上是同一个 `add(transcript)`，因为追加模式下 `transcript` 本身就是整篇文档）。
- 左箭头 = 回到上一个文档版本（撤销上次追加 / 恢复清空之前），右箭头 = 前进。5 条上限不变，即最多 5 步撤销。
- **空视图恢复规则**：文本框为空且历史非空时，左箭头恢复当前游标指向的条目（清空后游标停在最新条，即刚 push 进去的那份）。这条规则同时让「手动全选删除」也能用一个左箭头找回最近一份文本。
- 若存「单条块」进历史，箭头切出的文本会和屏幕上看到的文档对不上，认知上是断裂的——所以追加模式只存文档快照。

### Record 屏不放常驻的模式标签

理由：追加模式下的文档是自明的（文本就在屏上，录完下一条它还在）；文档为空时两种模式不可区分，但也都没有风险；⋯ 菜单里 checkmark 的位置本身就是模式信号。常驻一个「Append mode」标签是噪声，违反设计原则 6（文案克制）和原则 7（可选功能不占主屏权重）。

### 让切换自然的五条

1. **开关在动作发生的地方**：模式决定的是「下一次 Start 怎么处理屏上的文本」，用户做这个决定的时刻就站在 Record 屏，⋯ 菜单是零跳动的最短路径。
2. **需要区分前不可区分**：空文档时两模式无差别，模式只在产生后果的那一刻可见。
3. **每个后果可撤销**：追加入历史快照（箭头撤销），垃圾桶 push 历史（左箭头恢复），默认 Replace 保证存量用户永远不会误入新行为。
4. **session 语义匹配使用节奏**：工作流来回切是常态，session 级开关不需要「去设置里改回来」，也不污染全局配置。
5. **词汇来自用户自己**：Replace / Append。

## 边界情况

- **重发录音**：追加模式下重转写的是最后一条录音，结果**替换最后一段块**，不是追加第二份，也不是覆盖整篇文档。实现上合并时记住最后一段的长度，resend 成功时只替换尾部那一段。替换模式行为不变（整体覆盖）。
- **Custom Action 结果**：`addTransform`（result + source 双入历史）在追加模式下同样成立——作用对象是整篇文档，与快照撤销语义一致，无需特判。
- **Deep link / 快捷指令 Start**：与手按 Start 完全一致，文档保留。
- **App 被杀**：文档与模式都丢失（`transcript` 与模式均不落盘，与今天行为一致）。模式回到 Replace。文档持久化是候选后续项（会引入产品数据模型变化，不进 V1）。
- **超长文档**：V1 不设上限。自动滚动复用既有逻辑——「新文本是旧文本的扩展」时滚到底部（`src/VoiceFlow/VoiceFlow/Views/RecordView.swift:491`），合并恰好就是这个 case。
- **录音中切模式**：菜单项禁用，不影响当前录音（Start 锁定），与策略一致。
- **替换 ↔ 追加切换瞬间**：替换改追加，现有文本即成为文档；追加改替换，下次 Start 清空。都自明，不需要迁移逻辑。
- **垃圾桶与历史的交互**：清空后立即按左箭头，恢复刚清空的那份（空视图恢复规则）；重复 push 同一文本走 `add` 的去重，不产生重复条目。
- **手动全选删除**：文本框被用户清空后，左箭头可恢复当前游标指向的最近条目（空视图恢复规则覆盖此场景，与垃圾桶共用同一路径）。

## 实现草图

<details>
<summary>文件级映射与测试清单</summary>

- `Models/TranscriptMode.swift`（新增）：`enum TranscriptMode: String, CaseIterable, Codable { case replace, append }`。
- `AppState.swift`：`@Published var transcriptMode: TranscriptMode = .replace`（**session 级，不写 UserDefaults**）；`startRecording` 缓存 `activeTranscriptMode`（与 `activeRecordingStrategy` 同款，Start 时锁定）；chunk 状态：`composeBase: String`（chunk 在飞时冻结的基座文本，append 新录音 = 当前文档，append 重发 = 文档去掉最后一段，replace = 空）、`chunkInFlight: Bool`、`lastChunkLength: Int?`（最后一段的字符数，重发替换用；`transcript.didSet` 一律置 nil，合并/settle 显式写回）、`preResendDocument: String?` + `preResendChunkLength: Int?`（append 重发前快照，失败时原样恢复）。`@Published var transcript` 继续作为编辑器绑定（显示层 = composeBase + 分隔 + chunk，idle/ready 时 composeBase 即 transcript）。
- `AppState+LiveSession.swift`：`applyStreamedTranscript` 改为 composeBase 感知（前置 `chunkInFlight` 守卫，结算后的陈旧帧忽略；快照先 `composeTranscript(base:chunk:)` 合成再套原有 append-delta/尾替换/整体替换逻辑；空快照忽略）；`completeStopTranscriptionSuccess` 按 `activeTranscriptMode` 分支（replace 现状 / append 走 `mergeChunkIntoTranscript`：compose 合并 + 记 lastChunkLength + 清块状态），`transcriptHistory.add(committed)` 与 `copyTranscript()` 统一作用于整篇文档（append 下 committed 即整篇快照）；失败漏斗（`completeStopTranscriptionFailure`、`stopRecording` defer、resend 各早期出口）调用幂等的 `settleFailedChunk()`：因流式写入恒在基座上合成，settle **不改写 transcript**（可见 partial 原样保留即等于并入文档），只清块状态解锁编辑器并回填 `lastChunkLength`（空块保留原边界）；resend 重转写失败走 `settleFailedResend()` 恢复 `preResendDocument` + `preResendChunkLength`（后者防止 `transcript.didSet` 失效边界后下一次 resend 重复追加尾段）。
- `TranscriptHistory.swift`：新增 `currentEntry: String?`（entries[safe: currentIndex]）与 `isEmpty`；`add` 改存原文（trim 只用于空判断与去重——垃圾桶使历史成为撤销目标，恢复须逐字节一致）；`navigatePrevious` / `navigateNext` 不变。
- 边界归属规则（复审后补充）：`lastChunkLength` 永远描述**当前可重发录音**的最后一块——新录音 persist 成功后置 nil（stop / 录音中重发两处）；replace 成功记整页长；settle 记可见 partial 长；resend 失败恢复记 `preResendChunkLength`（idle/ready 重发 = 合并边界，录音中/卡死重发 = 可见 live 块长）。
- `AppState+TranscriptHistory.swift`：`clearTranscriptToHistory()`（垃圾桶动作：`add(transcript)` + 清空 + 诊断日志）；`navigatePreviousTranscript` 加空视图恢复（transcript 为空时恢复 `currentEntry`）；`canNavigatePreviousTranscript` 对应放行。
- `RecordView.swift`：⋯ 菜单顶部加 Replace / Append 两个 Button（checkmark 标记当前项，Section 与既有三项分隔，`canChangeTranscriptMode` = idle/ready 且 Custom Action 未运行）；工具条 Copy 左边加垃圾桶 ghost 按钮（`trash` 图标，`canClearTranscript` = 非空 + idle/ready + 未在运行）；`TranscriptEditor.isLocked` 增加 `chunkInFlight && !composeBase.isEmpty` 条件。
- `SettingsView.swift`：不动。
- 本地化：`record.transcriptMode.title` / `record.transcriptMode.replace` / `record.transcriptMode.append` / `record.clear`，en/zh-Hans 各一份。
- UI test 支持 `-uiTestTranscriptModeAppend` 启动种子（对齐现有 `-uiTest*` 模式）；`resetForUITest` 重置 `transcriptMode = .replace` 与 chunk 状态。
- 测试（`src/VoiceFlow/VoiceFlowTests/`）：merge 的分隔符规则（含文档已以换行结尾不补）；composeBase 非空时流式快照只动 chunk 区不动文档区；composeBase 为空时行为与现状一致（替换模式回归）；resend（append）替换最后一段；垃圾桶 push + 清空 + 左箭头恢复（空视图规则）；手动清空后左箭头恢复；失败 settle 保留可见 partial / 空 chunk 不动文档；模式在 Start 时锁定（录音中切换不影响本次合并）；编辑器锁定条件。
- 文档：`prd.md` 加「转写模式（追加）」小节，`rfc.md` 加两层模型与合并/失败语义，`working.md` 记录实施与验证（AGENTS.md 硬性规则 5）。
- 不做：文档持久化、模式持久化、分隔符可配置、Record 屏常驻模式标签、每次录音级模式选择（长按 Start 之类）。

</details>

## 首屏复述（验收用）

1. 追加模式下，转写区变成一个持续生长的文档：每次录音的结果接到现有文本下面，不再覆盖；再按 Start 接着录。
2. 不管是逐字流式出字的策略还是录完才出字的策略，行为都一样：新文本先出现在现有文本下方，等它完整到达后才正式成为文档的一部分，已有文本永远不会被中途的快照覆盖。
3. 模式开关放在 Record 屏的 ⋯ 菜单里（Replace / Append，当前项打勾），是跟会话走的设置不落全局配置，随时可以来回切；工具条 Copy 左边多了个垃圾桶按钮，按一下当前内容进历史栈、文本框清空，按左箭头就能找回来。
