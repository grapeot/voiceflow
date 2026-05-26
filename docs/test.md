# 测试与验收策略

## 文档阶段验收

脚手架阶段必须满足：

```bash
test -d .git
test -f AGENTS.md
test -f README.md
test -f .gitignore
test -f .env.example
test -f docs/prd.md
test -f docs/rfc.md
test -f docs/working.md
test -f docs/test.md
```

隐私扫描：

```bash
rg -n '(o[p]://|/U[s]ers/[^ ]+|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' .
```

预期结果是零匹配。`.env.example` 只能出现 fake token。

## App 阶段验收

创建 Xcode 工程后，至少补齐以下验证：

```bash
xcodebuild -list -project src/VoiceFlow/VoiceFlow.xcodeproj
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.2' CODE_SIGNING_ALLOWED=NO build
```

如果加入 XCTest，再补：

```bash
xcodebuild -project src/VoiceFlow/VoiceFlow.xcodeproj -scheme VoiceFlow -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' CODE_SIGNING_ALLOWED=NO test
```

build 和 test 串行执行。

## 单元测试目标

第一批单元测试覆盖：KeychainStore 保存/读取/删除 token、endpoint 拼接、Bearer header 注入、TranscriptHistory 最近 5 条保留和回滚行为、Record 状态机合法转移、本地化 key 存在性。

## 集成测试目标

连接测试和转写请求需要支持 offline mock。真实 API token 只在开发者本机或 CI secret 中配置，默认测试不依赖真实网络。

## 手工验证

V0 手工验证只看用户路径：首次启动、Settings 保存 token、连接测试、Record 录音、停止转写、复制、历史回滚、发送到 OpenCode、中英文界面切换、无 token 状态提示。
