# VoiceFlow

This repo ships two things in one place:

1. **VoiceFlowKit** — a Swift Package that wraps real-time audio capture + transcription (PCM16 24 kHz mono → WebSocket → partial transcripts → final text). Drop it into any iOS 17+ / visionOS 1+ app and add voice input in ~50 lines.
2. **VoiceFlow** — an iPhone / iPad / Apple Vision Pro app built on top of VoiceFlowKit. A minimal voice-memo recorder with auto-clipboard, history, save/resend, and optional OpenCode push.

Public repo: <https://github.com/grapeot/voiceflow>

### Designed as a generative kernel for AI integrators

VoiceFlowKit is built around the [generative kernel](https://yage.ai/ai-software-engineering.html) idea: the package itself is the **core kit** (mic capture + WS transport + transcription pipeline), `skills/adding_voice_input_with_voiceflowkit.md` is the **guiding knowledge** written for AI agents reading it in another host's codebase, and `VoiceFlowClient.makeStub(...)` / `VoiceFlowAudioMetering` / the typed `VoiceFlowError` cases are **leverage tools** the AI can compose without going to the raw WebSocket layer.

Concretely that means:

- Errors come back as typed `VoiceFlowError` cases (`.httpError(statusCode:)`, `.connectionLost(detail)`, `.websocketError(detail)`, …) — not a wrapped "something went wrong." Agents can pattern-match and react instead of guessing.
- The facade is small and stable, but every primitive an integrator might need (offline stub client, audio metering helper, two-layer caption store) is exposed. No "hidden for your own good" knobs.
- The skill file is treated as a first-class deliverable, not an afterthought. Read it before writing client code.

> AI agents who want to add voice input to their host's iOS / visionOS app should read `skills/adding_voice_input_with_voiceflowkit.md` end-to-end before touching the kit.

## VoiceFlowKit (the library)

### Quick start

In Xcode: File → Add Package Dependencies → URL `https://github.com/grapeot/voiceflow.git`. Pick `branch: master` for now (no SemVer tag yet — we're still iterating). Add the `VoiceFlowKit` product to your app target.

Add `NSMicrophoneUsageDescription` to your Info.plist (a sentence explaining the mic is used for voice-to-text).

Five lines to start streaming:

```swift
import VoiceFlowKit

let config = VoiceFlowConfig(tokenProvider: { yourToken })
let client = VoiceFlowClient(config: config)
let session = try await client.startSession()
// → push PCM16 chunks via session.sendAudioChunk(_:)
// → drain partial transcripts from session.events
// → finalize with try await session.commitAndStop()
```

### Public surface

| Type | What it does |
|---|---|
| `VoiceFlowConfig` | endpoint + token closure + optional prompt/terms |
| `VoiceFlowClient` (actor) | factory for sessions + bulk transcribe + connection test |
| `VoiceFlowSession` (actor) | one live recording session — send audio, ping, commit, cancel; exposes `events: AsyncStream<VoiceFlowEvent>` |
| `VoiceFlowMicrophone` (`@MainActor`) | mic capture; permission + PCM16/24kHz/mono `start(onPCMChunk:)` + `stop()` |
| `VoiceFlowEvent` | enum: `partialTranscript / phaseChanged / recoveryStarted / recoveryFailed` |
| `VoiceFlowConnectionPhase` | enum: `connecting / connected / recovering / generating / disconnected` |
| `VoiceFlowError` | enum: `missingToken / invalidEndpoint / httpError / sessionUnavailable / websocketError / connectionLost / emptyTranscript / microphoneUnavailable / audioConversionFailed / underlying(String)` |
| `VoiceFlowClient.makeStub(...)` | offline stub client for UI test launch modes + SwiftUI previews — no WebSocket, canned final transcript |
| `StreamCaption` / `StreamCaptionStore` | optional two-layer caption helper (persistent + transient flash) if you want "Reconnecting…" / "Stream restored." prompts |

Two work modes: **live streaming** (`startSession` → push chunks → `commitAndStop`) or **bulk** (`transcribe(audioFile:)` for one-shot WAV files — used by VoiceFlow's resend path).

### Integration guide for AI agents

Full integration walkthrough (with reference implementations, traps, and acceptance criteria) is in `skills/adding_voice_input_with_voiceflowkit.md`. Read that before writing client code.

### Reference implementations

- **VoiceFlow** in this repo (`src/VoiceFlow/`) — voice-memo recorder. See `AppState+LiveSession.swift` for the canonical session bridge.
- **OpenCode iOS Client** (`grapeot/opencode_ios_client`, private but PR #52 is the integration commit) — chat app with mic input on the composer.

### Platform support

- iOS 17+, visionOS 1+
- macOS host build works for `swift test` (mic capture is conditional-compiled out) — VoiceFlowKit is mic-less on macOS

### Backend

Default endpoint is AI Builder Space (`https://space.ai-builders.com/backend`). Wire protocol: POST `/v1/audio/realtime/sessions` to get a ticket, then `wss://.../v1/audio/realtime/ws?ticket=...` for PCM16 streaming. Model is `gpt-realtime`. You can swap the endpoint via `VoiceFlowConfig.endpoint` if you have a compatible backend.

## VoiceFlow (the app)

V0 has two tabs: **Record** and **Settings**.

**Record**: start/stop recording with live partial transcript, auto-copy on stop, history navigation (prev/next), save WAV to Files, resend last recording, manual copy, optional push to OpenCode when configured.

**Settings**: AI Builder Space token (Keychain), default endpoint, optional OpenCode (server URL + username in UserDefaults, password in Keychain), language preference (System / English / 简体中文), transcription prompt + terms inputs for shaping recognizer output.

### Deep link

```text
voiceflow://record
```

Bind via Shortcuts → "Open URL" → Action Button or Home Screen icon. See `docs/rfc.md`.

### Build / test

```bash
./scripts/test_unit.sh           # daily — fast unit tests
./scripts/test_ui_smoke.sh       # smoke UI tests (~45s)
./scripts/test_ui_full.sh        # full UI suite (~3-5min)
./scripts/test_live_integration.sh   # opt-in live backend WS tests (needs .env)
./scripts/test_all.sh            # everything before release
```

`swift test` (at the repo root) runs the Kit's own tests independently of the app.

## Repository layout

```text
Package.swift                          # VoiceFlowKit SPM manifest
Sources/VoiceFlowKit/                  # Library source
  VoiceFlow{Client,Session,Microphone,Config,Error}.swift  # Public facade
  Internal/                            # WebSocket transport, audio recorder,
                                       #  message parser — module-internal
  Resources/PrivacyInfo.xcprivacy      # Privacy manifest shipped with the kit
Tests/VoiceFlowKitTests/               # Library tests (swift-testing)

src/VoiceFlow/                         # The VoiceFlow app
  VoiceFlow.xcodeproj
  VoiceFlow/                           # App sources (AppState + extensions, Views)
  VoiceFlowTests/                      # Unit tests
  VoiceFlowUITests/                    # UI tests

skills/                                # Integration skill files for AI agents
docs/                                  # PRD, RFC, design notes, working log
scripts/                               # test_*.sh, pin_simulator.sh
```

## Privacy & credentials

The repo only contains fake examples. Real tokens go to the device Keychain; see `.env.example` for the live-integration test env-var format.

## Documentation

- `docs/prd.md` — product scope (covers both the library and the app)
- `docs/rfc.md` — module structure, facade contract, wire protocol
- `docs/working.md` — daily change log
- `docs/design.md` — visual system
- `docs/test.md` — test commands and coverage
- `skills/adding_voice_input_with_voiceflowkit.md` — integration walkthrough for AI agents
