#!/usr/bin/env bash

voiceflow_xcodebuild_common_args() {
  VOICEFLOW_XCODE_PROJECT="$1"
  VOICEFLOW_XCODE_SCHEME="${2:-VoiceFlow}"
  VOICEFLOW_XCODE_DESTINATION="$3"
  VOICEFLOW_XCODE_ONLY_TESTING=("${@:4}")
}

voiceflow_xcodebuild_run() {
  local action="$1"
  shift

  local -a cmd=(
    xcodebuild
    -project "$VOICEFLOW_XCODE_PROJECT"
    -scheme "$VOICEFLOW_XCODE_SCHEME"
    -destination "$VOICEFLOW_XCODE_DESTINATION"
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
