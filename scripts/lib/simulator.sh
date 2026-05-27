#!/usr/bin/env bash
# Shared iOS Simulator pinning for VoiceFlow test scripts.
#
# First run on a machine discovers a matching simulator UDID, saves it locally
# under .voiceflow/, boots it, and reuses it on later runs. Override with
# VOICEFLOW_TEST_DESTINATION to skip pinning entirely.

voiceflow_simulator_init() {
  local root="$1"
  VOICEFLOW_ROOT="$root"
  VOICEFLOW_PIN_DIR="$root/.voiceflow"
  VOICEFLOW_PIN_FILE="$VOICEFLOW_PIN_DIR/simulator-udid"
  VOICEFLOW_SIMULATOR_NAME="${VOICEFLOW_SIMULATOR_NAME:-iPhone 17 Pro}"
  VOICEFLOW_SIMULATOR_OS="${VOICEFLOW_SIMULATOR_OS:-26.3.1}"
}

voiceflow_simulator_udid_exists() {
  local udid="$1"
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid:
            sys.exit(0)
sys.exit(1)
' "$udid"
}

voiceflow_simulator_discover_udid() {
  python3 - "$VOICEFLOW_SIMULATOR_NAME" "$VOICEFLOW_SIMULATOR_OS" <<'PY'
import json
import subprocess
import sys

name, os_pref = sys.argv[1], sys.argv[2]
major_minor = ".".join(os_pref.split(".")[:2])

payload = subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    text=True,
)
data = json.loads(payload)

def runtime_matches(runtime_id: str) -> bool:
    marker = "SimRuntime.iOS-"
    idx = runtime_id.find(marker)
    if idx == -1:
        return False
    runtime_version = runtime_id[idx + len(marker) :].replace("-", ".")
    return runtime_version == major_minor or runtime_version.startswith(f"{major_minor}.")

candidates = []
for runtime_id, devices in data.get("devices", {}).items():
    if not runtime_matches(runtime_id):
        continue
    for device in devices:
        if device.get("name") != name:
            continue
        if device.get("isAvailable") is False:
            continue
        candidates.append(device)

if not candidates:
    print(
        f"No available simulator named {name!r} for iOS {os_pref!r}.",
        file=sys.stderr,
    )
    print(
        "Install the runtime in Xcode or override VOICEFLOW_SIMULATOR_NAME / "
        "VOICEFLOW_SIMULATOR_OS / VOICEFLOW_TEST_DESTINATION.",
        file=sys.stderr,
    )
    sys.exit(1)

booted = [device for device in candidates if device.get("state") == "Booted"]
chosen = booted[0] if booted else candidates[0]
print(chosen["udid"])
PY
}

voiceflow_simulator_resolve_udid() {
  local pinned=""

  if [[ -n "${VOICEFLOW_TEST_DESTINATION:-}" ]]; then
    return 0
  fi

  mkdir -p "$VOICEFLOW_PIN_DIR"

  if [[ -f "$VOICEFLOW_PIN_FILE" ]]; then
    pinned="$(tr -d '[:space:]' < "$VOICEFLOW_PIN_FILE")"
    if [[ -n "$pinned" ]] && voiceflow_simulator_udid_exists "$pinned"; then
      printf '%s\n' "$pinned"
      return 0
    fi
  fi

  pinned="$(voiceflow_simulator_discover_udid)"
  printf '%s\n' "$pinned" > "$VOICEFLOW_PIN_FILE"
  printf '%s\n' "$pinned"
}

voiceflow_simulator_boot() {
  local udid="$1"
  if xcrun simctl list devices booted -j | python3 -c '
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid and device.get("state") == "Booted":
            sys.exit(0)
sys.exit(1)
' "$udid"; then
    return 0
  fi

  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

voiceflow_simulator_prepare_destination() {
  local root="$1"
  voiceflow_simulator_init "$root"

  if [[ -n "${VOICEFLOW_TEST_DESTINATION:-}" ]]; then
    VOICEFLOW_TEST_DESTINATION_SOURCE="override"
    return 0
  fi

  local udid
  udid="$(voiceflow_simulator_resolve_udid)"
  voiceflow_simulator_boot "$udid"
  export VOICEFLOW_TEST_DESTINATION="platform=iOS Simulator,id=$udid"
  VOICEFLOW_TEST_DESTINATION_SOURCE="pinned"
}
