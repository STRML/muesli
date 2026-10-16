import Foundation

/// Lets a superseded post-Stop pipeline drop its LLM stages (title, summary) while the transcript
/// stages run to completion. Once cancelled, `run` never hands back a result, even one that
/// finished at the same instant, so a late summary cannot be written over a resumed meeting.
final class MeetingSummaryStageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {}

    /// Runs `work`; returns nil when the gate was cancelled before or while it ran.
    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await work()
    }
}
