import SwiftUI

#if os(iOS)
import UIKit

extension View {
    func dismissKeyboardOnTapOutsideTextInputs() -> some View {
        background(DismissKeyboardOnTapInstaller())
    }
}

private struct DismissKeyboardOnTapInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughView()
        view.onMovedToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var hostView: UIView?
        private var tapRecognizer: UITapGestureRecognizer?

        func install(on window: UIWindow?) {
            guard let window, hostView !== window else { return }
            uninstall()
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            hostView = window
            tapRecognizer = tap
        }

        func uninstall() {
            if let hostView, let tapRecognizer {
                hostView.removeGestureRecognizer(tapRecognizer)
            }
            hostView = nil
            tapRecognizer = nil
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UISearchBar {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}

private final class PassThroughView: UIView {
    var onMovedToWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMovedToWindow?(window)
    }
}
#else
extension View {
    func dismissKeyboardOnTapOutsideTextInputs() -> some View {
        self
    }
}
#endif
