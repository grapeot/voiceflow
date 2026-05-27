#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/test_unit.sh"
"$ROOT/scripts/test_ui_full.sh"
