import Foundation
import Testing
@testable import VoiceFlowKit
@testable import VoiceFlow

@Suite
struct SignalQualityTests {

    // MARK: - RMS helper

    @Test func rmsLevelOfSilenceIsNearZero() {
        let silence = Data(count: 8192)  // all zeros
        let rms = VoiceFlowAudioMetering.rmsLevel(fromPCM16LE: silence)
        #expect(rms == 0)
    }

    @Test func rmsLevelOfLoudToneExceedsSilenceFloor() {
        var samples = [Int16]()
        for i in 0..<4096 {
            let sample = Int16(10000.0 * sin(Double(i) * 0.1))
            samples.append(sample)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let rms = VoiceFlowAudioMetering.rmsLevel(fromPCM16LE: data)
        #expect(rms > AppState.silenceFloor)
        #expect(rms > AppState.speechThreshold)
    }

    @Test func rmsLevelOfQuietToneBelowSpeechThreshold() {
        // Very quiet tone — should be above silence floor but below speech threshold
        var samples = [Int16]()
        for i in 0..<4096 {
            let sample = Int16(200.0 * sin(Double(i) * 0.1))
            samples.append(sample)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let rms = VoiceFlowAudioMetering.rmsLevel(fromPCM16LE: data)
        // 200/32768 ≈ 0.006 RMS for a sine — above silenceFloor, below speechThreshold(0.008)
        #expect(rms > AppState.silenceFloor)
        #expect(rms < AppState.speechThreshold)
    }

    // MARK: - Tier evaluation

    @MainActor
    @Test func tier1WhenNoSpeechDetected() async {
        let state = AppState()
        state.peakRms = 0.005  // noise floor may exceed silenceFloor
        state.activeAudioMs = 0  // but no frames crossed speech threshold
        let tier = state.evaluateSignalTier()
        #expect(tier == .tier1NoSignal)
    }

    @MainActor
    @Test func tier1WithSmallNoiseButNoSpeech() async {
        let state = AppState()
        state.peakRms = 0.01  // noise floor above silenceFloor
        state.activeAudioMs = 50  // tiny amount, below 100ms threshold
        let tier = state.evaluateSignalTier()
        #expect(tier == .tier1NoSignal)
    }

    @MainActor
    @Test func tier2WhenPeakRmsAboveFloorButActiveAudioShort() async {
        let state = AppState()
        state.peakRms = 0.01
        state.activeAudioMs = 500  // above 100ms (not tier1) but below 1500ms cutoff
        let tier = state.evaluateSignalTier()
        #expect(tier == .tier2ShortAudio)
    }

    @MainActor
    @Test func tier3WhenActiveAudioExceedsCutoff() async {
        let state = AppState()
        state.peakRms = 0.05
        state.activeAudioMs = 2000  // above 1500ms cutoff
        let tier = state.evaluateSignalTier()
        #expect(tier == .tier3Normal)
    }

    @MainActor
    @Test func tier2BoundaryExactlyAtCutoff() async {
        let state = AppState()
        state.peakRms = 0.01
        state.activeAudioMs = AppState.activeAudioShortMs  // exactly 1500
        let tier = state.evaluateSignalTier()
        #expect(tier == .tier3Normal)
    }

    @MainActor
    @Test func showTranscriptWarningOnlyForTier2WhenReady() async {
        let state = AppState()
        // Tier 2 + ready -> warning shows
        state.signalTier = .tier2ShortAudio
        state.recordingStatus = .ready
        #expect(state.showTranscriptWarning == true)

        // Tier 2 + recording -> warning does not show
        state.recordingStatus = .recording
        #expect(state.showTranscriptWarning == false)

        // Tier 3 + ready -> no warning
        state.signalTier = .tier3Normal
        state.recordingStatus = .ready
        #expect(state.showTranscriptWarning == false)
    }
}