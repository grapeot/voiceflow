import Testing
@testable import VoiceFlowKit

@Suite("VoiceFlowKit module")
struct VoiceFlowKitSanityTests {
    @Test func moduleExposesVersion() {
        #expect(!VoiceFlowKit.version.isEmpty)
    }
}
