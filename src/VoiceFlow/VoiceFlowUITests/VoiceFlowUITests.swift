import XCTest

final class VoiceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEnglishAppShell() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Recording..."].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Transcript ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].waitForExistence(timeout: 5))

        app.buttons["Send to OpenCode"].tap()
        XCTAssertTrue(app.staticTexts["Sent to OpenCode."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOpenCodeConfigCanBeSavedAndCleared() throws {
        let app = launchApp(language: "en", locale: "en_US", extraArguments: ["-uiTestMode"])

        openSettings(in: app, label: "Settings")
        let passwordField = app.secureTextFields["settings.openCodePasswordField"]
        XCTAssertTrue(reveal(passwordField, in: app))
        passwordField.tap()
        passwordField.typeText("fake-opencode-password")
        app.buttons["settings.saveOpenCodeButton"].tap()

        XCTAssertTrue(app.staticTexts["Configured"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.openCodePasswordMaskedValue"].exists)

        app.buttons["settings.clearOpenCodeButton"].tap()
        XCTAssertTrue(app.secureTextFields["settings.openCodePasswordField"].waitForExistence(timeout: 5))
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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchApp(language: String, locale: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extraArguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication, label: String) {
        app.tabBars.buttons[label].tap()
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
    private func waitForValue(of element: XCUIElement, containing text: String) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
