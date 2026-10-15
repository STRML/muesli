import Foundation
import Testing
@testable import MuesliNativeApp

/// One scenario per row of the failure matrix in `docs/call-end-detection.md`. Each replays a whole
/// call second by second through the real resolver, media filter, session tracker and call tracker,
/// and checks when (and whether) the recording is told to stop.
@Suite("Meeting call-end scenarios")
struct MeetingCallEndScenarioTests {
    private typealias Run = CallEndScenarioRunner
    private let me = CallEndScenarioRunner.selfBundleID
    private let calls = MeetingCallEndDetectionTests.nativeCalls

    // MARK: building blocks

    private func inCall(_ call: MeetingCallEndDetectionTests.NativeCall, remote: Bool = true) -> CallFrame {
        CallFrame(micAttributed: [call.bundleID, me], runningApps: [call.bundleID], remoteSpeech: remote)
    }

    /// The call is over but the app is still open and Muesli still holds the mic.
    private func afterCall(
        _ call: MeetingCallEndDetectionTests.NativeCall,
        own: Bool = false,
        calendar: CalendarEventContext? = nil,
        selfAudioActive: Bool = true
    ) -> CallFrame {
        CallFrame(
            micAttributed: [me], selfAudioActive: selfAudioActive, runningApps: [call.bundleID],
            calendarEvent: calendar, ownSpeech: own
        )
    }

    private func source(_ call: MeetingCallEndDetectionTests.NativeCall) throws -> MeetingAutoStopSource {
        try armedSource(call.url)
    }

    private func armedSource(_ rawURL: String) throws -> MeetingAutoStopSource {
        let url = try #require(URL(string: rawURL))
        let source = MeetingAutoStopSource(meetingURL: url)
        return try #require(source)
    }

    private let meetRoomA = "https://meet.google.com/abc-defg-hij"
    private let meetRoomB = "https://meet.google.com/zzz-yyyy-xxx"

    private func tab(_ rawURL: String) throws -> BrowserMeetingContext {
        let normalized = try #require(MeetingURLNormalizer.normalize(rawURL))
        return BrowserMeetingContext(
            bundleID: "com.google.Chrome", appName: "Chrome", url: normalized.url,
            normalizedID: normalized.id, platform: normalized.platform, isFocused: true
        )
    }

    private func meetSource(_ rawURL: String) throws -> MeetingAutoStopSource {
        try armedSource(rawURL)
    }

    private func meetFrame(_ rawURL: String, live: Bool = true, tabOpen: Bool = true, remote: Bool = true) throws -> CallFrame {
        CallFrame(
            micAttributed: live ? ["com.google.Chrome", me] : [me],
            runningApps: ["com.google.Chrome"],
            browserTabs: tabOpen ? [try tab(rawURL)] : [],
            remoteSpeech: remote
        )
    }

    /// The seconds a stop may land in: the later of the grace and quiet periods after the last signal.
    private func expectStop(_ timeline: CallEndTimeline, between range: ClosedRange<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(timeline.seconds(of: .stopAndNotify).count == 1, "exactly one stop", sourceLocation: sourceLocation)
        let at = timeline.seconds(of: .stopAndNotify).first ?? -1
        #expect(range.contains(at), "stopped at \(at) s, expected \(range)", sourceLocation: sourceLocation)
    }

    // MARK: E1 call ends in a native app

    @Test("E1 a native call ends and the app stays open: the recording stops after the quiet period",
          arguments: MeetingCallEndDetectionTests.nativeCalls)
    func e1NativeCallEnds(call: MeetingCallEndDetectionTests.NativeCall) async throws {
        let timeline = await Run.run(source: try source(call), seconds: 200) {
            $0 < 60 ? inCall(call, remote: $0 % 5 == 0) : afterCall(call)
        }
        // Last remote speech at 55 s, so the 20 s quiet period ends at 75 s.
        expectStop(timeline, between: 74...77)
    }

    @Test("E1 a calendar guess from the running app does not keep a finished call alive")
    func e1CalendarGuessDoesNotKeepCallAlive() async throws {
        let zoom = calls[3]
        let calendar = CalendarEventContext(id: "evt-1", title: "Planning")
        // Muesli's own capture is not yet known to the monitor (the self-activity flag lags), so the
        // system mic flag is on with no attribution.
        let timeline = await Run.run(source: try source(zoom), seconds: 200) {
            $0 < 60 ? inCall(zoom, remote: $0 % 5 == 0)
                : afterCall(zoom, calendar: calendar, selfAudioActive: false)
        }
        expectStop(timeline, between: 74...77)
    }

    // MARK: E2, E3 browser calls

    @Test("E2 a browser call ends and the tab is closed")
    func e2TabClosed() async throws {
        let timeline = await Run.run(source: try meetSource(meetRoomA), seconds: 200) {
            try! meetFrame(meetRoomA, live: $0 < 60, tabOpen: $0 < 60, remote: $0 < 60 && $0 % 5 == 0)
        }
        expectStop(timeline, between: 74...77)
    }

    @Test("E3 a browser call ends and the tab stays open on the post-call page")
    func e3TabLeftOpen() async throws {
        let timeline = await Run.run(source: try meetSource(meetRoomA), seconds: 200) {
            try! meetFrame(meetRoomA, live: $0 < 60, tabOpen: true, remote: $0 < 60 && $0 % 5 == 0)
        }
        expectStop(timeline, between: 74...77)
    }

    // MARK: E4, E5, E7, E8 the call is still going

