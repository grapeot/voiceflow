import Foundation

/// Two-layer caption model. Long-lived status (e.g. "Reconnecting…")
/// lives in `persistent`; short confirmations (e.g. "Stream restored.")
/// flash through `transient`. The visible string is `transient ??
/// persistent` so a flash hides whatever's underneath and clears
/// itself after a fixed duration, revealing the *current* persistent
/// state (which may have changed during the flash window).
///
/// The store holds localization **keys**, not display strings. The host
/// is responsible for translating keys into localized text — keeps the
/// kit free of strings catalogs and bilingual maintenance.
public struct StreamCaption: Sendable, Equatable {
    public var persistent: String?
    public var transient: String?

    public init(persistent: String? = nil, transient: String? = nil) {
        self.persistent = persistent
        self.transient = transient
    }

    public var visible: String? {
        transient ?? persistent
    }
}

/// Observable caption state. Mark `@MainActor` because hosts will
/// usually bind it directly to SwiftUI views.
@MainActor
public final class StreamCaptionStore: ObservableObject {
    @Published public private(set) var caption: StreamCaption = .init()

    public let transientDuration: Duration
    private var transientTask: Task<Void, Never>?

    public init(transientDuration: Duration = .seconds(3)) {
        self.transientDuration = transientDuration
    }

    /// Set the long-lived caption layer. Pass `nil` to clear only the
    /// persistent layer (any active transient flash remains).
    public func setPersistent(_ key: String?) {
        caption.persistent = key
    }

    /// Flash a transient caption for `transientDuration`, then clear
    /// itself. Restarts the timer if called while another flash is
    /// active (rather than overlapping).
    public func flashTransient(_ key: String) {
        transientTask?.cancel()
        caption.transient = key
        transientTask = Task { [weak self, duration = transientDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.caption.transient = nil
        }
    }

    /// Clear both layers and cancel any pending transient timer.
    public func clear() {
        transientTask?.cancel()
        transientTask = nil
        caption = .init()
    }
}
