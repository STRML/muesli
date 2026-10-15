import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Sidebar meeting entry")
struct SidebarMeetingEntryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, startsIn: TimeInterval, title: String = "PVT weekly call",
                       url: String? = "https://meet.google.com/abc-defg-hij", allDay: Bool = false) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id, title: title, startDate: now.addingTimeInterval(startsIn),
            endDate: now.addingTimeInterval(startsIn + 3_600), isAllDay: allDay, source: .eventKit,
            meetingURL: url.flatMap(URL.init(string:))
        )
    }

    private func entry(
        _ events: [UnifiedCalendarEvent] = [], hidden: Set<String> = [], call: DetectedCallState? = nil,
        busy: Bool = false, keys: Set<String> = [], all: Bool = false
    ) -> SidebarMeetingEntry? {
        SidebarMeetingEntryPolicy.entry(
            events: events, hiddenEventIDs: hidden, detectedCall: call, isRecordingOrStarting: busy,
            autoJoinEventKeys: keys, autoJoinAllMeetings: all, now: now
        )
    }

    @Test("the next event shows from 15 minutes before it starts")
    func upcomingWindow() {
        #expect(entry([event("a", startsIn: 899)]) != nil)
        #expect(entry([event("a", startsIn: 901)]) == nil)
    }

    @Test("an event that has started, an all-day event and a hidden one never show")
    func ineligible() {
        #expect(entry([event("a", startsIn: -1)]) == nil)
        #expect(entry([event("a", startsIn: 60, allDay: true)]) == nil)
        #expect(entry([event("a", startsIn: 60)], hidden: ["a"]) == nil)
    }

    @Test("the nearest event wins")
    func nearest() {
        guard case .upcoming(let upcoming) = entry([event("late", startsIn: 600), event("soon", startsIn: 120, title: "Soon")]) else {
            Issue.record("expected an upcoming entry")
            return
        }
        #expect(upcoming.title == "Soon")
    }

    @Test("nothing shows while a meeting is recording or starting, not even a detected call")
    func busy() {
        let call = DetectedCallState(candidateID: "c", title: "Call", eventKey: nil, endsAt: nil, recordsAt: nil)
        #expect(entry([event("a", startsIn: 60)], call: call, busy: true) == nil)
    }

    @Test("a detected call takes the place of the upcoming event")
    func callOverEvent() {
        let call = DetectedCallState(candidateID: "c", title: "PVT weekly call", eventKey: "a|1", endsAt: nil,
                                     recordsAt: now.addingTimeInterval(5))
        guard case .callDetected(let detected) = entry([event("a", startsIn: 60)], call: call) else {
            Issue.record("expected a call entry")
            return
        }
        #expect(detected.title == "PVT weekly call")
    }

    @Test("auto-join follows the global option or the per-event choice")
    func autoJoin() {
        let e = event("a", startsIn: 60)
        let key = SidebarMeetingEntryPolicy.eventKey(id: "a", startDate: e.startDate)
        func autoJoins(_ entry: SidebarMeetingEntry?) -> Bool? {
            if case .upcoming(let u) = entry { return u.autoJoinsAtStart }
            return nil
        }
        #expect(autoJoins(entry([e])) == false)
        #expect(autoJoins(entry([e], keys: [key])) == true)
        #expect(autoJoins(entry([e], all: true)) == true)
        #expect(autoJoins(entry([e], keys: ["other|1"])) == false)
    }

    @Test("the countdown reads minutes and seconds and never goes negative")
    func countdownLabel() {
        guard case .upcoming(let u) = entry([event("a", startsIn: 272)]) else {
            Issue.record("no entry")
            return
        }
        #expect(u.countdownLabel(now: now) == "Starts in 4:32")
        #expect(u.countdownLabel(now: now.addingTimeInterval(272)) == "Starts in 0:00")
        #expect(u.countdownLabel(now: now.addingTimeInterval(400)) == "Starts in 0:00")
    }

    @Test("the join action says Record when the event has no link")
    func joinLabel() {
        guard case .upcoming(let withLink) = entry([event("a", startsIn: 60)]),
              case .upcoming(let without) = entry([event("b", startsIn: 60, url: nil)]) else {
            Issue.record("no entry")
            return
        }
        #expect(withLink.joinActionLabel == "Join & Record")
        #expect(without.joinActionLabel == "Record")
    }

    @Test("a detected call counts down when it records by itself and waits when it does not")
    func callStatus() {
        let counting = DetectedCallEntry(candidateID: "c", title: "T", eventKey: nil, endsAt: nil, recordsAt: now.addingTimeInterval(5))
        let waiting = DetectedCallEntry(candidateID: "c", title: "T", eventKey: nil, endsAt: nil, recordsAt: nil)
        #expect(counting.statusLabel(now: now.addingTimeInterval(1)) == "Call detected, recording in 4 s")
        #expect(waiting.statusLabel(now: now) == "Call detected")
    }
}