    @Test("E4 a signal drop shorter than the grace period does nothing")
    func e4ShortDropout() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 300) {
            (60..<75).contains($0) ? afterCall(zoom) : inCall(zoom, remote: $0 % 5 == 0)
        }
        #expect(timeline.actions.isEmpty)
    }

    @Test("E5 a long drop while remote speech keeps arriving does nothing")
    func e5LongDropoutWithSpeech() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 300) {
            var frame = (60..<120).contains($0) ? afterCall(zoom) : inCall(zoom)
            frame.remoteSpeech = $0 % 5 == 0
            return frame
        }
        #expect(timeline.actions.isEmpty)
    }

    @Test("E7 muted and listening, with the mic still attributed, survives a silent meeting")
    func e7MutedListening() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 600) {
            inCall(zoom, remote: $0 < 60 && $0 % 5 == 0)
        }
        #expect(timeline.actions.isEmpty)
    }

    @Test("E8 rejoining clears the loss, and a later end stops the recording once")
    func e8RejoinThenEnd() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 400) {
            if $0 < 200 {
                return (60..<75).contains($0) ? afterCall(zoom) : inCall(zoom, remote: $0 % 5 == 0)
            }
            return afterCall(zoom)
        }
        // Last remote speech at 195 s, so the stop lands at 215 s.
        expectStop(timeline, between: 214...217)
    }

    // MARK: E6 own voice after the call

    @Test("E6 the user's own voice after the call does not defer the stop")
    func e6OwnVoiceDoesNotDefer() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 300) {
            $0 < 60 ? inCall(zoom, remote: $0 % 5 == 0) : afterCall(zoom, own: $0 % 3 == 0)
        }
        expectStop(timeline, between: 74...77)
    }

    // MARK: E9, E10 recordings that never stop by themselves

    @Test("E9 a source that was never seen never stops the recording")
    func e9NeverSeen() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 600) { _ in afterCall(zoom) }
        #expect(timeline.actions.isEmpty)
    }

    @Test("E10 a manual recording never stops by itself")
    func e10Manual() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: nil, origin: .manual, seconds: 300) {
            $0 < 60 ? inCall(zoom) : afterCall(zoom)
        }
        #expect(timeline.actions.isEmpty)
        #expect(MeetingRecordingStartOrigin.manual.signalLossResponse == .none)
    }

    @Test("E10 every source-backed origin stops with a notice",
          arguments: [MeetingRecordingStartOrigin.detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord])
    func tracked(origin: MeetingRecordingStartOrigin) {
        #expect(origin.signalLossResponse == .stopWithNotice)
    }

    // MARK: E11 a second call

    @Test("E11 a second room in the same browser does not keep the first call's recording alive")
    func e11SecondRoomInSameBrowser() async throws {
        let timeline = await Run.run(source: try meetSource(meetRoomA), seconds: 250) {
            $0 < 60 ? try! meetFrame(meetRoomA, remote: $0 % 5 == 0) : try! meetFrame(meetRoomB, remote: false)
        }
        expectStop(timeline, between: 74...77)
    }

    // MARK: E13, E16, E17 what the user and the controller do

    @Test("E13 stopping by hand during the grace period leaves nothing to fire")
    func e13ManualStopDuringGrace() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 300, stopAt: 70) {
            $0 < 60 ? inCall(zoom, remote: $0 % 5 == 0) : afterCall(zoom)
        }
        #expect(timeline.actions.isEmpty)
    }

    @Test("E16 the stop is decided once, however long the loss lasts")
    func e16StopOnce() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 900) {
            $0 < 60 ? inCall(zoom, remote: $0 % 5 == 0) : afterCall(zoom)
        }
        #expect(timeline.seconds(of: .stopAndNotify).count == 1)
        #expect(!timeline.actions.contains(.reofferToast))
    }

    @Test("E17 a call-ended alert the user dismissed never stops the recording")
    func e17Dismissed() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 300, dismissAt: 30) {
            $0 < 60 ? inCall(zoom, remote: $0 % 5 == 0) : afterCall(zoom)
        }
        #expect(timeline.actions.isEmpty)
    }

    // MARK: E14, E15 the scheduled-end popup

    @Test("E14 the scheduled-end popup shows while the call is live or not yet seen")
    func e14PopupWhileLive() throws {
        let zoom = calls[3]
        var tracker = MeetingAutoStopTracker()
        #expect(MeetingCallEndPolicy.showsScheduledEndPopup(tracker: tracker))
        tracker.arm(source: try source(zoom))
        #expect(MeetingCallEndPolicy.showsScheduledEndPopup(tracker: tracker))
    }

    @Test("E15 the scheduled-end popup yields once the call is lost")
    func e15PopupYieldsToLostCall() async throws {
        let zoom = calls[3]
        let timeline = await Run.run(source: try source(zoom), seconds: 80) {
            $0 < 60 ? inCall(zoom, remote: true) : afterCall(zoom)
        }
        #expect(timeline.lostAtSecond[59] == false)
        #expect(timeline.lostAtSecond[60] == true)

        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: try source(zoom))
        tracker.markRecordingStarted(now: CallEndScenarioRunner.start)
        let candidate = MeetingCandidate(
            id: "meeting-session:app:us.zoom.xos:1", platform: .zoom, appName: "zoom.us", url: nil,
            evidence: [.audioInputProcess, .dedicatedApp], startedAt: CallEndScenarioRunner.start,
            meetingTitle: nil, sourceBundleID: "us.zoom.xos"
        )
        _ = tracker.observe(candidate: candidate, now: CallEndScenarioRunner.start, gracePeriod: 20)
        #expect(MeetingCallEndPolicy.showsScheduledEndPopup(tracker: tracker))
        _ = tracker.observe(candidate: nil, now: CallEndScenarioRunner.start.addingTimeInterval(1), gracePeriod: 20)
        #expect(!MeetingCallEndPolicy.showsScheduledEndPopup(tracker: tracker))
    }
}
