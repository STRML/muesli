import Foundation

/// Per-frame speaker activity from a streaming diarizer. `probabilities` is
/// row-major `[frameCount x slotCount]`; `startFrame` indexes the first row on
/// the diarizer's own clock.
struct LiveSpeakerFrames: Sendable, Equatable {
    let startFrame: Int
    let slotCount: Int
    let probabilities: [Float]
}

/// Outcome of resolving a time range against the diarizer's retained frames.
enum LiveSpeakerResolution: Equatable, Sendable {
    case speaker(String)
    /// The diarizer covered the entire range and detected no active voice.
    case silent
    /// The diarizer has not covered (or no longer retains) the range.
    case uncovered
}

/// Turns diarizer frames into provisional "Speaker N" labels for time ranges.
///
/// Pure state, no I/O. Numbers are handed out the first time a slot is shown, so
/// the first speaker on screen is always "Speaker 1" and a number never changes
/// afterwards. A slot the model later folds into another one simply stops
/// appearing; lines already shown keep their label. History is stored as
/// compressed `(startFrame, endFrame, slot)` runs so full-meeting history stays
/// tiny; finite `retainSeconds` optionally bounds history to a rolling window.
struct LiveSpeakerLabeler: Sendable {
    static let fallbackLabel = "Others"
    private static let activityThreshold: Float = 0.5
    private static let minimumActiveFrames = 2
    private static let silence: Int8 = -1

    private struct SlotRun: Sendable, Equatable {
        var startFrame: Int
        var endFrame: Int // exclusive
        let slot: Int8
    }

    private let slotCount: Int
    private let frameDuration: TimeInterval
    private let originSeconds: TimeInterval
    private let retainFrames: Int?
    private var baseFrame = 0
    private var endFrame = 0
    /// Compressed runs of loudest active slot (or `silence`) covering `[baseFrame, endFrame)`.
    private var runs: [SlotRun] = []
    private var displayNumbers: [Int: Int] = [:]

    init(
        slotCount: Int,
        frameDuration: TimeInterval,
        originSeconds: TimeInterval = 0,
        retainSeconds: TimeInterval = 300
    ) {
        self.slotCount = max(slotCount, 1)
        self.frameDuration = frameDuration
        self.originSeconds = originSeconds
        if retainSeconds.isFinite, retainSeconds > 0 {
            self.retainFrames = max(Int(retainSeconds / frameDuration), 1)
        } else {
            self.retainFrames = nil
        }
    }

    private var nextFrame: Int { endFrame }

    /// End of the audio the diarizer has reported on, on the caller's clock.
    var coveredThrough: TimeInterval { originSeconds + Double(nextFrame) * frameDuration }

    var retainedFrameCount: Int { nextFrame - baseFrame }

    var speakerCount: Int { displayNumbers.count }

    var compressedRunCount: Int { runs.count }

    mutating func ingest(_ frames: LiveSpeakerFrames) {
        guard frames.slotCount == slotCount,
              frames.probabilities.count.isMultiple(of: slotCount) else { return }
        let frameCount = frames.probabilities.count / slotCount
        let replayed = max(nextFrame - frames.startFrame, 0)
        guard replayed < frameCount else { return }
        padGap(before: frames.startFrame)
        for row in replayed..<frameCount {
            let slot = loudestActiveSlot(in: frames.probabilities, row: row)
            appendRun(slot: slot, startFrame: endFrame, endFrame: endFrame + 1)
            endFrame += 1
        }
        trimHistory()
    }

    mutating func labelResolution(start: TimeInterval, end: TimeInterval) -> LiveSpeakerResolution {
        let tolerance = frameDuration * 1e-6
        guard coveredThrough > start + tolerance else { return .uncovered }
        if let slot = dominantSlot(start: start, end: end) {
            return .speaker("Speaker \(displayNumber(for: slot))")
        }
        let retainedStart = originSeconds + Double(baseFrame) * frameDuration
        let isFullyCovered = start + tolerance >= retainedStart && coveredThrough + tolerance >= end
        return isFullyCovered ? .silent : .uncovered
    }

