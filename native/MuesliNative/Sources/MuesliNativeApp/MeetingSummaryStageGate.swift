import Foundation

/// Lets a superseded post-Stop pipeline drop its LLM stages (title, summary) while the transcript
/// stages run to completion. Once cancelled, `run` never hands back a result, even one that
/// finished at the same instant, so a late summary cannot be written over a resumed meeting.
final class MeetingSummaryStageGate: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var inFlight: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = NSLock()
    private var guarded = State()

    var isCancelled: Bool {
        state.withLock { guarded.cancelled }
    }

    /// Marks the gate cancelled and cancels any stage already running under it.
    func cancel() {
        let running = state.withLock { () -> [@Sendable () -> Void] in
            guarded.cancelled = true
            return Array(guarded.inFlight.values)
        }
        running.forEach { $0() }
    }

    /// Runs `work`; returns nil when the gate was cancelled before or while it ran. A failure that
    /// lands after cancellation is swallowed: the caller no longer cares about the outcome.
    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        guard !isCancelled else { return nil }
        let id = UUID()
        let task = Task { try await work() }
        let alreadyCancelled = state.withLock { () -> Bool in
            guarded.inFlight[id] = { task.cancel() }
            return guarded.cancelled
        }
        if alreadyCancelled { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        let wasCancelled = state.withLock { () -> Bool in
            guarded.inFlight[id] = nil
            return guarded.cancelled
        }
        if wasCancelled { return nil }
        return try result.get()
    }
}
