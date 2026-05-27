#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/simulator.sh
source "$ROOT/scripts/lib/simulator.sh"

voiceflow_simulator_prepare_destination "$ROOT"

if [[ "${VOICEFLOW_TEST_DESTINATION_SOURCE:-}" == "override" ]]; then
  echo "Using VOICEFLOW_TEST_DESTINATION=$VOICEFLOW_TEST_DESTINATION"
else
  udid="$(tr -d '[:space:]' < "$VOICEFLOW_PIN_FILE")"
  echo "Pinned simulator UDID: $udid"
  echo "Destination: $VOICEFLOW_TEST_DESTINATION"
fi
