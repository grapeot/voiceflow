import SwiftUI

struct RecordingTimerView: View {
    let timeString: String

    var body: some View {
        Text(timeString)
            .font(.title)
            .padding()
            .accessibilityIdentifier("record.recordingTimer")
            .accessibilityValue(timeString)
    }
}
