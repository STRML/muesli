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
///
/// The engine only ever sees whole 100 ms blocks (1,600 samples; the rest waits
/// for the next call). FluidAudio resamples each call on its own and rounds odd
/// lengths up, which would stretch the diarizer's clock against the chunk timing
/// by a fraction of a percent, a few seconds over an hour-long meeting.
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
        var retainSeconds: Double = .infinity
    }

    static let sampleRate = 16_000
    /// 100 ms: halves exactly when resampled to the model's 8 kHz.
    static let blockSamples = 1_600
    private static let logger = Logger(subsystem: "com.muesli.native", category: "LiveSpeakerLabels")

    private struct State {
        var status = Status.loading
        var engine: LiveSpeakerEngine?
        var labeler: LiveSpeakerLabeler?
        var pending: [Float] = []
        var droppedSamples = 0
        var loadTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var onStatusChanged: (@Sendable (Status) -> Void)?
        var onCoverageAdvanced: (@Sendable (TimeInterval) -> Void)?

        var acceptsAudio: Bool { status == .loading || status == .running }

        /// Terminal states stay put; only a live session can fail.
        @discardableResult
        mutating func fail(_ failure: Failure) -> (Status, (@Sendable (Status) -> Void)?)? {
            guard status == .loading || status == .running || status == .stopping else { return nil }
            status = .failed(failure)
            engine = nil
            pending = []
            loadTask?.cancel()
            timeoutTask?.cancel()
            return (status, onStatusChanged)
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

    init(
        factory: @escaping EngineFactory,
        limits: Limits = Limits(),
        onStatusChanged: (@Sendable (Status) -> Void)? = nil,
        onCoverageAdvanced: (@Sendable (TimeInterval) -> Void)? = nil
    ) {
        self.factory = factory
        self.limits = limits
        maxBacklogSamples = Int(limits.maxBacklogSeconds * Double(Self.sampleRate))
        state.withLock { s in
            s.onStatusChanged = onStatusChanged
            s.onCoverageAdvanced = onCoverageAdvanced
        }
    }

    var onStatusChanged: (@Sendable (Status) -> Void)? {
        get { state.withLock { $0.onStatusChanged } }
        set { state.withLock { $0.onStatusChanged = newValue } }
    }

    var onCoverageAdvanced: (@Sendable (TimeInterval) -> Void)? {
        get { state.withLock { $0.onCoverageAdvanced } }
        set { state.withLock { $0.onCoverageAdvanced = newValue } }
    }

    var status: Status { state.withLock { $0.status } }

    var activeSpeakerCount: Int { state.withLock { $0.labeler?.speakerCount ?? 0 } }

    var coveredThrough: TimeInterval { state.withLock { $0.labeler?.coveredThrough ?? 0 } }

    /// True once the engine has produced a labeler and the session has not failed.
    /// Labels stay answerable after `stop()`, so chunks still committing keep them.
    var isLabeling: Bool {
        state.withLock { s in
            if case .failed = s.status { return false }
            return s.labeler != nil
        }
    }

    /// Begins loading the engine. Audio enqueued before this is buffered.
    func start() {
        let initialNotification = state.withLock { s -> (Status, (@Sendable (Status) -> Void)?)? in
            guard s.status == .loading else { return nil }
            return (s.status, s.onStatusChanged)
        }
        initialNotification?.1?(initialNotification?.0 ?? .loading)

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
        let (isRunning, statusNotification) = state.withLock { s -> (Bool, (Status, (@Sendable (Status) -> Void)?)?) in
            guard s.acceptsAudio else { return (false, nil) }
            s.pending.append(contentsOf: samples)
            guard s.pending.count > maxBacklogSamples else { return (s.status == .running, nil) }
            if s.status == .loading {
                dropOldestPending(&s)
                return (false, nil)
            }
            let notification = s.fail(.backlogOverflow)
            Self.logger.error("live speaker labels off: audio backlog exceeded \(self.limits.maxBacklogSeconds)s")
            return (false, notification)
        }
        statusNotification?.1?(statusNotification?.0 ?? .failed(.backlogOverflow))
        if isRunning { processingQueue.async { self.drainPending() } }
    }

    /// Provisional resolution for a time range on the system-sample clock. Waits a
    /// bounded time for the diarizer to reach `end`, then answers with what it has.
    func labelResolution(start: TimeInterval, end: TimeInterval) async -> LiveSpeakerResolution {
        let deadline = ContinuousClock.now + limits.coverageWait
        while !state.withLock({ $0.isSettled(through: end) }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return state.withLock { $0.labeler?.labelResolution(start: start, end: end) } ?? .uncovered
    }

    /// Provisional label for a time range on the system-sample clock. Waits a
    /// bounded time for the diarizer to reach `end`, then answers with what it has.
    func label(start: TimeInterval, end: TimeInterval) async -> String {
        switch await labelResolution(start: start, end: end) {
        case .speaker(let label):
            return label
        case .silent, .uncovered:
            return LiveSpeakerLabeler.fallbackLabel
        }
    }

    /// Non-blocking retroactive label lookup once the diarizer has covered `[start, end]`.
    /// Returns `nil` while loading, after failure, or before `coveredThrough` reaches `end`.
    func labelIfCovered(start: TimeInterval, end: TimeInterval) -> String? {
        state.withLock { s in
            if case .failed = s.status { return nil }
            guard var labeler = s.labeler else { return nil }
            guard s.status == .stopped || labeler.coveredThrough >= end else { return nil }
            let resolution = labeler.labelResolution(start: start, end: end)
            s.labeler = labeler
            switch resolution {
            case .speaker(let label):
                return label
            case .silent:
                return LiveSpeakerLabeler.fallbackLabel
            case .uncovered:
                return nil
            }
        }
    }

    /// Flushes the last partial window through the engine, then releases it.
    func stop() {
        let (finishEngine, statusNotification) = state.withLock { s -> (Bool, (Status, (@Sendable (Status) -> Void)?)?) in
            switch s.status {
            case .running:
                s.status = .stopping
                return (true, (s.status, s.onStatusChanged))
            case .loading:
                s.status = .stopped
                s.loadTask?.cancel()
                s.timeoutTask?.cancel()
                s.pending = []
                return (false, (s.status, s.onStatusChanged))
            case .stopping, .stopped, .failed:
                return (false, nil)
            }
        }
        statusNotification?.1?(statusNotification?.0 ?? .stopped)
        if finishEngine { processingQueue.async { self.finishAndRelease() } }
    }

    // MARK: - Engine lifecycle

    private func engineLoaded(_ engine: LiveSpeakerEngine) {
        let (shouldDrain, statusNotification) = state.withLock { s -> (Bool, (Status, (@Sendable (Status) -> Void)?)?) in
            // A late engine (timed out, failed or stopped meanwhile) is dropped.
            guard s.status == .loading else { return (false, nil) }
            s.status = .running
            s.engine = engine
            s.labeler = LiveSpeakerLabeler(
                slotCount: engine.slotCount,
                frameDuration: engine.frameDuration,
                originSeconds: Double(s.droppedSamples) / Double(Self.sampleRate),
                retainSeconds: limits.retainSeconds
            )
            s.timeoutTask?.cancel()
            return (s.pending.count >= Self.blockSamples, (s.status, s.onStatusChanged))
        }
        statusNotification?.1?(statusNotification?.0 ?? .running)
        if shouldDrain { processingQueue.async { self.drainPending() } }
    }

    private func failed(_ failure: Failure, _ message: String) {
        let statusNotification = state.withLock { s -> (Status, (@Sendable (Status) -> Void)?)? in
            s.fail(failure)
        }
        if let statusNotification {
            Self.logger.error("live speaker labels off: \(message)")
            statusNotification.1?(statusNotification.0)
        }
    }

    private func dropOldestPending(_ s: inout State) {
        let excess = s.pending.count - maxBacklogSamples
        s.pending.removeFirst(excess)
        s.droppedSamples += excess
    }

    // MARK: - Processing queue

    private func drainPending(includingPartialBlock: Bool = false) {
        while let (engine, samples) = takePending(includingPartialBlock: includingPartialBlock) {
            do {
                ingest(try engine.process(samples: samples))
            } catch {
                failed(.engineError, "engine error: \(error)")
                return
            }
        }
    }

    private func takePending(includingPartialBlock: Bool) -> (LiveSpeakerEngine, [Float])? {
        state.withLock { s in
            guard s.status == .running || s.status == .stopping, let engine = s.engine else { return nil }
            let count = includingPartialBlock ? s.pending.count : s.pending.count - s.pending.count % Self.blockSamples
            guard count > 0 else { return nil }
            let samples = Array(s.pending.prefix(count))
            s.pending.removeFirst(count)
            return (engine, samples)
        }
    }

    private func finishAndRelease() {
        drainPending(includingPartialBlock: true)
        let engine = state.withLock { $0.status == .stopping ? $0.engine : nil }
        if let engine {
            do {
                ingest(try engine.finish())
            } catch {
                Self.logger.error("live speaker labels: tail flush failed: \(error)")
            }
        }
        let statusNotification = state.withLock { s -> (Status, (@Sendable (Status) -> Void)?)? in
            guard s.status == .stopping else { return nil }
            s.status = .stopped
            s.engine = nil
            return (s.status, s.onStatusChanged)
        }
        statusNotification?.1?(statusNotification?.0 ?? .stopped)
    }

    private func ingest(_ frames: LiveSpeakerFrames?) {
        guard let frames else { return }
        let coverageNotification = state.withLock { s -> (TimeInterval, (@Sendable (TimeInterval) -> Void)?)? in
            guard s.labeler != nil else { return nil }
            s.labeler?.ingest(frames)
            guard let covered = s.labeler?.coveredThrough else { return nil }
            return (covered, s.onCoverageAdvanced)
        }
        if let coverageNotification {
            coverageNotification.1?(coverageNotification.0)
        }
    }
}
