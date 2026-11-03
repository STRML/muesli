import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Live calendar event actions")
struct LiveCalendarEventActionsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var end: Date { start.addingTimeInterval(3600) }

    private func actions(
        now: Date, hasURL: Bool = true, recording: LiveRecordingContext = .idle
    ) -> [LiveCalendarEventAction] {
        LiveCalendarEventActions.visibleActions(
            start: start, end: end, now: now, hasMeetingURL: hasURL, recording: recording)
    }

    private var live: Date { start.addingTimeInterval(120) }

    @Test("a live event with a link offers Join & Transcribe and Transcribe")
    func liveWithLink() {
        #expect(actions(now: live) == [.joinAndTranscribe, .transcribe])
    }

    @Test("a live event without a link offers only Transcribe")
    func liveWithoutLink() {
        #expect(actions(now: live, hasURL: false) == [.transcribe])
    }

    @Test("buttons appear five minutes before the start and stop at the end")
    func window() {
        #expect(actions(now: start.addingTimeInterval(-6 * 60)).isEmpty)
        #expect(actions(now: start.addingTimeInterval(-5 * 60)) == [.joinAndTranscribe, .transcribe])
        #expect(actions(now: start.addingTimeInterval(-1)) == [.joinAndTranscribe, .transcribe])
        #expect(actions(now: end.addingTimeInterval(-1)) == [.joinAndTranscribe, .transcribe])
        #expect(actions(now: end).isEmpty)
        #expect(actions(now: end.addingTimeInterval(600)).isEmpty)
    }

    @Test("nothing is offered while a recording is starting")
    func starting() {
        #expect(actions(now: live, recording: .starting).isEmpty)
    }

    @Test("nothing is offered while this very event is being recorded")
    func recordingThisEvent() {
        #expect(actions(now: live, recording: .recordingThisEvent).isEmpty)
    }

    @Test("another meeting still recording offers to switch, so a live event is never blocked")
    func recordingAnotherMeeting() {
        #expect(actions(now: live, recording: .recordingOtherMeeting) == [.switchAndJoin, .switchAndTranscribe])
        #expect(actions(now: live, hasURL: false, recording: .recordingOtherMeeting) == [.switchAndTranscribe])
    }

    @Test("an event outside its window offers nothing even when another meeting records")
    func outsideWindowWhileRecording() {
        #expect(actions(now: end.addingTimeInterval(60), recording: .recordingOtherMeeting).isEmpty)
    }

    @Test("an event that ends before it starts is never live")
    func invertedRange() {
        let result = LiveCalendarEventActions.visibleActions(
            start: end, end: start, now: live, hasMeetingURL: true, recording: .idle)
        #expect(result.isEmpty)
    }

    @Test("recording context: idle, starting, this event, another meeting")
    func contextFromState() {
        #expect(LiveRecordingContext.make(isRecording: false, isStarting: false, activeIsThisEvent: false) == .idle)
        #expect(LiveRecordingContext.make(isRecording: false, isStarting: true, activeIsThisEvent: false) == .starting)
        #expect(LiveRecordingContext.make(isRecording: true, isStarting: false, activeIsThisEvent: true) == .recordingThisEvent)
        #expect(LiveRecordingContext.make(isRecording: true, isStarting: false, activeIsThisEvent: false) == .recordingOtherMeeting)
    }
}