    mutating func label(start: TimeInterval, end: TimeInterval) -> String {
        switch labelResolution(start: start, end: end) {
        case .speaker(let label):
            return label
        case .silent, .uncovered:
            return Self.fallbackLabel
        }
    }

    private mutating func padGap(before startFrame: Int) {
        let gap = startFrame - nextFrame
        guard gap > 0 else { return }
        if let retainFrames, gap >= retainFrames {
            runs.removeAll()
            baseFrame = startFrame
            endFrame = startFrame
        } else {
            appendRun(slot: Self.silence, startFrame: nextFrame, endFrame: startFrame)
            endFrame = startFrame
        }
    }

    private mutating func appendRun(slot: Int8, startFrame: Int, endFrame: Int) {
        guard endFrame > startFrame else { return }
        if let lastIndex = runs.indices.last,
           runs[lastIndex].slot == slot,
           runs[lastIndex].endFrame == startFrame {
            runs[lastIndex].endFrame = endFrame
        } else {
            runs.append(SlotRun(startFrame: startFrame, endFrame: endFrame, slot: slot))
        }
    }

    private func loudestActiveSlot(in probabilities: [Float], row: Int) -> Int8 {
        var best = Self.silence
        var bestProbability = Self.activityThreshold
        for slot in 0..<slotCount {
            let probability = probabilities[row * slotCount + slot]
            if probability >= bestProbability {
                best = Int8(slot)
                bestProbability = probability
            }
        }
        return best
    }

    private mutating func trimHistory() {
        guard let retainFrames, (nextFrame - baseFrame) > retainFrames * 2 else { return }
        let newBase = nextFrame - retainFrames
        baseFrame = newBase
        var firstSurviving = 0
        while firstSurviving < runs.count, runs[firstSurviving].endFrame <= newBase {
            firstSurviving += 1
        }
        if firstSurviving > 0 {
            runs.removeFirst(firstSurviving)
        }
        if !runs.isEmpty, runs[0].startFrame < newBase {
            runs[0].startFrame = newBase
        }
    }

    private func dominantSlot(start: TimeInterval, end: TimeInterval) -> Int? {
        let rawFirst = Int(((start - originSeconds) / frameDuration).rounded(.down))
        let rawLast = Int(((end - originSeconds) / frameDuration).rounded(.up))
        let first = max(rawFirst, baseFrame)
        let last = min(rawLast, nextFrame)
        guard first < last else { return nil }
        var counts = [Int](repeating: 0, count: slotCount)

        var lo = 0
        var hi = runs.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if runs[mid].endFrame <= first {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var index = lo
        while index < runs.count, runs[index].startFrame < last {
            let run = runs[index]
            if run.slot >= 0 {
                let overlapStart = max(first, run.startFrame)
                let overlapEnd = min(last, run.endFrame)
                if overlapEnd > overlapStart {
                    counts[Int(run.slot)] += overlapEnd - overlapStart
                }
            }
            index += 1
        }

        let best = counts.indices.min { lhs, rhs in
            if counts[lhs] != counts[rhs] { return counts[lhs] > counts[rhs] }
            let (lhsNumber, rhsNumber) = (displayNumbers[lhs] ?? .max, displayNumbers[rhs] ?? .max)
            return lhsNumber != rhsNumber ? lhsNumber < rhsNumber : lhs < rhs
        }
        let requiredFrames = min(Self.minimumActiveFrames, max(rawLast - rawFirst, 1))
        guard let best, counts[best] >= requiredFrames else { return nil }
        return best
    }

    private mutating func displayNumber(for slot: Int) -> Int {
        if let number = displayNumbers[slot] { return number }
        let number = displayNumbers.count + 1
        displayNumbers[slot] = number
        return number
    }
}
