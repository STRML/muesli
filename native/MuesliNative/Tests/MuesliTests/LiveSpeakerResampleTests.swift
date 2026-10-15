import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

/// FluidAudio resamples each call independently and rounds odd lengths up, so the
/// labeler's clock only stays exact if the engine is fed whole 100 ms blocks.
/// This pins that assumption without needing the model.
@Suite("LiveSpeakerResample")
struct LiveSpeakerResampleTests {
    @Test("whole 100 ms blocks resample to exactly half the samples, call after call")
    func wholeBlocksDoNotDrift() throws {
        let converter = AudioConverter(sampleRate: 8_000)
        var output = 0
        let blocks = 600
        for block in 0..<blocks {
            let samples = (0..<LiveSpeakerLabelSession.blockSamples).map {
                Float(sin(Double(block * LiveSpeakerLabelSession.blockSamples + $0) * 0.05)) * 0.3
            }
            output += try converter.resample(samples, from: Double(LiveSpeakerLabelSession.sampleRate)).count
        }
        #expect(output == blocks * LiveSpeakerLabelSession.blockSamples / 2)
    }
}
