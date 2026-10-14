import Foundation

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

    init(factory: @escaping EngineFactory, limits: Limits = Limits()) {}

    var status: Status { .loading }

    func start() {}

    /// Cheap and non-blocking: called from the audio queue for every system buffer.
    func enqueue(_ samples: [Float]) {}

    /// Provisional label for a time range on the system-sample clock.
    func label(start: TimeInterval, end: TimeInterval) async -> String {
        "Speaker 99"
    }

    func stop() {}
}
