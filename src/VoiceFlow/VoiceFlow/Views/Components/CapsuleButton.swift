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
    var icon: String? = nil
    var isEnabled: Bool = true

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(DesignTokens.Typography.buttonLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .frame(height: DesignTokens.Sizing.buttonHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundView)
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(CapsulePressStyle())
        .disabled(!isEnabled)
    }

    @Environment(\.colorScheme) private var colorScheme

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
