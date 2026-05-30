import SwiftUI

/// The single visual anchor of the Record screen. Three modes:
///
/// - `idle`: a faint horizontal hairline, no motion.
/// - `active`: a scrolling history of recent mic levels — each bar is the
///   audio amplitude N×33ms ago. The newest sample enters on the right and
///   ages off the left.
/// - `generating`: a traveling pulse that sweeps left to right, used while
///   the backend is finalizing transcription (no mic signal available).
struct WaveformView: View {
    enum Mode {
        case idle
        case active
        case generating
    }

    var mode: Mode
    var color: Color
    /// 0…1 microphone level. Only read in `.active` mode; ignored otherwise.
    var level: Float = 0

    // Pixelate waveform: 15 chunky square blocks instead of 36 hairlines.
    // Wide, well-spaced, hard right angles (no corner radius) for the
    // OP-1 / Playdate "pixel as discipline" look.
    private let barCount = 15
    private let barWidth: CGFloat = 14
    private let barSpacing: CGFloat = 6

    // Each bar is rendered as a "pixel column": a stack of tiny squares with
    // visible gaps, so the chunky bar reads as something assembled from
    // individual pixels rather than one smooth rectangle.
    private let pixelCell: CGFloat = 5.5
    private let pixelGap: CGFloat = 1.8

    @State private var history: [Float] = Array(repeating: 0, count: 15)
    @State private var lastTick: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .idle)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centerY = size.height / 2
                let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
                let originX = (size.width - total) / 2

                let snapshot = currentBars(at: t)

                // How many pixel columns fit inside one bar's width, and the
                // x-offset to center them within the bar slot.
                let columnPitch = pixelCell + pixelGap
                let columnCount = max(1, Int((barWidth + pixelGap) / columnPitch))
                let columnsSpan = CGFloat(columnCount) * pixelCell
                    + CGFloat(columnCount - 1) * pixelGap
                let columnInset = (barWidth - columnsSpan) / 2

                let cellPitch = pixelCell + pixelGap

                for i in 0..<barCount {
                    let barX = originX + CGFloat(i) * (barWidth + barSpacing)
                    let height = snapshot[i] * (size.height - 4) + 2
                    // Half-height available above (and below) the center line.
                    let halfHeight = max(height, 1) / 2

                    // Number of pixel cells that fit in the half-height. At
                    // least one so even the flat idle row shows a single block.
                    let halfCells = max(1, Int((halfHeight + pixelGap) / cellPitch))

                    for col in 0..<columnCount {
                        let x = barX + columnInset + CGFloat(col) * columnPitch
                        for n in 0..<halfCells {
                            // Cell n sits just above the center line; its twin
                            // mirrors below — preserving the two-way symmetry.
                            let topY = centerY - CGFloat(n + 1) * cellPitch + pixelGap
                            let upper = CGRect(
                                x: x, y: topY,
                                width: pixelCell, height: pixelCell
                            )
                            let bottomY = centerY + CGFloat(n) * cellPitch
                                + (cellPitch - pixelCell)
                            let lower = CGRect(
                                x: x, y: bottomY,
                                width: pixelCell, height: pixelCell
                            )
                            // Hard square blocks with visible gaps so the bar
                            // reads as assembled from individual pixels.
                            context.fill(Path(upper), with: .color(color))
                            context.fill(Path(lower), with: .color(color))
                        }
                    }
                }
            }
            .accessibilityHidden(true)
            .onChange(of: timeline.date) {
                if mode == .active {
                    advanceHistory(at: t)
                } else if mode == .idle && history.contains(where: { $0 > 0.01 }) {
                    // Decay the bars when we leave .active so the visual
                    // collapses gracefully instead of snapping flat.
                    history = history.map { $0 * 0.6 }
                }
            }
        }
        .frame(height: DesignTokens.Sizing.waveformHeight)
        .opacity(mode == .idle ? 0.45 : 1.0)
    }

    /// Pushes the smoothed current `level` onto the right of `history`,
    /// drops the oldest sample. Throttled to ~30 Hz so 60 Hz redraws don't
    /// burn through samples faster than the mic delivers them.
    private func advanceHistory(at t: TimeInterval) {
        guard t - lastTick >= 1.0 / 30.0 else { return }
        lastTick = t
        // Subtle floor (~0.04) keeps the row visible during quiet pauses
        // mid-sentence rather than collapsing into a flat line and looking
        // like the mic died.
        let sample = max(Float(0.04), level)
        history.removeFirst()
        history.append(sample)
    }

    /// CGFloat heights (0…1) for the current frame.
    private func currentBars(at t: TimeInterval) -> [CGFloat] {
        switch mode {
        case .idle:
            // Static hairline; ignore history.
            return Array(repeating: 0.02, count: barCount)

        case .active:
            return history.map { CGFloat($0) }

        case .generating:
            // Traveling pulse — independent of mic level, indicates the
            // server is doing the work now.
            let speed = 12.0
            let position = (t * speed).truncatingRemainder(dividingBy: Double(barCount))
            return (0..<barCount).map { i in
                let distance = min(abs(Double(i) - position),
                                   Double(barCount) - abs(Double(i) - position))
                let intensity = max(0, 1 - distance / 3)
                return CGFloat(0.04 + intensity * 0.96)
            }
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        WaveformView(mode: .idle, color: DesignTokens.Palette.textSecondary.color(for: .light))
        WaveformView(mode: .active, color: DesignTokens.Palette.accent, level: 0.6)
        WaveformView(mode: .generating, color: DesignTokens.Palette.accent)
    }
    .padding()
    .background(DesignTokens.Palette.bgPrimary)
}
