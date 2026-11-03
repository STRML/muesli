import Foundation
import Testing
@testable import MuesliNativeApp

/// Runs only on a machine that already has the LS-EEND model cached (turn on
/// "Live speaker labels" in Settings once). It checks the FluidAudio adapter, not
/// diarization quality, and never downloads anything.
@Suite("Live speaker labels with the real model")
struct LiveSpeakerRealModelSmokeTests {
    @Test(
        "the cached model loads and keeps pace with the audio it is fed",
        .enabled(if: LiveSpeakerModelStore.isDownloaded())
    )
    func realEngineProducesContiguousFrames() async throws {
        let engine = try await LiveSpeakerModelStore.loadEngine()
        #expect(engine.slotCount > 0)
        #expect(engine.frameDuration > 0)

        var nextFrame = 0
        let block = [Float](repeating: 0, count: LiveSpeakerLabelSession.blockSamples)
        for _ in 0..<600 {
            if let frames = try engine.process(samples: block) {
                #expect(frames.slotCount == engine.slotCount)
                #expect(frames.startFrame == nextFrame)
                nextFrame += frames.probabilities.count / frames.slotCount
            }
        }
        if let tail = try engine.finish() {
            #expect(tail.startFrame == nextFrame)
            nextFrame += tail.probabilities.count / tail.slotCount
        }
        // 60 s in; the clock must not drift against the audio it was fed.
        #expect(abs(Double(nextFrame) * engine.frameDuration - 60) < 0.3)
    }
}
