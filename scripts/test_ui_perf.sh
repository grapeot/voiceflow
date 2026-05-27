#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/test_ui_common.sh
source "$ROOT/scripts/lib/test_ui_common.sh"
voiceflow_run_ui_suite perf "$ROOT"
