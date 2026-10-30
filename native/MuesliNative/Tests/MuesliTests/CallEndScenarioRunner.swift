import Foundation
@testable import MuesliNativeApp

/// What the machine reports during one second of a call. A scenario is a function from the second
/// to a frame, replayed through the same resolver, filter, session tracker and call tracker the
/// live monitor uses (`docs/call-end-detection.md`).
struct CallFrame {
    /// Control Center's mic and camera attributions, the only audio evidence while a recording follows a call.
    var micAttributed: Set<String> = []
    var cameraAttributed: Set<String> = []
    /// The system-wide mic flag. Muesli's own recording keeps it on after the call ends.
    var deviceMicActive = true
    var cameraActive = false
    /// Whether Muesli knows its own capture is what holds the mic.
    var selfAudioActive = true
    var runningApps: [String] = []
    var browserTabs: [BrowserMeetingContext] = []
    var calendarEvent: CalendarEventContext?
    /// Speech transcribed in this second.
    var remoteSpeech = false
    var ownSpeech = false
}

struct CallEndTimeline {
    struct Event: Equatable {
        let second: Int
        let action: MeetingSignalLossAction
    }

    let events: [Event]
    /// The decision-relevant state at each second: whether the tracker had lost the call.
    let lostAtSecond: [Int: Bool]

    var actions: [MeetingSignalLossAction] { events.map(\.action) }

    func seconds(of action: MeetingSignalLossAction) -> [Int] {
        events.filter { $0.action == action }.map(\.second)
    }
}

enum CallEndScenarioRunner {
    static let selfBundleID = "com.muesli.app"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Replays `seconds` one-second ticks. The recording starts at second 0 with `source` armed.
    static func run(
        source: MeetingAutoStopSource?,
        origin: MeetingRecordingStartOrigin = .joinAndRecord,
        seconds: Int,
        stopAt stopSecond: Int? = nil,
        dismissAt dismissSecond: Int? = nil,
        frame: (Int) -> CallFrame
    ) async -> CallEndTimeline {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = selfBundleID
        let sessions = MeetingMediaSessionTracker()
        var tracker = MeetingAutoStopTracker()
        var prompt = MeetingSignalLossPromptState()
        tracker.arm(source: source)
        tracker.markRecordingStarted(now: start)
        let response = origin.signalLossResponse

        var events: [CallEndTimeline.Event] = []
        var lost: [Int: Bool] = [:]
        for second in 0..<seconds {
            let now = start.addingTimeInterval(TimeInterval(second))
            if second == stopSecond { tracker.disarm() }
            if second == dismissSecond { prompt.markDismissedByUser() }
            let frame = frame(second)
            if frame.remoteSpeech { prompt.noteTranscriptActivity(from: "Others", now: now) }
            if frame.ownSpeech { prompt.noteTranscriptActivity(from: MeetingSignalLossPromptState.ownVoiceSpeakerLabel, now: now) }

            let candidate = await observedCandidate(frame, tracker: tracker, resolver: resolver, sessions: sessions, now: now)
            let action = MeetingCallEndPolicy.step(
                tracker: &tracker, prompt: &prompt, response: response, candidate: candidate, now: now
            )
            lost[second] = tracker.hasLostSource
            if action != .none { events.append(.init(second: second, action: action)) }
        }
        return CallEndTimeline(events: events, lostAtSecond: lost)
    }

    /// The monitor's evaluation for one tick, in source-liveness mode.
    private static func observedCandidate(
        _ frame: CallFrame,
        tracker: MeetingAutoStopTracker,
        resolver: MeetingCandidateResolver,
        sessions: MeetingMediaSessionTracker,
        now: Date
    ) async -> MeetingCandidate? {
        let attributions = SensorAttributionSnapshot(
            micBundleIDs: frame.micAttributed, cameraBundleIDs: frame.cameraAttributed, observedAt: now
        )
        let processes = MeetingAutoStopPolicy.livenessAudioProcesses(
            [],
            sensorAttributions: attributions,
            runningProcessIDsByBundleID: Dictionary(uniqueKeysWithValues: frame.runningApps.map { ($0, pid_t(4321)) }),
            source: tracker.source
        )
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: frame.deviceMicActive,
            cameraActive: frame.cameraActive,
            audioInputProcesses: processes,
            sensorAttributions: attributions,
            selfAudioActivityActive: frame.selfAudioActive,
            selfBundleID: selfBundleID
        )
        var tabs = frame.browserTabs
        if let source = tracker.source {
            tabs = MeetingAutoStopPolicy.scopedBrowserMeetings(tabs, source: source)
        }
        let snapshot = MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: frame.calendarEvent,
            runningApps: frame.runningApps.map { RunningAppInfo(bundleID: $0, isActive: false) },
            browserMeetings: tabs,
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        )
        let stabilized = await sessions.stabilize(candidate: resolver.resolve(snapshot), snapshot: snapshot)
        guard let source = tracker.source else { return nil }
        return MeetingAutoStopPolicy.followedCandidate(stabilized, source: source)
    }
}
