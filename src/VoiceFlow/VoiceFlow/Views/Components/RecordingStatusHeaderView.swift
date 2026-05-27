import SwiftUI

struct RecordingStatusHeaderView: View {
    let recordingStatus: AppState.RecordingStatus
    let streamConnectionPhase: RealtimeConnectionPhase

    private var indicatorColor: Color {
        switch recordingStatus {
        case .recording:
            switch streamConnectionPhase {
            case .connected:
                return .green
            case .recovering, .connecting, .generating:
                return .orange
            case .disconnected:
                return .red
            }
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
                .animation(.easeInOut, value: streamConnectionPhase)
                .accessibilityElement()
                .accessibilityIdentifier("record.statusIndicator")
                .accessibilityLabel("Recording status")
                .accessibilityValue(accessibilityStatusValue)
        }
        .accessibilityIdentifier("record.statusHeader")
    }

    private var accessibilityStatusValue: String {
        if recordingStatus == .recording {
            return "recording-\(streamConnectionPhase)"
        }
        return recordingStatus.indicatorAccessibilityValue
    }
}
