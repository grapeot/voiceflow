#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/src/VoiceFlow/VoiceFlow.xcodeproj"

export VOICEFLOW_REPO_ROOT="$ROOT"
export OPENCODE_LIVE=1
export TEST_RUNNER_OPENCODE_LIVE=1
export TEST_RUNNER_VOICEFLOW_REPO_ROOT="$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    export "$line"
  done < "$ROOT/.env"
  set +a
  export TEST_RUNNER_OPENCODE_BASE_URL="${OPENCODE_BASE_URL:-}"
  export TEST_RUNNER_OPENCODE_USERNAME="${OPENCODE_USERNAME:-}"
  export TEST_RUNNER_OPENCODE_PASSWORD="${OPENCODE_PASSWORD:-}"
fi

USER_NAME="${OPENCODE_USERNAME:-}"
PASS="${OPENCODE_PASSWORD:-}"
if [[ -z "$USER_NAME" || -z "$PASS" || "$PASS" == "replace-with-your-real-password" ]]; then
  echo "Error: set OPENCODE_USERNAME and OPENCODE_PASSWORD in .env — see .env.example" >&2
  exit 1
fi

echo "Running live OpenCode send-transcript integration test."
echo "Server: ${OPENCODE_BASE_URL:-http://localhost:4096}"

mkdir -p "$ROOT/.voiceflow"
touch "$ROOT/.voiceflow/opencode-live-opt-in"
cleanup_live_marker() {
  rm -f "$ROOT/.voiceflow/opencode-live-opt-in"
}
trap cleanup_live_marker EXIT

# shellcheck source=lib/simulator.sh
source "$ROOT/scripts/lib/simulator.sh"
# shellcheck source=lib/xcodebuild_test.sh
source "$ROOT/scripts/lib/xcodebuild_test.sh"

cd "$ROOT"
voiceflow_simulator_prepare_destination "$ROOT"
voiceflow_xcodebuild_common_args \
  "$PROJECT" \
  VoiceFlow \
  "$VOICEFLOW_TEST_DESTINATION" \
  -only-testing:VoiceFlowTests/LiveOpenCodeIntegrationTests

if [[ "${VOICEFLOW_TEST_REBUILD:-}" == "1" ]]; then
  voiceflow_xcodebuild_run build-for-testing
  voiceflow_xcodebuild_run test-without-building
else
  voiceflow_xcodebuild_test_with_rebuild_fallback test-without-building
fi
