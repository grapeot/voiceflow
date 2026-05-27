#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/src/VoiceFlow/VoiceFlow.xcodeproj"

# shellcheck source=lib/simulator.sh
source "$ROOT/scripts/lib/simulator.sh"
# shellcheck source=lib/xcodebuild_test.sh
source "$ROOT/scripts/lib/xcodebuild_test.sh"

cd "$ROOT"
voiceflow_simulator_prepare_destination "$ROOT"
voiceflow_xcodebuild_common_args "$PROJECT" VoiceFlow "$VOICEFLOW_TEST_DESTINATION"

if [[ "${VOICEFLOW_TEST_REBUILD:-}" == "1" ]]; then
  voiceflow_xcodebuild_run build-for-testing
  voiceflow_xcodebuild_run test-without-building
else
  voiceflow_xcodebuild_test_with_rebuild_fallback test-without-building
fi
