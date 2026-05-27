import XCTest

/// Launch performance metrics; run via `./scripts/test_ui_perf.sh` only.
final class VoiceFlowUITestsPerformance: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestMode", "-uiTestResetPreferences"]
            app.launch()
        }
    }
}
