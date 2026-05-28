import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Single source of truth for VoiceFlow's visual language: amber accent on
/// deep ink at night and warm paper-white during the day. See `docs/design.md`
/// for the spec these tokens implement.
enum DesignTokens {
    enum Palette {
        static let bgPrimary       = DynamicColor(light: 0xFAFAF7, dark: 0x0A0A0B)
        static let bgSecondary     = DynamicColor(light: 0xF2F2EE, dark: 0x141416)
        static let textPrimary     = DynamicColor(light: 0x1A1A1A, dark: 0xF4F4F5)
        static let textSecondary   = DynamicColor(light: 0x71717A, dark: 0xA1A1AA)
        static let textTertiary    = DynamicColor(light: 0xA1A1AA, dark: 0x52525B)
        static let divider         = DynamicColor(light: 0xE4E4E1, dark: 0x27272A)
        static let accent          = Color(hex: 0xF0A868)
        static let accentMuted     = Color(hex: 0xF0A868, alpha: 0.2)
        /// Used for the "Stop" / destructive action: still amber-family so we
        /// stay single-hue, but rendered as outline to differ from primary.
        static let onAccent        = Color.black
    }

    enum Typography {
        static let timer       = Font.system(size: 56, weight: .thin,    design: .default)
        static let title       = Font.system(size: 28, weight: .medium,  design: .default)
        static let body        = Font.system(size: 17, weight: .regular, design: .default)
        static let bodyBold    = Font.system(size: 17, weight: .medium,  design: .default)
        static let caption     = Font.system(size: 14, weight: .regular, design: .default)
        static let captionSub  = Font.system(size: 13, weight: .regular, design: .default)
        static let buttonLabel = Font.system(size: 15, weight: .medium,  design: .default)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 16
        static let l:  CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Sizing {
        static let buttonHeight: CGFloat = 56
        static let ghostButton:  CGFloat = 36
        static let ghostIcon:    CGFloat = 18
        static let waveformHeight: CGFloat = 80
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// A color token that resolves to its light or dark variant by reading
/// SwiftUI's `colorScheme` environment value at draw time. Used as a
/// `ShapeStyle` (it conforms via `resolve(in:)`), so existing call sites
/// like `.foregroundStyle(DesignTokens.Palette.textPrimary)` keep working.
///
/// Why not just use `Color(UIColor { traits in ... })`? On visionOS the
/// UIKit trait collection's `userInterfaceStyle` is pinned to `.dark`
/// (Vision Pro uses glass UI by default), so the UIKit dynamic provider
/// would lock the app to dark regardless of the user's Settings →
/// Appearance choice. SwiftUI's `colorScheme` env, however, does reflect
/// the system Appearance on visionOS, matching first-party apps like
/// Safari that flip Light/Dark via Settings → Appearance.
struct DynamicColor: ShapeStyle, View, Sendable {
    let lightHex: UInt32
    let darkHex: UInt32

    init(light: UInt32, dark: UInt32) {
        self.lightHex = light
        self.darkHex = dark
    }

    /// `ShapeStyle` resolver — picked up by `.foregroundStyle(...)`,
    /// `.fill(...)`, `.background(...)`, `.tint(...)` etc.
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark
            ? Color(hex: darkHex)
            : Color(hex: lightHex)
    }

    /// Explicit resolution for call sites that need a concrete `Color`
    /// (e.g. SwiftUI Canvas painting, custom shape drawing). Reach for
    /// `@Environment(\.colorScheme)` at the call site and pass it in.
    func color(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(hex: darkHex)
            : Color(hex: lightHex)
    }

    /// View body — allows direct rendering, e.g.
    /// `DesignTokens.Palette.bgPrimary.ignoresSafeArea()`. The rectangle
    /// resolves itself from the environment, so it matches the
    /// containing view's colorScheme without any explicit wiring.
    var body: some View {
        EnvironmentReader { env in
            Rectangle().fill(resolve(in: env))
        }
    }
}

/// Tiny helper to read environment values inside a `@ViewBuilder` body.
/// `@Environment(\.colorScheme)` only works in `View` types directly,
/// so `DynamicColor.body` uses this to pipe the environment in.
private struct EnvironmentReader<Content: View>: View {
    @Environment(\.self) private var env
    let content: (EnvironmentValues) -> Content

    var body: some View {
        content(env)
    }
}

#if canImport(UIKit)
private extension UIColor {
    static func fromHex(_ hex: UInt32) -> UIColor {
        UIColor(
            red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:  CGFloat(hex & 0xFF)         / 255.0,
            alpha: 1.0
        )
    }
}
#endif
