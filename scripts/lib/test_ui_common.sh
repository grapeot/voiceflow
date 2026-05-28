#!/usr/bin/env bash

voiceflow_test_ui_only_testing_args() {
  local suite="$1"
  local -a tests=()

  case "$suite" in
    smoke)
      tests=(
        "VoiceFlowUITests/VoiceFlowUITests/testEnglishAppShell"
        "VoiceFlowUITests/VoiceFlowUITests/testMockStreamingRecordingUpdatesTranscript"
        "VoiceFlowUITests/VoiceFlowUITests/testTokenIsMaskedAfterSavingAndCanBeCleared"
      )
      ;;
    full)
      tests=(
        "VoiceFlowUITests/VoiceFlowUITests/testChineseAppShell"
        "VoiceFlowUITests/VoiceFlowUITests/testDeepLinkRecordStartsMockRecordingFlow"
        "VoiceFlowUITests/VoiceFlowUITests/testEnglishAppShell"
        "VoiceFlowUITests/VoiceFlowUITests/testMockRecordingFlowShowsTranscriptAndClipboardStatus"
        "VoiceFlowUITests/VoiceFlowUITests/testMockStreamingRecordingUpdatesTranscript"
        "VoiceFlowUITests/VoiceFlowUITests/testOpenCodeConfigCanBeSavedAndCleared"
        "VoiceFlowUITests/VoiceFlowUITests/testRecordingControlsExposeHistoryNavigationAndSaveResendMenu"
        "VoiceFlowUITests/VoiceFlowUITests/testSettingsConnectionFailureShowsErrorDetail"
        "VoiceFlowUITests/VoiceFlowUITests/testSettingsDismissesKeyboardWhenTappingOutsideFields"
        "VoiceFlowUITests/VoiceFlowUITests/testSettingsLanguagePreferenceOverridesSystemLanguage"
        "VoiceFlowUITests/VoiceFlowUITests/testTokenIsMaskedAfterSavingAndCanBeCleared"
        "VoiceFlowUITests/VoiceFlowUITests/testTranscriptionSettingsFieldsAcceptInputAndPersistInForm"
      )
      ;;
    perf)
      tests=(
        "VoiceFlowUITests/VoiceFlowUITestsPerformance/testLaunchPerformance"
        "VoiceFlowUITests/VoiceFlowUITestsLaunchTests/testLaunch"
      )
      ;;
    *)
      echo "Unknown UI suite: $suite (expected smoke, full, or perf)" >&2
      return 1
      ;;
  esac

  local -a args=()
  local test_name
  for test_name in "${tests[@]}"; do
    args+=(-only-testing:"$test_name")
  done
  printf '%s\n' "${args[@]}"
}

voiceflow_run_ui_suite() {
  local suite="$1"
  local root="$2"
  local project="$root/src/VoiceFlow/VoiceFlow.xcodeproj"

  # shellcheck source=lib/simulator.sh
  source "$root/scripts/lib/simulator.sh"
  # shellcheck source=lib/xcodebuild_test.sh
  source "$root/scripts/lib/xcodebuild_test.sh"

  cd "$root"
  voiceflow_simulator_prepare_destination "$root"

  UI_ONLY_TESTING=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && UI_ONLY_TESTING+=("$line")
  done <<EOF
$(voiceflow_test_ui_only_testing_args "$suite")
EOF

  voiceflow_xcodebuild_common_args \
    "$project" \
    VoiceFlow \
    "$VOICEFLOW_TEST_DESTINATION" \
    "${UI_ONLY_TESTING[@]}"

  if [[ "${VOICEFLOW_TEST_REBUILD:-}" == "1" ]]; then
    voiceflow_xcodebuild_run build-for-testing
    voiceflow_xcodebuild_run test-without-building
  else
    voiceflow_xcodebuild_test_with_rebuild_fallback test-without-building
  fi
}
