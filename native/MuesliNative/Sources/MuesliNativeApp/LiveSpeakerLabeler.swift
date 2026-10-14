import Foundation

/// Per-frame speaker activity from a streaming diarizer. `probabilities` is
/// row-major `[frameCount x slotCount]`; `startFrame` indexes the first row on
/// the diarizer's own clock.
struct LiveSpeakerFrames: Sendable, Equatable {
    let startFrame: Int
    let slotCount: Int
    let probabilities: [Float]
}

struct LiveSpeakerLabeler: Sendable {
    static let fallbackLabel = "Others"

    init(
        slotCount: Int,
        frameDuration: TimeInterval,
        originSeconds: TimeInterval = 0,
        retainSeconds: TimeInterval = 300
    ) {}

    var coveredThrough: TimeInterval { 0 }
    var retainedFrameCount: Int { 0 }

    mutating func ingest(_ frames: LiveSpeakerFrames) {}

    mutating func label(start: TimeInterval, end: TimeInterval) -> String {
        "Speaker 99"
    }
}
