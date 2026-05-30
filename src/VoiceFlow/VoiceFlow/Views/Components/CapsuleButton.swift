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
            .contentShape(PixelRoundedRectangle())
            // Constrain visionOS gaze-hover highlight to the button shape and
            // let `.lift` give a clear focused affordance — otherwise outlined
            // / ghost roles read as "no focus" even when they are the user's
            // gaze target, and focus appears to "jump" to a neighboring filled
            // control.
            .contentShape(.hoverEffect, PixelRoundedRectangle())
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
            PixelRoundedRectangle().fill(DesignTokens.Palette.accent)
        case .secondary:
            PixelRoundedRectangle()
                .stroke(DesignTokens.Palette.accent, lineWidth: 1.5)
        case .ghost:
            Color.clear
        }
    }
}

/// A rounded rectangle whose corners are cut as a staircase of square steps
/// instead of a smooth arc — the "pixel rounded button" used by old games and
/// the OP-1/Playdate visual language. Edges stay perfectly straight; only the
/// four corners step inward by `stepCount` levels of `stepSize` each.
struct PixelRoundedRectangle: Shape {
    /// Number of square steps per corner.
    var stepCount: Int = 3
    /// Side length of each square step, in points.
    var stepSize: CGFloat = 3.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = max(0, stepCount)
        let s = stepSize
        // Inset the straight edges by the full corner depth so the steps fit.
        let inset = CGFloat(steps) * s
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY

        // Walk the outline clockwise. For each corner we emit a staircase of
        // `steps` right-angle treads. Start on the top edge just after the
        // top-left corner.
        path.move(to: CGPoint(x: minX + inset, y: minY))

        // Top edge → top-right corner staircase.
        path.addLine(to: CGPoint(x: maxX - inset, y: minY))
        for i in 0..<steps {
            let x = maxX - inset + CGFloat(i) * s
            path.addLine(to: CGPoint(x: x + s, y: minY + CGFloat(i) * s))
            path.addLine(to: CGPoint(x: x + s, y: minY + CGFloat(i + 1) * s))
        }

        // Right edge → bottom-right corner staircase.
        path.addLine(to: CGPoint(x: maxX, y: maxY - inset))
        for i in 0..<steps {
            let y = maxY - inset + CGFloat(i) * s
            path.addLine(to: CGPoint(x: maxX - CGFloat(i) * s, y: y + s))
            path.addLine(to: CGPoint(x: maxX - CGFloat(i + 1) * s, y: y + s))
        }

        // Bottom edge → bottom-left corner staircase.
        path.addLine(to: CGPoint(x: minX + inset, y: maxY))
        for i in 0..<steps {
            let x = minX + inset - CGFloat(i) * s
            path.addLine(to: CGPoint(x: x - s, y: maxY - CGFloat(i) * s))
            path.addLine(to: CGPoint(x: x - s, y: maxY - CGFloat(i + 1) * s))
        }

        // Left edge → top-left corner staircase.
        path.addLine(to: CGPoint(x: minX, y: minY + inset))
        for i in 0..<steps {
            let y = minY + inset - CGFloat(i) * s
            path.addLine(to: CGPoint(x: minX + CGFloat(i) * s, y: y - s))
            path.addLine(to: CGPoint(x: minX + CGFloat(i + 1) * s, y: y - s))
        }

        path.closeSubpath()
        return path
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
