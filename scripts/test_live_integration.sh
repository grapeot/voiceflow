#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/src/VoiceFlow/VoiceFlow.xcodeproj"

export VOICEFLOW_REPO_ROOT="$ROOT"
export VOICEFLOW_LIVE_WS=1
export TEST_RUNNER_VOICEFLOW_LIVE_WS=1
export TEST_RUNNER_VOICEFLOW_REPO_ROOT="$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    export "$line"
  done < "$ROOT/.env"
  set +a
  export TEST_RUNNER_AI_BUILDER_TOKEN="${AI_BUILDER_TOKEN:-}"
  export TEST_RUNNER_AI_BUILDER_SPACE_ENDPOINT="${AI_BUILDER_SPACE_ENDPOINT:-}"
  export TEST_RUNNER_VOICEFLOW_AI_BUILDER_TOKEN="${VOICEFLOW_AI_BUILDER_TOKEN:-}"
fi

TOKEN="${AI_BUILDER_TOKEN:-${VOICEFLOW_AI_BUILDER_TOKEN:-}}"
if [[ -z "$TOKEN" || "$TOKEN" == "replace-with-your-real-token" ]]; then
  echo "Error: set AI_BUILDER_TOKEN (or VOICEFLOW_AI_BUILDER_TOKEN) in .env — see .env.example" >&2
  exit 1
fi

echo "Running live WebSocket integration tests (consumes AI Builder API credits)."
echo "Endpoint: ${AI_BUILDER_SPACE_ENDPOINT:-https://space.ai-builders.com/backend}"

mkdir -p "$ROOT/.voiceflow"
touch "$ROOT/.voiceflow/live-ws-opt-in"
cleanup_live_marker() {
  rm -f "$ROOT/.voiceflow/live-ws-opt-in"
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
  -only-testing:VoiceFlowTests/LiveWebSocketIntegrationTests

if [[ "${VOICEFLOW_TEST_REBUILD:-}" == "1" ]]; then
  voiceflow_xcodebuild_run build-for-testing
  voiceflow_xcodebuild_run test-without-building
else
  voiceflow_xcodebuild_test_with_rebuild_fallback test-without-building
fi
