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

    var body: some View {
        Text(key)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("record.statusText")
    }

    private var color: Color {
        switch role {
        case .neutral: return DesignTokens.Palette.textSecondary
        case .accent:  return DesignTokens.Palette.accent
        case .muted:   return DesignTokens.Palette.textTertiary
        }
    }
}
