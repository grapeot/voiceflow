import Foundation

/// Two-layer stream status caption. `persistentStreamCaptionKey` holds
/// long-lived status (e.g. "Reconnecting…"); `flashTransientStreamCaption`
/// briefly overlays a confirmation that auto-clears after
/// `transientStreamCaptionDuration`. `RecordView` reads
/// `streamStatusCaptionKey`, which prefers the transient layer.
extension AppState {
    /// Localization keys for the stream-status captions. Centralized to
    /// avoid the literal string drifting between `+LiveSession` (the
    /// state machine) and `+StreamCaption` (the setters/clearers).
    enum StreamCaptionKey {
        static let reconnecting = "record.status.reconnecting"
        static let reconnected = "record.status.reconnected"
        static let streamDisconnected = "record.error.streamDisconnected"
    }

    enum SignalCaptionKey {
        static let noSignalLive = "record.signal.noSignalLive"
    }
}

extension AppState {
    /// Set the long-lived stream caption. Pass `nil` to clear only the
    /// persistent layer (transient overlay stays visible if active).
    func setPersistentStreamCaption(_ key: String?) {
        persistentStreamCaptionKey = key
    }

    /// Flash a short confirmation for `transientStreamCaptionDuration`.
    /// After the delay, the transient layer clears itself, exposing the
    /// current persistent caption (which may have changed in the meantime).
    /// Multiple flashes restart the timer rather than overlap.
    func flashTransientStreamCaption(_ key: String) {
        transientStreamCaptionTask?.cancel()
        transientStreamCaptionKey = key
        transientStreamCaptionTask = Task { [weak self, duration = transientStreamCaptionDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.transientStreamCaptionKey = nil }
        }
    }

    /// Clear both caption layers (used by teardown / reset paths).
    func clearStreamCaptions() {
        transientStreamCaptionTask?.cancel()
        transientStreamCaptionTask = nil
        transientStreamCaptionKey = nil
        persistentStreamCaptionKey = nil
    }
}
