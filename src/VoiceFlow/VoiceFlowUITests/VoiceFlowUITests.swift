import XCTest

final class VoiceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnglishAppShell() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        XCTAssertTrue(app.buttons["record.startButton"].waitForExistence(timeout: 10))
        // Copy and OpenCode now live in the more menu — assert the menu exists,
        // not the standalone buttons that the old bottom row exposed.
        XCTAssertTrue(app.buttons["record.moreButton"].waitForExistence(timeout: 2))

        openSettings(in: app, label: "Settings")
        XCTAssertTrue(app.secureTextFields["settings.apiTokenField"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(app.staticTexts["https://space.ai-builders.com/backend"].exists)
        XCTAssertTrue(reveal(app.textFields["settings.openCodeServerURLField"], in: app))
        XCTAssertTrue(app.textFields["settings.openCodeUsernameField"].exists)
    }

    func testTokenIsMaskedAfterSavingAndCanBeCleared() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        openSettings(in: app, label: "Settings")
        let tokenField = app.secureTextFields["settings.apiTokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        tokenField.tap()
        tokenField.typeText("fake-ui-token")
        app.buttons["settings.saveTokenButton"].tap()

        XCTAssertTrue(app.staticTexts["settings.apiTokenMaskedValue"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertFalse(app.staticTexts["fake-ui-token"].exists)

        app.buttons["settings.testConnectionButton"].tap()
        XCTAssertTrue(app.staticTexts["Connection OK"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))

        app.buttons["settings.clearTokenButton"].tap()
        XCTAssertTrue(app.secureTextFields["settings.apiTokenField"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
    }

    func testMockRecordingFlowShowsTranscriptAndClipboardStatus() throws {
        let app = launchVoiceFlowApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken", "-uiTestSavedOpenCode"]
        )

        let startButton = app.buttons["record.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        startButton.tap()
        XCTAssertTrue(waitForRecordingState(.recording, in: app, timeout: 8))

        let stopButton = app.buttons["record.stopButton"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        stopButton.tap()
        XCTAssertTrue(waitForRecordingState(.ready, in: app, timeout: 8))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].exists)

        // Send-to-OpenCode is now nested inside the more menu.
        app.buttons["record.moreButton"].tap()
        let sendButton = app.buttons["record.sendOpenCodeButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        sendButton.tap()
        XCTAssertTrue(app.staticTexts["Sent to OpenCode."].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
    }

    func testOpenCodeConfigCanBeSavedAndCleared() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        openSettings(in: app, label: "Settings")
        scrollSettingsToTop(in: app)

        let passwordField = app.secureTextFields["settings.openCodePasswordField"]
        XCTAssertTrue(reveal(passwordField, in: app, attempts: 8))
        passwordField.tap()
        passwordField.typeText("fake-opencode-password")

        let saveOpenCodeButton = app.buttons["settings.saveOpenCodeButton"]
        XCTAssertTrue(reveal(saveOpenCodeButton, in: app, attempts: 6))
        saveOpenCodeButton.tap()

        XCTAssertTrue(app.staticTexts["settings.openCodePasswordMaskedValue"].waitForExistence(timeout: 8))
        app.buttons["settings.testOpenCodeConnectionButton"].tap()
        XCTAssertTrue(app.staticTexts["Connection OK"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))

        app.buttons["settings.clearOpenCodeButton"].tap()
        XCTAssertTrue(app.secureTextFields["settings.openCodePasswordField"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(app.textFields["settings.openCodeServerURLField"].exists)
        XCTAssertTrue(app.textFields["settings.openCodeUsernameField"].exists)
    }

    func testSettingsConnectionFailureShowsErrorDetail() throws {
        let app = launchVoiceFlowApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestOpenCodeConnectionFailure"]
        )

        openSettings(in: app, label: "Settings")
        let passwordField = app.secureTextFields["settings.openCodePasswordField"]
        XCTAssertTrue(reveal(passwordField, in: app))
        passwordField.tap()
        passwordField.typeText("fake-opencode-password")
        app.buttons["settings.saveOpenCodeButton"].tap()
        app.buttons["settings.testOpenCodeConnectionButton"].tap()

        XCTAssertTrue(app.staticTexts["Connection failed"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["settings.openCodeConnectionStatusDetail"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
    }

    func testSettingsDismissesKeyboardWhenTappingOutsideFields() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        openSettings(in: app, label: "Settings")
        let tokenField = app.secureTextFields["settings.apiTokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        tokenField.tap()
        tokenField.typeText("fake-ui-token")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))

        app.staticTexts["settings.endpointTitle"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
    }

    func testChineseAppShell() throws {
        let app = launchVoiceFlowApp(language: "zh-Hans", locale: "zh_Hans_US")

        XCTAssertTrue(app.buttons["record.startButton"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(app.buttons["录音"].exists)

        openSettings(in: app, label: "设置")
        XCTAssertTrue(app.buttons["settings.testConnectionButton"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
    }

    func testSettingsLanguagePreferenceOverridesSystemLanguage() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        let startButton = app.buttons["record.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        startButton.tap()
        let missingTokenAlert = app.alerts.firstMatch
        XCTAssertTrue(missingTokenAlert.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(missingTokenAlert.staticTexts["Save an AI Builder token before recording."].exists)
        missingTokenAlert.buttons.matching(identifier: "record.error.alert.okButton").element(boundBy: 0).tap()

        openSettings(in: app, label: "Settings")
        let languagePicker = app.segmentedControls["settings.languagePicker"]
        XCTAssertTrue(reveal(languagePicker, in: app))
        tapSegment(languagePicker, index: 2)

        openRecord(in: app, label: "Record")
        let zhStartButton = app.buttons["record.startButton"]
        XCTAssertTrue(zhStartButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        zhStartButton.tap()
        let chineseMissingTokenAlert = app.alerts.firstMatch
        XCTAssertTrue(chineseMissingTokenAlert.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(chineseMissingTokenAlert.staticTexts["录音前请先保存 AI Builder token。"].exists)
        chineseMissingTokenAlert.buttons.matching(identifier: "record.error.alert.okButton").element(boundBy: 0).tap()

        app.terminate()
        let relaunched = launchVoiceFlowApp(language: "zh-Hans", locale: "zh_Hans_US")

        openSettings(in: relaunched, label: "设置")
        let chineseSystemLanguagePicker = relaunched.segmentedControls["settings.languagePicker"]
        XCTAssertTrue(reveal(chineseSystemLanguagePicker, in: relaunched))
        tapSegment(chineseSystemLanguagePicker, index: 0)

        openRecord(in: relaunched, label: "录音")
        // System language follows simulator locale (zh-Hans here).
        XCTAssertTrue(relaunched.buttons["record.startButton"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
    }

    func testRecordingControlsExposeHistoryNavigationAndSaveResendMenu() throws {
        let app = launchVoiceFlowApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken"]
        )

        let previousButton = app.buttons["record.historyPreviousButton"]
        let nextButton = app.buttons["record.historyNextButton"]
        let moreButton = app.buttons["record.moreButton"]
        XCTAssertTrue(previousButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(nextButton.exists)
        XCTAssertTrue(moreButton.exists)
        XCTAssertFalse(previousButton.isEnabled)
        XCTAssertFalse(nextButton.isEnabled)

        app.buttons["record.startButton"].tap()
        XCTAssertTrue(app.buttons["record.stopButton"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        app.buttons["record.stopButton"].tap()
        XCTAssertTrue(waitForRecordingState(.ready, in: app, timeout: 8))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].exists)

        moreButton.tap()
        let saveButton = app.buttons.matching(identifier: "record.saveRecordingButton").firstMatch
        let resendButton = app.buttons.matching(identifier: "record.resendRecordingButton").firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        XCTAssertTrue(resendButton.exists)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertTrue(resendButton.isEnabled)
        saveButton.tap()
        XCTAssertTrue(app.staticTexts["Recording Saved"].waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        app.buttons.matching(identifier: "record.save.confirmation.okButton").element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'recording_'")).firstMatch.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))

        moreButton.tap()
        resendButton.tap()
        XCTAssertTrue(waitForRecordingState(.ready, in: app, timeout: 15))
    }

    func testDeepLinkRecordStartsMockRecordingFlow() throws {
        let app = launchVoiceFlowApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken", "-uiTestDeepLinkRecord"]
        )

        XCTAssertTrue(waitForRecordingState(.recording, in: app, timeout: 8))
        XCTAssertTrue(app.buttons["record.stopButton"].exists)
    }

    func testMockStreamingRecordingUpdatesTranscript() throws {
        let app = launchVoiceFlowApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken"]
        )

        let startButton = app.buttons["record.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        startButton.tap()
        XCTAssertTrue(waitForRecordingState(.recording, in: app, timeout: 8))

        app.buttons["record.stopButton"].tap()
        XCTAssertTrue(waitForRecordingState(.ready, in: app, timeout: 8))

        let transcript = app.textViews["record.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: VoiceFlowUITestSuite.defaultTimeout))
        let transcriptText = transcript.value as? String ?? ""
        XCTAssertGreaterThan(transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).count, 3)
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].exists)
    }

    func testTranscriptionSettingsFieldsAcceptInputAndPersistInForm() throws {
        let app = launchVoiceFlowApp(language: "en", locale: "en_US")

        openSettings(in: app, label: "Settings")

        let promptField = app.textFields["settings.transcriptionPromptField"]
        XCTAssertTrue(reveal(promptField, in: app))
        promptField.tap()
        promptField.typeText("Talking about Kubernetes")

        let termsField = app.textFields["settings.transcriptionTermsField"]
        XCTAssertTrue(reveal(termsField, in: app))
        termsField.tap()
        termsField.typeText("k8s, gRPC")

        // Hop to Record and back to dismiss the keyboard reliably, then
        // verify the typed values survived the round-trip.
        openRecord(in: app, label: "Record")
        openSettings(in: app, label: "Settings")
        XCTAssertTrue(reveal(promptField, in: app))
        XCTAssertEqual(promptField.value as? String, "Talking about Kubernetes")
        XCTAssertEqual(termsField.value as? String, "k8s, gRPC")
    }
}
