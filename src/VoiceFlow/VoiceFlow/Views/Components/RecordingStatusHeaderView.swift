import SwiftUI

struct RecordingStatusHeaderView: View {
    let recordingStatus: AppState.RecordingStatus

    private var indicatorColor: Color {
        switch recordingStatus {
        case .recording:
            return .green
        case .requestingPermission, .transcribing:
            return .orange
        case .idle, .ready:
            return .blue
        }
    }

    var body: some View {
        HStack {
            Text("VoiceFlow")
                .font(.largeTitle)
                .fontWeight(.bold)
                .accessibilityIdentifier("record.statusTitle")

            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)
                .animation(.easeInOut, value: recordingStatus)
                .accessibilityIdentifier("record.statusIndicator")
                .accessibilityLabel(Text("Recording status"))
                .accessibilityValue(Text(recordingStatus.indicatorAccessibilityValue))
        }
        .accessibilityIdentifier("record.statusHeader")
    }
}
