//
//  VoiceFlowTests.swift
//  VoiceFlowTests
//
//  Created by Yan Wang on 5/26/26.
//

import Testing
@testable import VoiceFlow

@MainActor
struct VoiceFlowTests {

    @Test func appStateStartsAsPureVoiceInput() async throws {
        let state = AppState()

        #expect(state.recordingStatus == .idle)
        #expect(state.transcript.isEmpty)
        #expect(state.hasSavedAIBuilderToken == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.canCopyTranscript == false)
        #expect(state.canSendToOpenCode == false)
        #expect(state.aiBuilderEndpoint == "https://space.ai-builders.com/backend")
    }

    @Test func openCodeRequiresConfigurationAndTranscript() async throws {
        let state = AppState()

        state.transcript = "hello"
        #expect(state.canCopyTranscript == true)
        #expect(state.canSendToOpenCode == false)

        state.isOpenCodeConfigured = true
        #expect(state.canSendToOpenCode == true)
    }

}
