import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Pixel-grid tab-bar glyphs for the Pixelate language. SwiftUI's `tabItem`
/// renders through UIKit's `UITabBarItem`, which needs a concrete `UIImage`
/// (a SwiftUI `Canvas` / `Shape` placed in a `tabItem` is silently dropped or
/// rendered inconsistently). So we rasterize each glyph from a small boolean
/// grid into a template `UIImage`; the tab bar then tints it amber when
/// selected and gray when not, exactly like an SF Symbol — preserving all
/// existing selection / accessibility behavior.
///
/// On platforms without UIKit (none currently ship a tab bar here, but keep the
/// build green) the helpers fall back to SF Symbols.
enum PixelTabIcon {
    /// 7×7 microphone glyph (mic capsule + stand + base). Pattern is shared
    /// verbatim with Android's `PixelTabIcon.MIC_GRID` so both platforms read
    /// as the same hand-placed pixels: a 3-wide capsule head, stand arms, and
    /// a base row.
    static let micGrid: [[Int]] = [
        [0, 0, 1, 1, 1, 0, 0],
        [0, 0, 1, 1, 1, 0, 0],
        [0, 0, 1, 1, 1, 0, 0],
        [0, 0, 1, 1, 1, 0, 0],
        [1, 0, 0, 1, 0, 0, 1],
        [0, 1, 0, 1, 0, 1, 0],
        [0, 0, 1, 1, 1, 0, 0],
    ]

    /// 7×7 gear glyph (ring of teeth around a hollow hub). Shared verbatim with
    /// Android's `PixelTabIcon.GEAR_GRID`.
    static let gearGrid: [[Int]] = [
        [0, 0, 1, 0, 1, 0, 0],
        [0, 1, 1, 1, 1, 1, 0],
        [1, 1, 0, 0, 0, 1, 1],
        [0, 1, 0, 0, 0, 1, 0],
        [1, 1, 0, 0, 0, 1, 1],
        [0, 1, 1, 1, 1, 1, 0],
        [0, 0, 1, 0, 1, 0, 0],
    ]

    #if canImport(UIKit)
    static let mic: UIImage? = rasterize(micGrid)
    static let gear: UIImage? = rasterize(gearGrid)

    /// Renders a boolean grid into a template `UIImage` of `pointSize` square,
    /// drawing each "on" cell as a hard-edged block with a 1px gutter so the
    /// pixels read as discrete squares rather than a smeared blob.
    private static func rasterize(_ grid: [[Int]], pointSize: CGFloat = 26) -> UIImage? {
        let rows = grid.count
        let cols = grid.first?.count ?? 0
        guard rows > 0, cols > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pointSize, height: pointSize),
            format: format
        )

        let cellW = pointSize / CGFloat(cols)
        let cellH = pointSize / CGFloat(rows)
        let gutter: CGFloat = 0.8

        let image = renderer.image { ctx in
            UIColor.black.setFill()
            for r in 0..<rows {
                for c in 0..<cols where grid[r][c] == 1 {
                    let rect = CGRect(
                        x: CGFloat(c) * cellW + gutter,
                        y: CGFloat(r) * cellH + gutter,
                        width: cellW - gutter * 2,
                        height: cellH - gutter * 2
                    )
                    ctx.fill(rect)
                }
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
    #endif
}

extension Image {
    /// Pixel tab glyph by name, falling back to the matching SF Symbol if the
    /// rasterized image is unavailable for any reason.
    static func pixelTab(_ kind: PixelTabKind) -> Image {
        #if canImport(UIKit)
        switch kind {
        case .mic:
            if let img = PixelTabIcon.mic { return Image(uiImage: img) }
            return Image(systemName: "mic")
        case .gear:
            if let img = PixelTabIcon.gear { return Image(uiImage: img) }
            return Image(systemName: "gearshape")
        }
        #else
        switch kind {
        case .mic:  return Image(systemName: "mic")
        case .gear: return Image(systemName: "gearshape")
        }
        #endif
    }
}

enum PixelTabKind {
    case mic
    case gear
}

// MARK: - In-button pixel glyphs

/// The pixel icon shown inside `CapsuleButton`'s leading slot. Replaces the
/// smooth SF Symbols (`mic.fill` / `stop.fill`) that read as out-of-language
/// "emoji" next to the Silkscreen pixel label. Both cases are drawn from the
/// same boolean-grid + hard-block rasterizer as the tab glyphs, tinted by the
/// button's foreground color (black on the amber primary).
enum PixelButtonGlyph {
    /// The mic reuses the exact 7×7 grid the tab bar uses, so the icon a user
    /// taps to record matches the tab they tapped to get here.
    case mic
    /// Stop is a single solid pixel block — the loudest possible "stop" cue in
    /// the pixel language.
    case stop
}

/// Renders a `PixelButtonGlyph` as a small grid of hard-edged squares with a
/// 1px gutter, mirroring `PixelTabIcon.rasterize`. Sized for the ~16–18pt icon
/// slot inside `CapsuleButton`.
struct PixelGlyphView: View {
    let glyph: PixelButtonGlyph
    var size: CGFloat = 17

    var body: some View {
        Canvas { context, canvasSize in
            switch glyph {
            case .mic:
                drawGrid(PixelTabIcon.micGrid, in: context, size: canvasSize)
            case .stop:
                // 3×3 solid block — a chunky, unmistakable square.
                drawGrid(
                    [[1, 1, 1], [1, 1, 1], [1, 1, 1]],
                    in: context,
                    size: canvasSize
                )
            }
        }
        .frame(width: size, height: size)
    }

    private func drawGrid(_ grid: [[Int]], in context: GraphicsContext, size: CGSize) {
        let rows = grid.count
        let cols = grid.first?.count ?? 0
        guard rows > 0, cols > 0 else { return }
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)
        let gutter: CGFloat = 0.6
        for r in 0..<rows {
            for c in 0..<cols where grid[r][c] == 1 {
                let rect = CGRect(
                    x: CGFloat(c) * cellW + gutter,
                    y: CGFloat(r) * cellH + gutter,
                    width: cellW - gutter * 2,
                    height: cellH - gutter * 2
                )
                // Tint comes from the surrounding `foregroundStyle`.
                context.fill(Path(rect), with: .foreground)
            }
        }
    }
}
