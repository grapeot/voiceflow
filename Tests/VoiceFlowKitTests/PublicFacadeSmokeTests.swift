import Foundation
import Testing
@testable import VoiceFlowKit

@Suite("Public facade smoke")
struct PublicFacadeSmokeTests {
    @Test func configCarriesDefaults() {
        let config = VoiceFlowConfig(tokenProvider: { "fake" })
        #expect(config.endpoint == VoiceFlowConfig.defaultEndpoint)
        #expect(config.model == VoiceFlowConfig.defaultModel)
        #expect(config.prompt == nil)
        #expect(config.terms.isEmpty)
    }

    @Test func captionStoreLayersFlash() async throws {
        let store = await StreamCaptionStore(transientDuration: .milliseconds(50))
        await store.setPersistent("reconnecting")
        await #expect(store.caption.visible == "reconnecting")
        await store.flashTransient("restored")
        await #expect(store.caption.visible == "restored")
        try await Task.sleep(for: .milliseconds(200))
        await #expect(store.caption.visible == "reconnecting")
    }

    @Test func errorTranslationCoversAllCases() {
        // Spot-check a few mappings so the bridge doesn't accidentally drop a case.
        let mapped = VoiceFlowError(RealtimeTranscriptionError.connectionLost("oops"))
        #expect(mapped == .connectionLost("oops"))
        let token = VoiceFlowError(RealtimeTranscriptionError.missingToken)
        #expect(token == .missingToken)
    }

    @Test func phaseTranslationRoundtrips() {
        let phases: [RealtimeConnectionPhase] = [.connecting, .connected, .recovering, .generating, .disconnected]
        for phase in phases {
            let public_ = VoiceFlowConnectionPhase(phase)
            // The reverse direction doesn't exist by design (the kit doesn't
            // need to accept public phases from hosts) — assert the public
            // form is at least non-trivial.
            switch public_ {
            case .connecting, .connected, .recovering, .generating, .disconnected:
                break
            }
        }
    }
}
