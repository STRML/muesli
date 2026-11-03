import Foundation

/// Per-frame speaker activity from a streaming diarizer. `probabilities` is
/// row-major `[frameCount x slotCount]`; `startFrame` indexes the first row on
/// the diarizer's own clock.
struct LiveSpeakerFrames: Sendable, Equatable {
    let startFrame: Int
    let slotCount: Int
    let probabilities: [Float]
}

/// Turns diarizer frames into provisional "Speaker N" labels for time ranges.
///
/// Pure state, no I/O. Numbers are handed out the first time a slot is shown, so
/// the first speaker on screen is always "Speaker 1" and a number never changes
/// afterwards. A slot the model later folds into another one simply stops
/// appearing; lines already shown keep their label. History is a rolling window,
/// so memory stays flat however long the meeting runs.
struct LiveSpeakerLabeler: Sendable {
    static let fallbackLabel = "Others"
    private static let activityThreshold: Float = 0.5
    private static let minimumActiveFrames = 2
    private static let silence: Int8 = -1

    private let slotCount: Int
    private let frameDuration: TimeInterval
    private let originSeconds: TimeInterval
    private let retainFrames: Int
    private var baseFrame = 0
    /// Loudest active slot per retained frame, or `silence`.
    private var activeSlots: [Int8] = []
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
        self.retainFrames = max(Int(retainSeconds / frameDuration), 1)
    }

    private var nextFrame: Int { baseFrame + activeSlots.count }

    /// End of the audio the diarizer has reported on, on the caller's clock.
    var coveredThrough: TimeInterval { originSeconds + Double(nextFrame) * frameDuration }

    var retainedFrameCount: Int { activeSlots.count }

    mutating func ingest(_ frames: LiveSpeakerFrames) {
        guard frames.slotCount == slotCount,
              frames.probabilities.count.isMultiple(of: slotCount) else { return }
        let frameCount = frames.probabilities.count / slotCount
        let replayed = max(nextFrame - frames.startFrame, 0)
        guard replayed < frameCount else { return }
        padGap(before: frames.startFrame)
        for row in replayed..<frameCount {
            activeSlots.append(loudestActiveSlot(in: frames.probabilities, row: row))
        }
        trimHistory()
    }

    mutating func label(start: TimeInterval, end: TimeInterval) -> String {
        guard let slot = dominantSlot(start: start, end: end) else { return Self.fallbackLabel }
        return "Speaker \(displayNumber(for: slot))"
    }

    private mutating func padGap(before startFrame: Int) {
        let gap = startFrame - nextFrame
        guard gap > 0 else { return }
        if gap >= retainFrames {
            activeSlots.removeAll()
            baseFrame = startFrame
        } else {
            activeSlots.append(contentsOf: repeatElement(Self.silence, count: gap))
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
        guard activeSlots.count > retainFrames * 2 else { return }
        let dropped = activeSlots.count - retainFrames
        activeSlots.removeFirst(dropped)
        baseFrame += dropped
    }

    private func dominantSlot(start: TimeInterval, end: TimeInterval) -> Int? {
        let first = max(Int(((start - originSeconds) / frameDuration).rounded(.down)), baseFrame)
        let last = min(Int(((end - originSeconds) / frameDuration).rounded(.up)), nextFrame)
        guard first < last else { return nil }
        var counts = [Int](repeating: 0, count: slotCount)
        for frame in first..<last {
            let slot = activeSlots[frame - baseFrame]
            if slot >= 0 { counts[Int(slot)] += 1 }
        }
        let best = counts.indices.min { lhs, rhs in
            if counts[lhs] != counts[rhs] { return counts[lhs] > counts[rhs] }
            let (lhsNumber, rhsNumber) = (displayNumbers[lhs] ?? .max, displayNumbers[rhs] ?? .max)
            return lhsNumber != rhsNumber ? lhsNumber < rhsNumber : lhs < rhs
        }
        guard let best, counts[best] >= min(Self.minimumActiveFrames, last - first) else { return nil }
        return best
    }

    private mutating func displayNumber(for slot: Int) -> Int {
        if let number = displayNumbers[slot] { return number }
        let number = displayNumbers.count + 1
        displayNumbers[slot] = number
        return number
    }
}
