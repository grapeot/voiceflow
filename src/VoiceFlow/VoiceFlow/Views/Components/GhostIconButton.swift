import SwiftUI

/// Tertiary icon-only action: history chevrons, the more-menu trigger,
/// in-place copy. Stays at `text.tertiary` weight so it never competes with
/// the waveform or the primary CTA.
struct GhostIconButton: View {
    let systemName: String
    let action: () -> Void
    var isEnabled: Bool = true
    var accessibilityLabel: LocalizedStringKey? = nil

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DesignTokens.Sizing.ghostIcon, weight: .regular))
                .frame(width: DesignTokens.Sizing.ghostButton,
                       height: DesignTokens.Sizing.ghostButton)
                .foregroundStyle(
                    isEnabled
                    ? DesignTokens.Palette.textSecondary
                    : DesignTokens.Palette.textTertiary
                )
                .opacity(isEnabled ? 1.0 : 0.6)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.lift)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel.map { Text($0) } ?? Text(verbatim: ""))
    }
}
