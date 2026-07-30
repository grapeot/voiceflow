import Foundation
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

    @Test func connectionTestUsesProtectedVoiceEndpoint() throws {
        let request = try AIBuilderClient.makeConnectionTestRequest(
            baseURL: "https://example.com/backend",
            token: "fake-token"
        )

        #expect(request.url?.absoluteString == "https://example.com/backend/v1/audio/realtime/sessions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"vad":false}"#.utf8))
    }
}
