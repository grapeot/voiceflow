#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/src/VoiceFlow/VoiceFlow.xcodeproj"

# shellcheck source=lib/simulator.sh
source "$ROOT/scripts/lib/simulator.sh"
# shellcheck source=lib/xcodebuild_test.sh
source "$ROOT/scripts/lib/xcodebuild_test.sh"
# shellcheck source=lib/test_ui_common.sh
source "$ROOT/scripts/lib/test_ui_common.sh"

cd "$ROOT"
voiceflow_simulator_prepare_destination "$ROOT"

UI_ONLY_TESTING=()
while IFS= read -r line; do
  [[ -n "$line" ]] && UI_ONLY_TESTING+=("$line")
done <<EOF
$(voiceflow_test_ui_only_testing_args perf)
EOF

voiceflow_xcodebuild_common_args \
  "$PROJECT" \
  VoiceFlow \
  "$VOICEFLOW_TEST_DESTINATION" \
  "${UI_ONLY_TESTING[@]}"

if [[ "${VOICEFLOW_TEST_REBUILD:-}" == "1" ]]; then
  voiceflow_xcodebuild_run build-for-testing
  voiceflow_xcodebuild_run test-without-building
else
  voiceflow_xcodebuild_test_with_rebuild_fallback test-without-building
fi
