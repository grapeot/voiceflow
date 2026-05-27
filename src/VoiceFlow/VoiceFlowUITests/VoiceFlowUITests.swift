//
//  VoiceFlowUITests.swift
//  VoiceFlowUITests
//
//  Created by Yan Wang on 5/26/26.
//

import XCTest

final class VoiceFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testEnglishAppShell() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Send to OpenCode"].exists)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["settings.apiTokenField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://space.ai-builders.com/backend"].exists)
    }

    @MainActor
    func testTokenIsMaskedAfterSavingAndCanBeCleared() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        app.tabBars.buttons["Settings"].tap()
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
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "-uiTestSavedToken", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.buttons["Start Recording"].waitForExistence(timeout: 5))
        app.buttons["Start Recording"].tap()
        XCTAssertTrue(app.staticTexts["Recording..."].waitForExistence(timeout: 5))

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Mock transcription"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Copied to clipboard."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChineseAppShell() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans_US"]
        app.launch()

        XCTAssertTrue(app.buttons["开始录音"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["复制"].exists)

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["测试连接"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
