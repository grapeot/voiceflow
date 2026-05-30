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

    /// Pixel ("Silkscreen") type — the OP-1 / Playdate "pixel as discipline"
    /// voice. Applied ONLY to Latin glyph contexts: the numeric timer, English
    /// status captions, and English button labels (STOP / Record). Silkscreen
    /// has no CJK coverage, so any Chinese string must keep `Typography.*`;
    /// SwiftUI silently falls back to the system font for missing glyphs, but we
    /// avoid leaning on that and gate pixel fonts behind a language check at the
    /// call site instead.
    ///
    /// PostScript family name registered via `UIAppFonts` is "Silkscreen" with
    /// styles "Regular" / "Bold". `Font.custom("Silkscreen", ...)` resolves the
    /// regular face; the bold face is reached with `.bold()` or by naming
    /// "Silkscreen-Bold" explicitly. Silkscreen is a fixed bitmap-style face, so
    /// sizes are chosen smaller than their system counterparts to stay legible.
    enum PixelType {
        /// Regular Silkscreen face name; use when an explicit name is needed.
        static let familyRegular = "Silkscreen-Regular"
        static let familyBold    = "Silkscreen-Bold"

        /// Big numeric timer (e.g. "00:42"). Pixel digits are the headline of
        /// the Pixelate look; smaller than the 56pt system timer because the
        /// bitmap face reads larger at equal point size.
        static let timer   = Font.custom(familyRegular, size: 44)
        /// English status captions ("Listening", "Generating").
        static let caption = Font.custom(familyRegular, size: 12)
        /// English button labels (STOP / Record). Bold face for weight parity
        /// with the system `buttonLabel`.
        static let button  = Font.custom(familyBold, size: 15)

        /// Returns the pixel font for `text` only when it is safe to render in
        /// Silkscreen (no CJK glyphs); otherwise returns the supplied system
        /// fallback. This keeps Chinese strings on the system face per the
        /// mixed-font rule, while English/numeric strings get the pixel look —
        /// and it works regardless of whether the user picked English, Chinese,
        /// or "system" language, because it inspects the resolved string.
        static func font(for text: String, pixel: Font, fallback: Font) -> Font {
            text.containsCJK ? fallback : pixel
        }
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

// MARK: - Script detection

extension String {
    /// True if the string contains any CJK ideograph (or common CJK
    /// punctuation/kana ranges). Used to decide whether a label can be rendered
    /// in the Latin-only Silkscreen pixel font or must fall back to the system
    /// font. Conservative on purpose: any CJK presence routes to the fallback.
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(v)   // CJK Extension A
                || (0x3040...0x30FF).contains(v)   // Hiragana + Katakana
                || (0x3000...0x303F).contains(v)   // CJK symbols & punctuation
                || (0xFF00...0xFFEF).contains(v)   // Fullwidth forms
                || (0xAC00...0xD7AF).contains(v)   // Hangul syllables
        }
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
/// On iOS / iPadOS this is wired up through a UIKit dynamic provider
/// (`Color(UIColor { traits in ... })`) so the system Dark / Light
/// preference flips colors automatically. On visionOS native targets
/// there is no Dark Mode to follow — visionOS uses glass materials that
/// adapt to ambient lighting instead of offering a Light/Dark toggle.
/// (Settings → Appearance on Vision Pro does show a Light / Dark
/// switch, but its subtitle is "Compatible Apps Appearance" — it only
/// affects iPad/iPhone compatibility-mode apps, not native visionOS
/// builds like this one.) `VoiceFlowApp` therefore pins the visionOS
/// window to `.preferredColorScheme(.light)`, and this struct's
/// `resolve(in:)` always picks the light variant on visionOS — which
/// is the right call against Vision Pro's default glass UI.
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
