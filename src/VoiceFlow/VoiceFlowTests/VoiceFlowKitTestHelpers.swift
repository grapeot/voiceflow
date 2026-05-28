import Foundation
@testable import VoiceFlowKit

/// Build a `VoiceFlowClient` backed by a `MockRealtimeTranscriptionClient`
/// for AppState-level tests. The mock is returned alongside the client so
/// tests can script events (`emitLiveEvent`), inspect captured contexts
/// (`lastLiveContext`), and override bulk results mid-test
/// (`setBulkResult`). Token is hard-coded — AppState reads it from the
/// `tokenProvider` closure on every call but tests don't observe its value.
@MainActor
func makeStubVoiceFlowClient(
    liveResult: Result<String, Error> = .success("voice text"),
    bulkResult: Result<String, Error>? = nil
) -> (VoiceFlowClient, MockRealtimeTranscriptionClient) {
    let mock = MockRealtimeTranscriptionClient(
        liveResult: liveResult,
        bulkResult: bulkResult ?? liveResult
    )
    let config = VoiceFlowConfig(
        endpoint: VoiceFlowConfig.defaultEndpoint,
        tokenProvider: { "test-token" }
    )
    return (VoiceFlowClient(config: config, transcriber: mock), mock)
}
