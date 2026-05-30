import SwiftUI

/// Replaces the old fixed-size `ColoredButtonStyle`. Pill-shaped, intrinsic
/// width so localized labels (en/zh) never get truncated. Three roles cover
/// the screen's needs without introducing a second hue.
enum CapsuleButtonRole {
    case primary       // amber fill, black label — the one CTA on screen
    case secondary     // outlined amber border + amber label — counterweight
    case ghost         // text-only, no fill, no border — tertiary action
}

struct CapsuleButton: View {
    let title: LocalizedStringKey
    let role: CapsuleButtonRole
    let action: () -> Void
    /// Optional SF Symbol icon. Kept for callers that still want a smooth
    /// glyph; the Record screen uses `pixelIcon` instead.
    var icon: String? = nil
    /// Optional pixel-grid glyph drawn in the same language as the label and
    /// tab bar. Takes precedence over `icon` when set.
    var pixelIcon: PixelButtonGlyph? = nil
    var isEnabled: Bool = true

    @Environment(\.localizationBundle) private var localizationBundle

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if let pixelIcon {
                    PixelGlyphView(glyph: pixelIcon, size: 17)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    // Button labels (STOP / Record) use the regular system face
                    // — the Pixelate look is dialed back to a hint, so the label
                    // is no longer the chunky pixel font.
                    .font(labelFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .frame(height: DesignTokens.Sizing.buttonHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundView)
            .opacity(isEnabled ? 1.0 : 0.4)
            // Keep outlined roles tappable across the whole visual pill, not
            // only around the label or stroked edge.
            .contentShape(Capsule())
            // Constrain visionOS gaze-hover highlight to the button shape and
            // let `.lift` give a clear focused affordance — otherwise outlined
            // / ghost roles read as "no focus" even when they are the user's
            // gaze target, and focus appears to "jump" to a neighboring filled
            // control.
            .contentShape(.hoverEffect, Capsule())
            .hoverEffect(.lift)
        }
        .buttonStyle(CapsulePressStyle())
        .disabled(!isEnabled)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var labelFont: Font {
        DesignTokens.Typography.buttonLabel
    }

    private var foregroundColor: Color {
        switch role {
        case .primary:   return DesignTokens.Palette.onAccent
        case .secondary: return DesignTokens.Palette.accent
        case .ghost:     return DesignTokens.Palette.textSecondary.color(for: colorScheme)
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch role {
        case .primary:
            Capsule().fill(DesignTokens.Palette.accent)
        case .secondary:
            Capsule()
                .stroke(DesignTokens.Palette.accent, lineWidth: 1.5)
        case .ghost:
            Color.clear
        }
    }
}


private struct CapsulePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 16) {
        CapsuleButton(title: "Record", role: .primary, action: {})
        CapsuleButton(title: "Stop",   role: .secondary, action: {})
        CapsuleButton(title: "开始录音", role: .primary, action: {})
        CapsuleButton(title: "Test",   role: .ghost, action: {})
    }
    .padding()
    .background(DesignTokens.Palette.bgPrimary)
}
