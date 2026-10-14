import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Live calendar event actions")
struct LiveCalendarEventActionsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var end: Date { start.addingTimeInterval(3600) }

    private func actions(
        now: Date, hasURL: Bool = true, busy: Bool = false
    ) -> [LiveCalendarEventAction] {
        LiveCalendarEventActions.visibleActions(
            start: start, end: end, now: now, hasMeetingURL: hasURL, isRecordingBusy: busy)
    }

    @Test("a live event with a link offers Join & Transcribe and Transcribe")
    func liveWithLink() {
        #expect(actions(now: start.addingTimeInterval(120)) == [.joinAndTranscribe, .transcribe])
    }

    @Test("a live event without a link offers only Transcribe")
    func liveWithoutLink() {
        #expect(actions(now: start.addingTimeInterval(120), hasURL: false) == [.transcribe])
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

    @Test("nothing is offered while a recording is running or starting")
    func busy() {
        #expect(actions(now: start.addingTimeInterval(120), busy: true).isEmpty)
    }

    @Test("an event that ends before it starts is never live")
    func invertedRange() {
        let result = LiveCalendarEventActions.visibleActions(
            start: end, end: start, now: start.addingTimeInterval(120), hasMeetingURL: true, isRecordingBusy: false)
        #expect(result.isEmpty)
    }
}
