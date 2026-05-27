#!/usr/bin/env bash
# Default UI entry: full functional suite (no perf / launch screenshot).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/test_ui_full.sh" "$@"
