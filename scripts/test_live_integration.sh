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

mkdir -p "$ROOT/.voiceflow/live-fixtures"
MODEL_BENCHMARK_DIR="${VOICEFLOW_MODEL_BENCHMARK_DIR:-$ROOT/../model_benchmark}"
prepare_gpt_live_fixture() {
  local environment_key="$1"
  local default_source="$2"
  local output_name="$3"
  local source_path="${!environment_key:-$default_source}"
  local output_path="$ROOT/.voiceflow/live-fixtures/$output_name"

  if [[ ! -f "$source_path" ]]; then
    echo "Skipping $environment_key: fixture not found at $source_path" >&2
    return
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Skipping $environment_key: ffmpeg is required to normalize the fixture" >&2
    return
  fi

  ffmpeg -nostdin -loglevel error -y -i "$source_path" -ar 24000 -ac 1 -c:a pcm_s16le "$output_path"
  export "TEST_RUNNER_${environment_key}=$output_path"
}

prepare_gpt_live_fixture \
  VOICEFLOW_GPT_LIVE_SHORT_WAV \
  "$MODEL_BENCHMARK_DIR/data/instruction_following/recording_2026-02-28_11-13-40.wav" \
  gpt-live-short.wav
prepare_gpt_live_fixture \
  VOICEFLOW_GPT_LIVE_60S_WAV \
  "$MODEL_BENCHMARK_DIR/data/sample_1min_single.mp3" \
  gpt-live-60s.wav
prepare_gpt_live_fixture \
  VOICEFLOW_GPT_LIVE_5MIN_WAV \
  "$MODEL_BENCHMARK_DIR/data/multi_speaker_5min.mp3" \
  gpt-live-5min.wav

echo "Running live WebSocket integration tests (consumes AI Builder API credits)."
echo "GPT Live fixtures can take more than six minutes and consume transcription credits."
echo "Endpoint: ${AI_BUILDER_SPACE_ENDPOINT:-https://space.ai-builders.com/backend}"

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
