import Testing
@testable import VoiceFlowKit

@Suite("VoiceFlowKit module")
struct VoiceFlowKitSanityTests {
    @Test func moduleExposesVersion() {
        #expect(!VoiceFlowKit.version.isEmpty)
    }

    @Test func connectionErrorsExplainHTTPStatus() {
        #expect(AIBuilderClientError.requestFailed(statusCode: 401).localizedDescription.contains("401"))
        #expect(AIBuilderClientError.requestFailed(statusCode: 403).localizedDescription.contains("403"))
        #expect(AIBuilderClientError.requestFailed(statusCode: 429).localizedDescription.contains("429"))
        #expect(AIBuilderClientError.requestFailed(statusCode: 503).localizedDescription.contains("503"))
    }
}
