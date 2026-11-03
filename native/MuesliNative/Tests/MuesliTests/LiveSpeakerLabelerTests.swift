import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("LiveSpeakerLabeler")
struct LiveSpeakerLabelerTests {
    private func labeler(slots: Int = 4, origin: TimeInterval = 0, retain: TimeInterval = 300) -> LiveSpeakerLabeler {
        LiveSpeakerLabeler(slotCount: slots, frameDuration: 0.1, originSeconds: origin, retainSeconds: retain)
    }

    @Test("no speech and no coverage both stay Others")
    func noSpeech() {
        var empty = labeler()
        #expect(empty.label(start: 0, end: 5) == "Others")

        var silent = labeler()
        silent.ingest(liveSpeakerFrames(slotRun(nil, frames: 50)))
        #expect(silent.label(start: 0, end: 5) == "Others")
    }

    @Test("one speaker is Speaker 1 whichever slot the model used")
    func oneSpeaker() {
        var sut = labeler()
        sut.ingest(liveSpeakerFrames(slotRun(3, frames: 100)))
        #expect(sut.label(start: 1, end: 6) == "Speaker 1")
    }

    @Test("speakers are numbered in the order they are first shown, not by slot")
    func numbersByFirstAppearance() {
        var sut = labeler()
        sut.ingest(liveSpeakerFrames(slotRun(2, frames: 20) + slotRun(0, frames: 20)))
        #expect(sut.label(start: 2, end: 4) == "Speaker 1")
        #expect(sut.label(start: 0, end: 2) == "Speaker 2")
    }

    @Test("an assigned number never changes when later audio arrives")
    func numberIsStable() {
        var sut = labeler()
        sut.ingest(liveSpeakerFrames(slotRun(1, frames: 20)))
        let first = sut.label(start: 0, end: 2)
        sut.ingest(liveSpeakerFrames(slotRun(3, frames: 20) + slotRun(1, frames: 20), startFrame: 20))
        #expect(sut.label(start: 2, end: 4) == "Speaker 2")
        #expect(sut.label(start: 0, end: 2) == first)
        #expect(sut.label(start: 4, end: 6) == first)
    }

    @Test("more real speakers than model slots never produce a number above the slot count")
    func moreSpeakersThanSlots() {
        var sut = labeler(slots: 4)
        let twelveSpeakers = (0..<12).flatMap { slotRun($0 % 4, frames: 10) }
        sut.ingest(liveSpeakerFrames(twelveSpeakers))
        let labels = Set((0..<12).map { sut.label(start: Double($0), end: Double($0) + 1) })
        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])
    }

    @Test("a block whose slot count does not match the model is ignored")
    func malformedBlock() {
        var sut = labeler(slots: 4)
        sut.ingest(liveSpeakerFrames(slotRun(1, frames: 10), slotCount: 4))
        sut.ingest(liveSpeakerFrames(slotRun(6, frames: 10), slotCount: 8, startFrame: 10))
        sut.ingest(LiveSpeakerFrames(startFrame: 10, slotCount: 4, probabilities: [0.9, 0.1, 0.1]))
        #expect(sut.coveredThrough == 1.0)
        #expect(sut.label(start: 0, end: 1) == "Speaker 1")
    }

    @Test("weak activity and one-frame blips do not earn a label")
    func thresholdsAndBlips() {
        var weak = labeler()
        weak.ingest(LiveSpeakerFrames(startFrame: 0, slotCount: 4, probabilities: [Float](repeating: 0.3, count: 200)))
        #expect(weak.label(start: 0, end: 5) == "Others")

        var blip = labeler()
        blip.ingest(liveSpeakerFrames(slotRun(nil, frames: 20) + [2] + slotRun(nil, frames: 29)))
        #expect(blip.label(start: 0, end: 5) == "Others")
    }

    @Test("the speaker with the most speech in the range wins; overlap goes to the louder slot")
    func dominantSpeaker() {
        var sut = labeler()
        sut.ingest(liveSpeakerFrames(slotRun(0, frames: 10) + slotRun(1, frames: 30)))
        // Slot 1 talks for 3 of the 4 seconds, so it is the first speaker shown.
        #expect(sut.label(start: 0, end: 4) == "Speaker 1")
        #expect(sut.label(start: 0, end: 1) == "Speaker 2")

        var overlap = labeler()
        let both = LiveSpeakerFrames(
            startFrame: 0, slotCount: 4,
            probabilities: (0..<20).flatMap { _ in [Float(0.6), 0.95, 0.05, 0.05] }
        )
        overlap.ingest(both)
        overlap.ingest(liveSpeakerFrames(slotRun(0, frames: 20), startFrame: 20))
        #expect(overlap.label(start: 0, end: 2) == "Speaker 1")
        #expect(overlap.label(start: 2, end: 4) == "Speaker 2")
        #expect(overlap.coveredThrough == 4.0)
    }

    @Test("diarizer time is shifted by the origin offset")
    func originOffset() {
        var sut = labeler(origin: 10)
        sut.ingest(liveSpeakerFrames(slotRun(2, frames: 20)))
        #expect(sut.coveredThrough == 12.0)
        #expect(sut.label(start: 10, end: 12) == "Speaker 1")
        #expect(sut.label(start: 0, end: 5) == "Others")
    }

    @Test("a gap is silence and replayed frames are not counted twice")
    func gapsAndReplays() {
        var sut = labeler()
        sut.ingest(liveSpeakerFrames(slotRun(0, frames: 10)))
        sut.ingest(liveSpeakerFrames(slotRun(1, frames: 10), startFrame: 20))
        #expect(sut.coveredThrough == 3.0)
        #expect(sut.label(start: 1, end: 2) == "Others")
        #expect(sut.label(start: 2, end: 3) == "Speaker 1")

        sut.ingest(liveSpeakerFrames(slotRun(3, frames: 10), startFrame: 25))
        #expect(sut.coveredThrough == 3.5)
    }

    @Test("history stays bounded over a ten hour meeting and recent ranges still resolve")
    func boundedHistory() {
        var sut = labeler(retain: 300)
        let tenMinutes = 6_000
        for block in 0..<60 {
            sut.ingest(liveSpeakerFrames(slotRun(block % 4, frames: tenMinutes), startFrame: block * tenMinutes))
        }
        #expect(sut.retainedFrameCount <= 2 * 3_000)
        #expect(sut.coveredThrough == 36_000)
        #expect(sut.label(start: 35_990, end: 35_995) != "Others")
        #expect(sut.label(start: 100, end: 105) == "Others")
    }
}
