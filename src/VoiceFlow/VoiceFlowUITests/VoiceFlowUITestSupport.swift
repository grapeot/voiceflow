import XCTest

enum VoiceFlowUITestSuite {
    static let defaultTimeout: TimeInterval = 3
}

enum RecordingUIStatus {
    case recording
    case ready
}

extension XCTestCase {
    func launchVoiceFlowApp(
        language: String,
        locale: String,
        extraArguments: [String] = ["-uiTestMode"]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extraArguments + [
            "-uiTestResetPreferences",
            "-AppleLanguages",
            "(\(language))",
            "-AppleLocale",
            locale,
        ]
        app.launch()
        return app
    }

    func waitForRecordingState(
        _ status: RecordingUIStatus,
        in app: XCUIApplication,
        timeout: TimeInterval = VoiceFlowUITestSuite.defaultTimeout
    ) -> Bool {
        switch status {
        case .recording:
            if app.buttons["record.stopButton"].waitForExistence(timeout: timeout) {
                return true
            }
            return app.buttons["Stop"].waitForExistence(timeout: 1)
        case .ready:
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for label in ["Copied to clipboard.", "已复制到剪贴板。"] {
                    if app.staticTexts[label].exists {
                        return true
                    }
                }
                if app.buttons["record.startButton"].exists, !app.buttons["record.stopButton"].exists {
                    return true
                }
                for label in ["Start Recording", "开始录音"] {
                    if app.buttons[label].exists, !app.buttons["Stop"].exists {
                        return true
                    }
                }
                if waitForValue(of: app.otherElements["record.statusIndicator"], containing: "ready", timeout: 0.5) {
                    return true
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return false
        }
    }

    func waitForValue(
        of element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = VoiceFlowUITestSuite.defaultTimeout
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func openSettings(in app: XCUIApplication, label: String) {
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

    func openRecord(in app: XCUIApplication, label: String) {
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

    func tapSegment(_ segmentedControl: XCUIElement, index: Int) {
        let segment = segmentedControl.buttons.element(boundBy: index)
        if segment.waitForExistence(timeout: 1) {
            segment.tap()
            return
        }
        let positions = [0.17, 0.5, 0.83]
        let position = positions[min(index, positions.count - 1)]
        segmentedControl.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
    }

    func scrollSettingsToTop(in app: XCUIApplication) {
        let scrollContainer = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        guard scrollContainer.waitForExistence(timeout: 1) else { return }
        for _ in 0..<3 {
            scrollContainer.swipeDown()
        }
    }

    func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 4) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        scrollSettingsToTop(in: app)
        if element.waitForExistence(timeout: 1) { return true }
        let scrollContainer = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0..<attempts {
            scrollContainer.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }
}
