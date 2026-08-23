import Foundation
import UIKit

protocol ScreenIdleControlling: AnyObject {
    func setIdleTimerDisabled(_ disabled: Bool)
}

final class SystemScreenIdleController: ScreenIdleControlling {
    func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

final class MockScreenIdleController: ScreenIdleControlling {
    private(set) var isIdleTimerDisabled = false
    private(set) var setCount = 0
    private(set) var values: [Bool] = []

    func setIdleTimerDisabled(_ disabled: Bool) {
        isIdleTimerDisabled = disabled
        setCount += 1
        values.append(disabled)
    }
}
