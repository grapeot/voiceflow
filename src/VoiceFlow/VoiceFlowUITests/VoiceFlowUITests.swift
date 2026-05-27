import XCTest

final class VoiceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishAppShell() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["VoiceFlow"].exists)
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Send to OpenCode"].exists)

        openSettings(in: app, label: "Settings")
        XCTAssertTrue(app.secureTextFields["settings.apiTokenField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://space.ai-builders.com/backend"].exists)
        XCTAssertTrue(reveal(app.textFields["settings.openCodeServerURLField"], in: app))
        XCTAssertTrue(app.textFields["settings.openCodeUsernameField"].exists)
    }

    @MainActor
    func testTokenIsMaskedAfterSavingAndCanBeCleared() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        openSettings(in: app, label: "Settings")
        let tokenField = app.secureTextFields["settings.apiTokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
        tokenField.tap()
        tokenField.typeText("fake-ui-token")
        app.buttons["settings.saveTokenButton"].tap()

        XCTAssertTrue(app.staticTexts["settings.apiTokenMaskedValue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["fake-ui-token"].exists)

        app.buttons["settings.testConnectionButton"].tap()
        XCTAssertTrue(app.staticTexts["Connection OK"].waitForExistence(timeout: 5))

        app.buttons["settings.clearTokenButton"].tap()
        XCTAssertTrue(app.secureTextFields["settings.apiTokenField"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMockRecordingFlowShowsTranscriptAndClipboardStatus() throws {
        let app = launchApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken", "-uiTestSavedOpenCode"]
        )

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
        app.buttons["Start Recording"].tap()
        XCTAssertTrue(waitForRecordingIndicator(in: app, status: "recording"))
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))

        app.buttons["Stop"].tap()
        XCTAssertTrue(waitForRecordingIndicator(in: app, status: "ready"))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].waitForExistence(timeout: 5))

        app.buttons["Send to OpenCode"].tap()
        XCTAssertTrue(app.staticTexts["Sent to OpenCode."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOpenCodeConfigCanBeSavedAndCleared() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        openSettings(in: app, label: "Settings")
        let serverURLField = app.textFields["settings.openCodeServerURLField"]
        XCTAssertTrue(reveal(serverURLField, in: app))
        serverURLField.tap()
        serverURLField.clearAndEnterText("http://voiceflow.test:4096")

        let usernameField = app.textFields["settings.openCodeUsernameField"]
        usernameField.tap()
        usernameField.clearAndEnterText("voiceflow-user")

        let passwordField = app.secureTextFields["settings.openCodePasswordField"]
        XCTAssertTrue(reveal(passwordField, in: app))
        passwordField.tap()
        passwordField.typeText("fake-opencode-password")
        app.buttons["settings.saveOpenCodeButton"].tap()

        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.openCodePasswordMaskedValue"].exists)
        app.buttons["settings.testOpenCodeConnectionButton"].tap()
        XCTAssertTrue(app.staticTexts["Connection OK"].waitForExistence(timeout: 5))

        app.buttons["settings.clearOpenCodeButton"].tap()
        XCTAssertTrue(app.secureTextFields["settings.openCodePasswordField"].waitForExistence(timeout: 5))
        XCTAssertEqual(serverURLField.value as? String, "http://voiceflow.test:4096")
        XCTAssertEqual(usernameField.value as? String, "voiceflow-user")
    }

    @MainActor
    func testSettingsConnectionFailureShowsErrorDetail() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode", "-uiTestOpenCodeConnectionFailure"])

        openSettings(in: app, label: "Settings")
        let passwordField = app.secureTextFields["settings.openCodePasswordField"]
        XCTAssertTrue(reveal(passwordField, in: app))
        passwordField.tap()
        passwordField.typeText("fake-opencode-password")
        app.buttons["settings.saveOpenCodeButton"].tap()
        app.buttons["settings.testOpenCodeConnectionButton"].tap()

        XCTAssertTrue(app.staticTexts["Connection failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.openCodeConnectionStatusDetail"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsDismissesKeyboardWhenTappingOutsideFields() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        openSettings(in: app, label: "Settings")
        let tokenField = app.secureTextFields["settings.apiTokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
        tokenField.tap()
        tokenField.typeText("fake-ui-token")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))

        app.staticTexts["settings.endpointTitle"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testChineseAppShell() throws {
        let app = launchApp(language: "zh-Hans", locale: "zh_Hans_US", extraArguments: ["-uiTestMode"])

        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["复制"].exists)

        openSettings(in: app, label: "设置")
        XCTAssertTrue(app.buttons["测试连接"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsLanguagePreferenceOverridesSystemLanguage() throws {
        var app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
        app.buttons["Start Recording"].tap()
        let missingTokenAlert = app.alerts.firstMatch
        XCTAssertTrue(missingTokenAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(missingTokenAlert.staticTexts["Save an AI Builder token before recording."].exists)
        missingTokenAlert.buttons.matching(identifier: "record.error.alert.okButton").element(boundBy: 0).tap()
        openSettings(in: app, label: "Settings")
        let languagePicker = app.segmentedControls["settings.languagePicker"]
        XCTAssertTrue(reveal(languagePicker, in: app))

        tapSegment(languagePicker, position: 0.84)

        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        app.buttons["开始录音"].tap()
        let chineseMissingTokenAlert = app.alerts.firstMatch
        XCTAssertTrue(chineseMissingTokenAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(chineseMissingTokenAlert.staticTexts["录音前请先保存 AI Builder token。"].exists)
        chineseMissingTokenAlert.buttons.matching(identifier: "record.error.alert.okButton").element(boundBy: 0).tap()

        app.terminate()
        app = launchApp(language: "zh-Hans", locale: "zh_Hans_US", extraArguments: ["-uiTestMode"])
        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        openSettings(in: app, label: "设置")
        let chineseSystemLanguagePicker = app.segmentedControls["settings.languagePicker"]
        XCTAssertTrue(reveal(chineseSystemLanguagePicker, in: app))
        tapSegment(chineseSystemLanguagePicker, position: 0.50)

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecordingControlsExposeHistoryNavigationAndSaveResendMenu() throws {
        let app = launchApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken"]
        )

        let previousButton = app.buttons["record.historyPreviousButton"]
        let nextButton = app.buttons["record.historyNextButton"]
        let moreButton = app.buttons["record.moreButton"]
        XCTAssertTrue(previousButton.waitForExistence(timeout: 5))
        XCTAssertTrue(nextButton.exists)
        XCTAssertTrue(moreButton.exists)
        XCTAssertFalse(previousButton.isEnabled)
        XCTAssertFalse(nextButton.isEnabled)

        app.buttons["Start Recording"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        app.buttons["Stop"].tap()
        XCTAssertTrue(waitForRecordingIndicator(in: app, status: "ready"))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].waitForExistence(timeout: 5))

        moreButton.tap()
        let saveButton = app.buttons.matching(identifier: "record.saveRecordingButton").firstMatch
        let resendButton = app.buttons.matching(identifier: "record.resendRecordingButton").firstMatch
        if !saveButton.waitForExistence(timeout: 2) {
            XCTAssertTrue(app.buttons["Save Recording"].waitForExistence(timeout: 2))
            XCTAssertTrue(app.buttons["Resend Recording"].exists)
            app.buttons["Save Recording"].tap()
        } else {
            XCTAssertTrue(resendButton.exists)
            XCTAssertTrue(saveButton.isEnabled)
            XCTAssertTrue(resendButton.isEnabled)
            saveButton.tap()
        }
        XCTAssertTrue(app.staticTexts["Recording saved to Documents."].waitForExistence(timeout: 5))

        moreButton.tap()
        if resendButton.exists {
            resendButton.tap()
        } else {
            app.buttons["Resend Recording"].tap()
        }
        XCTAssertTrue(waitForRecordingIndicator(in: app, status: "ready"))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeepLinkRecordStartsMockRecordingFlow() throws {
        let app = launchApp(
            language: "en",
            locale: "en_US",
            extraArguments: ["-uiTestMode", "-uiTestSavedToken", "-uiTestDeepLinkRecord"]
        )

        XCTAssertTrue(waitForRecordingIndicator(in: app, status: "recording"))
        XCTAssertTrue(app.staticTexts["VoiceFlow"].exists)
        XCTAssertTrue(app.buttons["Stop"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchApp(language: String, locale: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extraArguments + ["-uiTestResetPreferences", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication, label: String) {
        for candidate in ["tab.settings", label, "Settings", "设置"] {
            let button = app.tabBars.buttons[candidate]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
        }

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 1) {
            tabBar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            return
        }

        XCTFail("Settings tab was not found")
    }

    @MainActor
    private func openRecord(in app: XCUIApplication, label: String) {
        for candidate in ["tab.record", label, "Record", "录音"] {
            let button = app.tabBars.buttons[candidate]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
        }

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 1) {
            tabBar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            return
        }

        XCTFail("Record tab was not found")
    }

    @MainActor
    private func tapSegment(_ segmentedControl: XCUIElement, position: Double) {
        let coordinate = segmentedControl.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5))
        coordinate.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 4) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        let scrollContainer = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0..<attempts {
            scrollContainer.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    @MainActor
    private func waitForRecordingIndicator(in app: XCUIApplication, status: String) -> Bool {
        let indicator = app.otherElements["record.statusIndicator"]
        return waitForValue(of: indicator, containing: status)
    }

    @MainActor
    private func waitForValue(of element: XCUIElement, containing text: String) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}

private extension XCUIElement {
    func clearAndEnterText(_ text: String) {
        tap()
        if let currentValue = value as? String, !currentValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            typeText(deleteString)
        }
        typeText(text)
    }
}
