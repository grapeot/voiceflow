import SwiftUI

/// Replaces the dot+title combo in `RecordingStatusHeaderView`. Status is
/// conveyed through a single line of muted text under the timer; color
/// pops to amber only when the waveform is actively recording.
struct StatusText: View {
    enum Role {
        case neutral   // text.secondary — most states
        case accent    // amber — recording in progress
        case muted     // text.tertiary — disconnected, idle hints
    }

    let key: LocalizedStringKey
    let role: Role

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.localizationBundle) private var localizationBundle

    var body: some View {
        Text(key)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("record.statusText")
    }

    /// English captions ("Listening", "Generating") render in the Silkscreen
    /// pixel font; Chinese captions keep the system caption face (Silkscreen has
    /// no CJK). We resolve the key against the active localization bundle to
    /// inspect the actual rendered text, then pick the face.
    private var font: Font {
        DesignTokens.PixelType.font(
            for: resolvedText,
            pixel: DesignTokens.PixelType.caption,
            fallback: DesignTokens.Typography.caption
        )
    }

    private var resolvedText: String {
        StatusText.resolvedString(from: key, bundle: localizationBundle)
    }

    private var color: Color {
        switch role {
        case .neutral: return DesignTokens.Palette.textSecondary.color(for: colorScheme)
        case .accent:  return DesignTokens.Palette.accent
        case .muted:   return DesignTokens.Palette.textTertiary.color(for: colorScheme)
        }
    }

    /// Recovers the underlying key string from a `LocalizedStringKey` via
    /// reflection, then localizes it against `bundle`. SwiftUI exposes no public
    /// accessor for the key, so we read the private `key` mirror child; if the
    /// shape ever changes we fall back to the description, which is safe — the
    /// only consequence of a miss is that a Latin caption renders in the system
    /// font instead of the pixel font. Strings built from already-localized text
    /// (e.g. a formatted status line) have a `key` equal to that text, so the
    /// CJK check still routes them correctly.
    static func resolvedString(from key: LocalizedStringKey, bundle: Bundle) -> String {
        let mirror = Mirror(reflecting: key)
        let rawKey = mirror.children.first { $0.label == "key" }?.value as? String
            ?? "\(key)"
        return String(localized: String.LocalizationValue(rawKey), bundle: bundle)
    }
}
