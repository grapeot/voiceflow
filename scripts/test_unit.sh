#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/src/VoiceFlow/VoiceFlow.xcodeproj"
DESTINATION="${VOICEFLOW_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1}"

cd "$ROOT"
xcodebuild \
  -project "$PROJECT" \
  -scheme VoiceFlow \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:VoiceFlowTests \
  test
