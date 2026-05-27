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
