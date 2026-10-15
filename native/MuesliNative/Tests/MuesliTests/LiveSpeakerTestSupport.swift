import Foundation
@testable import MuesliNativeApp

/// Builds synthetic diarizer output: one entry per 0.1 s frame, the slot that is
/// speaking (probability 0.9) or nil for silence.
func liveSpeakerFrames(_ active: [Int?], slotCount: Int = 4, startFrame: Int = 0) -> LiveSpeakerFrames {
    var probabilities: [Float] = []
    probabilities.reserveCapacity(active.count * slotCount)
    for slot in active {
        for index in 0..<slotCount {
            probabilities.append(index == slot ? 0.9 : 0.05)
        }
    }
    return LiveSpeakerFrames(startFrame: startFrame, slotCount: slotCount, probabilities: probabilities)
}

func slotRun(_ slot: Int?, frames: Int) -> [Int?] {
    Array(repeating: slot, count: frames)
}

/// Scripted stand-in for the LS-EEND engine. It emits one 0.1 s frame per 1,600
/// samples, `lagFrames` behind the audio like the real right-context delay, and
/// everything left on `finish()`.
final class ScriptedLiveSpeakerEngine: LiveSpeakerEngine, @unchecked Sendable {
    struct Failure: Error {}

    let slotCount: Int
    let frameDuration: TimeInterval = 0.1
    private let lock = NSLock()
    private let activeSlot: @Sendable (Int) -> Int?
    private let lagFrames: Int
    private let failAtSamples: Int?
    private let gate: DispatchSemaphore?
    private var samplesSeen = 0
    private var framesEmitted = 0
    private var finishes = 0
    private var partialBlockCalls = 0

    init(
        slotCount: Int = 4,
        lagFrames: Int = 3,
        failAtSamples: Int? = nil,
        gate: DispatchSemaphore? = nil,
        activeSlot: @escaping @Sendable (Int) -> Int?
    ) {
        self.slotCount = slotCount
        self.lagFrames = lagFrames
        self.failAtSamples = failAtSamples
        self.gate = gate
        self.activeSlot = activeSlot
    }

    var totalSamplesSeen: Int { lock.withLock { samplesSeen } }
    var finishCalls: Int { lock.withLock { finishes } }
    /// Calls whose length was not a whole number of 100 ms blocks.
    var calledWithPartialBlock: Int { lock.withLock { partialBlockCalls } }

    func process(samples: [Float]) throws -> LiveSpeakerFrames? {
        gate?.wait()
        return try lock.withLock {
            if let failAtSamples, samplesSeen + samples.count >= failAtSamples { throw Failure() }
            if !samples.count.isMultiple(of: LiveSpeakerLabelSession.blockSamples) { partialBlockCalls += 1 }
            samplesSeen += samples.count
            return emit(upTo: max(samplesSeen / 1_600 - lagFrames, 0))
        }
    }

    func finish() throws -> LiveSpeakerFrames? {
        lock.withLock {
            finishes += 1
            return emit(upTo: samplesSeen / 1_600)
        }
    }

    private func emit(upTo frame: Int) -> LiveSpeakerFrames? {
        guard frame > framesEmitted else { return nil }
        let block = (framesEmitted..<frame).map(activeSlot)
        defer { framesEmitted = frame }
        return liveSpeakerFrames(block, slotCount: slotCount, startFrame: framesEmitted)
    }
}

/// Feeds `seconds` of audio the way the system recorder does: small buffers.
func feedLiveSpeakerAudio(_ session: LiveSpeakerLabelSession, seconds: Double) {
    let buffer = [Float](repeating: 0.1, count: 8_000)
    for _ in 0..<Int(seconds * 2) { session.enqueue(buffer) }
}

func liveSpeakerWaitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
