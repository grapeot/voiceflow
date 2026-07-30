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

    @Test func connectionTestUsesUsageSummaryEndpoint() throws {
        let request = try AIBuilderClient.makeConnectionTestRequest(
            baseURL: "https://example.com/backend",
            token: "fake-token"
        )

        #expect(request.url?.absoluteString == "https://example.com/backend/v1/usage/summary")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)
    }
}
