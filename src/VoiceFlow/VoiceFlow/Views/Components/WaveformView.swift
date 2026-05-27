import SwiftUI

/// The single visual anchor of the Record screen. Renders a horizontal row of
/// thin bars whose heights breathe while the user is recording, and collapse
/// into a flat hairline when idle.
///
/// V0 uses a synthesized animation rather than live mic levels — AppState
/// doesn't surface an audio-level signal yet. The component is purely
/// presentational; replace `level` with a real metering value when
/// AudioRecorder learns to report it.
struct WaveformView: View {
    enum Mode {
        case idle
        case active
        case generating
    }

    var mode: Mode
    var color: Color

    private let barCount = 36
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: mode == .idle)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centerY = size.height / 2
                let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
                let originX = (size.width - total) / 2

                for i in 0..<barCount {
                    let x = originX + CGFloat(i) * (barWidth + barSpacing)
                    let height = barHeight(for: i, at: t, canvasHeight: size.height)
                    let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: max(height, 1))
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(color))
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: DesignTokens.Sizing.waveformHeight)
        .opacity(mode == .idle ? 0.45 : 1.0)
    }

    private func barHeight(for index: Int, at t: TimeInterval, canvasHeight: CGFloat) -> CGFloat {
        switch mode {
        case .idle:
            return 2

        case .active:
            // Two superimposed sine waves at different frequencies for a more
            // organic look than a single oscillator would give.
            let i = Double(index)
            let s1 = sin(t * 4.0 + i * 0.35)
            let s2 = sin(t * 1.6 + i * 0.18)
            let envelope = sin(t * 2.4 + i * 0.12) * 0.5 + 0.5
            let amplitude = (s1 * 0.6 + s2 * 0.4) * envelope
            let normalized = abs(amplitude)
            return CGFloat(2 + normalized * Double(canvasHeight - 4))

        case .generating:
            // A traveling pulse: a narrow window of bars at high amplitude
            // sweeps left-to-right, the rest stay near baseline.
            let i = Double(index)
            let speed = 12.0
            let position = (t * speed).truncatingRemainder(dividingBy: Double(barCount))
            let distance = min(abs(i - position), Double(barCount) - abs(i - position))
            let intensity = max(0, 1 - distance / 3)
            return CGFloat(2 + intensity * Double(canvasHeight - 4))
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        WaveformView(mode: .idle, color: DesignTokens.Palette.textSecondary)
        WaveformView(mode: .active, color: DesignTokens.Palette.accent)
        WaveformView(mode: .generating, color: DesignTokens.Palette.accent)
    }
    .padding()
    .background(DesignTokens.Palette.bgPrimary)
}
