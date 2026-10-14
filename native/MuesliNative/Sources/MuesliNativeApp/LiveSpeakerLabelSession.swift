import Foundation
import os

/// A streaming diarizer reduced to what live labels need. The real engine wraps
/// FluidAudio's LS-EEND; tests drive the session with a scripted fake.
protocol LiveSpeakerEngine: AnyObject, Sendable {
    var slotCount: Int { get }
    var frameDuration: TimeInterval { get }
    /// Feed 16 kHz mono samples; returns the frames that became final, if any.
    func process(samples: [Float]) throws -> LiveSpeakerFrames?
    /// Flush the right-context tail at end of stream.
    func finish() throws -> LiveSpeakerFrames?
}

/// Provisional "Speaker N" labels for a meeting's system audio.
///
/// The session never touches recording: `enqueue` is a lock and an array append,
/// CoreML runs on its own queue, and every problem (model missing, slow load,
/// engine error, backlog) ends in `.failed`, after which every label is "Others".
/// The final Stop-time diarization pass is separate and untouched.
///
/// The sample clock starts at the session's first `enqueue`. Audio that piles up
/// while the model loads is dropped oldest-first and the clock origin moves with
/// it, so labels stay aligned. After the engine is running nothing is dropped:
/// overflow fails the session instead of silently desynchronising it.
final class LiveSpeakerLabelSession: @unchecked Sendable {
    typealias EngineFactory = @Sendable () async throws -> LiveSpeakerEngine

    enum Failure: Equatable, Sendable {
        case loadFailed
        case loadTimedOut
        case backlogOverflow
        case engineError
    }

    enum Status: Equatable, Sendable {
        case loading
        case running
        case stopping
        case stopped
        case failed(Failure)
    }

    struct Limits: Sendable {
        var loadTimeout: Duration = .seconds(30)
        var maxBacklogSeconds: Double = 60
        var coverageWait: Duration = .seconds(2)
        var retainSeconds: Double = 300
    }

    static let sampleRate = 16_000
    private static let logger = Logger(subsystem: "com.muesli.native", category: "LiveSpeakerLabels")

    private struct State {
        var status = Status.loading
        var engine: LiveSpeakerEngine?
        var labeler: LiveSpeakerLabeler?
        var pending: [[Float]] = []
        var pendingSamples = 0
        var droppedSamples = 0
        var loadTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        var acceptsAudio: Bool { status == .loading || status == .running }

        /// Terminal states stay put; only a live session can fail.
        mutating func fail(_ failure: Failure) {
            guard status == .loading || status == .running || status == .stopping else { return }
            status = .failed(failure)
            engine = nil
            pending = []
            pendingSamples = 0
            loadTask?.cancel()
            timeoutTask?.cancel()
        }

        /// True once waiting for the diarizer cannot improve an answer.
        func isSettled(through end: TimeInterval) -> Bool {
            switch status {
            case .loading, .stopped, .failed: return true
            case .running, .stopping: return (labeler?.coveredThrough ?? 0) >= end
            }
        }
    }

    private let factory: EngineFactory
    private let limits: Limits
    private let maxBacklogSamples: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let processingQueue = DispatchQueue(label: "com.muesli.live-speaker-labels", qos: .userInitiated)

    init(factory: @escaping EngineFactory, limits: Limits = Limits()) {
        self.factory = factory
        self.limits = limits
        maxBacklogSamples = Int(limits.maxBacklogSeconds * Double(Self.sampleRate))
    }

    var status: Status { state.withLock { $0.status } }

