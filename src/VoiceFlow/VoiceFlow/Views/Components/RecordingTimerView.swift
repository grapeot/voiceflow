import SwiftUI

struct RecordingTimerView: View {
    let timeString: String

    var body: some View {
        Text(timeString)
            .font(.title)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .accessibilityIdentifier("record.recordingTimer")
            .accessibilityValue(timeString)
    }
}
