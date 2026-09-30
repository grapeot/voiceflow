#!/usr/bin/env bash

voiceflow_xcodebuild_common_args() {
  VOICEFLOW_XCODE_PROJECT="$1"
  VOICEFLOW_XCODE_SCHEME="${2:-VoiceFlow}"
  VOICEFLOW_XCODE_DESTINATION="$3"
  VOICEFLOW_XCODE_ONLY_TESTING=("${@:4}")

  # Repo-local DerivedData: concurrent xcodebuild jobs (other AI sessions,
  # archives, other worktrees) sharing Xcode's default DerivedData contend on
  # its build database lock and can silently queue a test run for minutes. A
  # repo-local store keeps all of this repo's unit/UI/manual builds on one
  # warm cache while isolating them from everything else. The store is safe
  # to delete (`rm -rf <path>`) at the cost of one cold rebuild.
  # Override with VOICEFLOW_DERIVED_DATA.
  local vf_root
  vf_root="$(cd "$(dirname "$1")/../.." && pwd)"
  VOICEFLOW_DERIVED_DATA="${VOICEFLOW_DERIVED_DATA:-$vf_root/.voiceflow/DerivedData}"
}

voiceflow_xcodebuild_run() {
  local action="$1"
  shift

  local -a cmd=(
    xcodebuild
    -project "$VOICEFLOW_XCODE_PROJECT"
    -scheme "$VOICEFLOW_XCODE_SCHEME"
    -destination "$VOICEFLOW_XCODE_DESTINATION"
    -derivedDataPath "$VOICEFLOW_DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    -parallel-testing-enabled
    NO
  )

  if ((${#VOICEFLOW_XCODE_ONLY_TESTING[@]} > 0)); then
    cmd+=("${VOICEFLOW_XCODE_ONLY_TESTING[@]}")
  fi

  cmd+=("$action" "$@")
  "${cmd[@]}"
}

voiceflow_xcodebuild_test_with_rebuild_fallback() {
  local action="$1"
  shift

  if voiceflow_xcodebuild_run "$action" "$@"; then
    return 0
  fi

  if [[ "$action" != "test-without-building" ]]; then
    return 1
  fi

  voiceflow_xcodebuild_run build-for-testing "$@"
  voiceflow_xcodebuild_run test-without-building "$@"
}