    /// Begins loading the engine. Audio enqueued before this is buffered.
    func start() {
        let factory = factory
        let loadTask = Task { [weak self] in
            do {
                self?.engineLoaded(try await factory())
            } catch {
                self?.failed(.loadFailed, "engine load failed: \(error)")
            }
        }
        let timeout = limits.loadTimeout
        let timeoutTask = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.failed(.loadTimedOut, "engine load timed out")
        }
        state.withLock { s in
            guard s.status == .loading else {
                loadTask.cancel()
                timeoutTask.cancel()
                return
            }
            s.loadTask = loadTask
            s.timeoutTask = timeoutTask
        }
    }

    /// Cheap and non-blocking: called from the audio queue for every system buffer.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let isRunning = state.withLock { s -> Bool in
            guard s.acceptsAudio else { return false }
            s.pending.append(samples)
            s.pendingSamples += samples.count
            guard s.pendingSamples > maxBacklogSamples else { return s.status == .running }
            if s.status == .loading {
                dropOldestPending(&s)
                return false
            }
            s.fail(.backlogOverflow)
            Self.logger.error("live speaker labels off: audio backlog exceeded \(self.limits.maxBacklogSeconds)s")
            return false
        }
        if isRunning { processingQueue.async { self.drainPending() } }
    }

    /// Provisional label for a time range on the system-sample clock. Waits a
    /// bounded time for the diarizer to reach `end`, then answers with what it has.
    func label(start: TimeInterval, end: TimeInterval) async -> String {
        let deadline = ContinuousClock.now + limits.coverageWait
        while !state.withLock({ $0.isSettled(through: end) }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return state.withLock { $0.labeler?.label(start: start, end: end) } ?? LiveSpeakerLabeler.fallbackLabel
    }

    /// Flushes the last partial window through the engine, then releases it.
    func stop() {
        let finishEngine = state.withLock { s -> Bool in
            switch s.status {
            case .running:
                s.status = .stopping
                return true
            case .loading:
                s.status = .stopped
                s.loadTask?.cancel()
                s.timeoutTask?.cancel()
                s.pending = []
                s.pendingSamples = 0
                return false
            case .stopping, .stopped, .failed:
                return false
            }
        }
        if finishEngine { processingQueue.async { self.finishAndRelease() } }
    }

    // MARK: - Engine lifecycle

    private func engineLoaded(_ engine: LiveSpeakerEngine) {
        let shouldDrain = state.withLock { s -> Bool in
            // A late engine (timed out, failed or stopped meanwhile) is dropped.
            guard s.status == .loading else { return false }
            s.status = .running
            s.engine = engine
            s.labeler = LiveSpeakerLabeler(
                slotCount: engine.slotCount,
                frameDuration: engine.frameDuration,
                originSeconds: Double(s.droppedSamples) / Double(Self.sampleRate),
                retainSeconds: limits.retainSeconds
            )
            s.timeoutTask?.cancel()
            return !s.pending.isEmpty
        }
        if shouldDrain { processingQueue.async { self.drainPending() } }
    }

    private func failed(_ failure: Failure, _ message: String) {
        let didFail = state.withLock { s -> Bool in
            let wasLive = s.status == .loading || s.status == .running || s.status == .stopping
            s.fail(failure)
            return wasLive
        }
        if didFail { Self.logger.error("live speaker labels off: \(message)") }
    }

    private func dropOldestPending(_ s: inout State) {
        while s.pendingSamples > maxBacklogSamples, !s.pending.isEmpty {
            let dropped = s.pending.removeFirst()
            s.pendingSamples -= dropped.count
            s.droppedSamples += dropped.count
        }
    }

    // MARK: - Processing queue

    private func drainPending() {
        while let (engine, samples) = takePending() {
            do {
                ingest(try engine.process(samples: samples))
            } catch {
                failed(.engineError, "engine error: \(error)")
                return
            }
        }
    }

    private func takePending() -> (LiveSpeakerEngine, [Float])? {
        state.withLock { s in
            guard s.status == .running || s.status == .stopping,
                  let engine = s.engine, !s.pending.isEmpty else { return nil }
            let samples = s.pending.flatMap { $0 }
            s.pending = []
            s.pendingSamples = 0
            return (engine, samples)
        }
    }

    private func finishAndRelease() {
        drainPending()
        let engine = state.withLock { $0.status == .stopping ? $0.engine : nil }
        if let engine {
            do {
                ingest(try engine.finish())
            } catch {
                Self.logger.error("live speaker labels: tail flush failed: \(error)")
            }
        }
        state.withLock { s in
            guard s.status == .stopping else { return }
            s.status = .stopped
            s.engine = nil
        }
    }

    private func ingest(_ frames: LiveSpeakerFrames?) {
        guard let frames else { return }
        state.withLock { $0.labeler?.ingest(frames) }
    }
}
