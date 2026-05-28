import Foundation
import Testing
@testable import VoiceFlowKit

/// Regression coverage for the bulk-transcribe race that surfaced in
/// VoiceFlow [PR #34](https://github.com/grapeot/voiceflow/pull/34).
///
/// The four tests below were originally written for the Xcode test
/// target but swift-testing refused to discover them in that context
/// (see PR #34 commit message). They now live in the SPM-driven
/// `VoiceFlowKitTests` target where discovery works, which is one of
/// the unexpected nice things that fell out of the library extraction.
@Suite("BulkTranscriptionProgress race")
struct BulkProgressRegressionTests {
    /// Once `.status(.idle)` finishes the call, the trailing
    /// `.disconnected` from the server closing the socket is normal
    /// wind-down — must not be reported as failure.
    @Test func ignoresDisconnectAfterIdle() async {
        let progress = BulkTranscriptionProgress()
        await progress.handle(.textDelta(content: "hello world", isNewResponse: true), onPartialTranscript: nil)
        await progress.handle(.status(.idle), onPartialTranscript: nil)
        await progress.handle(.disconnected, onPartialTranscript: nil)

        let isFinished = await progress.isFinished
        let receivedError = await progress.receivedError
        let transcript = await progress.transcript

        #expect(isFinished)
        #expect(receivedError == nil)
        #expect(transcript == "hello world")
    }

    /// Same idea for the rarer case of a late `.error` arriving after
    /// `.status(.idle)`. The call result is already settled.
    @Test func ignoresErrorAfterIdle() async {
        let progress = BulkTranscriptionProgress()
        await progress.handle(.textDelta(content: "hello", isNewResponse: true), onPartialTranscript: nil)
        await progress.handle(.status(.idle), onPartialTranscript: nil)
        await progress.handle(.error(message: "late server error"), onPartialTranscript: nil)

        let receivedError = await progress.receivedError
        let transcript = await progress.transcript

        #expect(receivedError == nil)
        #expect(transcript == "hello")
    }

    /// Disconnect *before* idle is still a real failure and must surface.
    @Test func recordsDisconnectBeforeIdle() async {
        let progress = BulkTranscriptionProgress()
        await progress.handle(.textDelta(content: "partial", isNewResponse: true), onPartialTranscript: nil)
        await progress.handle(.disconnected, onPartialTranscript: nil)

        let isFinished = await progress.isFinished
        let receivedError = await progress.receivedError

        #expect(isFinished)
        #expect(receivedError == "WebSocket disconnected")
    }

    /// Error mid-stream still flips the error state — only post-idle
    /// noise is suppressed.
    @Test func recordsErrorBeforeIdle() async {
        let progress = BulkTranscriptionProgress()
        await progress.handle(.error(message: "boom"), onPartialTranscript: nil)

        let isFinished = await progress.isFinished
        let receivedError = await progress.receivedError

        #expect(isFinished)
        #expect(receivedError == "boom")
    }
}
