import Foundation
import Testing
@testable import MuesliNativeApp

/// A call the monitor detects is matched to a calendar event, by its room URL when there is one and
/// by time otherwise, and named after the event or after the platform and the clock.
@Suite("Detected call matcher")
struct DetectedCallMatcherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let meetRoom = "https://meet.google.com/abc-defg-hij"
    private let otherMeetRoom = "https://meet.google.com/zzz-yyyy-xxx"
    private let zoomRoom = "https://us02web.zoom.us/j/81234567890?pwd=abc"

    private func event(
        _ id: String, _ title: String, startsIn start: TimeInterval, lasts: TimeInterval = 3_600,
        url: String? = nil, allDay: Bool = false
    ) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id, title: title, startDate: now.addingTimeInterval(start),
            endDate: now.addingTimeInterval(start + lasts), isAllDay: allDay, source: .eventKit,
            meetingURL: url.flatMap(URL.init(string:))
        )
    }

    private func candidate(
        platform: MeetingCandidate.Platform = .googleMeet, url: String? = nil, app: String = "Arc"
    ) -> MeetingCandidate {
        let normalized = url.flatMap(MeetingURLNormalizer.normalize)
        return MeetingCandidate(
            id: normalized?.id ?? "meeting-session:browser:company.thebrowser.Browser:media:1",
            platform: platform, appName: app, url: normalized?.url,
            evidence: [.audioInputProcess], startedAt: now, meetingTitle: nil,
            sourceBundleID: "company.thebrowser.Browser"
        )
    }

    @Test("the room URL picks the event, even when another event is closer in time")
    func roomURLWins() {
        let events = [
            event("near", "Standup", startsIn: -300, url: otherMeetRoom),
            event("room", "PVT weekly call", startsIn: 300, url: meetRoom),
        ]
        #expect(DetectedCallMatcher.event(for: candidate(url: meetRoom), in: events, now: now)?.id == "room")
    }

    @Test("a call joined 5 minutes before the start matches that event when the call has no URL")
    func startsInFiveMinutes() {
        let events = [event("pvt", "PVT weekly call", startsIn: 300, url: meetRoom)]
        #expect(DetectedCallMatcher.event(for: candidate(), in: events, now: now)?.id == "pvt")
    }

    @Test("a call that is running matches the event in progress")
    func inProgress() {
        let events = [event("pvt", "PVT weekly call", startsIn: -900)]
        #expect(DetectedCallMatcher.event(for: candidate(), in: events, now: now)?.id == "pvt")
    }

    @Test("an event far in the future, an ended one and an all-day one do not match")
    func outsideTheWindow() {
        let events = [
            event("later", "Later", startsIn: 3_600),
            event("ended", "Ended", startsIn: -7_200, lasts: 3_600),
            event("allday", "Out of office", startsIn: -3_600, lasts: 86_400, allDay: true),
        ]
        #expect(DetectedCallMatcher.event(for: candidate(), in: events, now: now) == nil)
    }

    @Test("a call that runs a few minutes past the scheduled end still matches")
    func overrun() {
        let events = [event("pvt", "PVT weekly call", startsIn: -3_900, lasts: 3_600)]
        #expect(DetectedCallMatcher.event(for: candidate(), in: events, now: now)?.id == "pvt")
    }

    @Test("a different room never matches, however close the event is")
    func conflictingRoom() {
        let events = [event("pvt", "PVT weekly call", startsIn: 300, url: otherMeetRoom)]
        #expect(DetectedCallMatcher.event(for: candidate(url: meetRoom), in: events, now: now) == nil)
    }

    @Test("a different platform never matches")
    func conflictingPlatform() {
        let events = [event("zoom", "Zoom sync", startsIn: 300, url: zoomRoom)]
        #expect(DetectedCallMatcher.event(for: candidate(platform: .googleMeet), in: events, now: now) == nil)
    }

    @Test("an event without a link matches by time on any platform")
    func eventWithoutLink() {
        let events = [event("lunch", "Samuel / Quentin", startsIn: 120)]
        #expect(DetectedCallMatcher.event(for: candidate(platform: .zoom), in: events, now: now)?.id == "lunch")
    }

    @Test("with two candidates by time, the one that carries a link and starts nearest wins")
    func prefersLinkThenNearest() {
        let events = [
            event("plain", "Plain", startsIn: 60),
            event("far", "Far link", startsIn: 540, url: meetRoom),
            event("near", "Near link", startsIn: 240, url: meetRoom),
        ]
        #expect(DetectedCallMatcher.event(for: candidate(), in: events, now: now)?.id == "near")
    }

    @Test("a recurring room matches the occurrence around now, not last week's")
    func recurringRoom() {
        let events = [
            event("last-week", "PVT weekly call", startsIn: -604_800, url: meetRoom),
            event("this-week", "PVT weekly call", startsIn: 300, url: meetRoom),
        ]
        #expect(DetectedCallMatcher.event(for: candidate(url: meetRoom), in: events, now: now)?.id == "this-week")
    }

    @Test("the title is the event's, trimmed")
    func titleFromEvent() {
        let e = event("pvt", "  PVT weekly call ", startsIn: 300)
        #expect(DetectedCallMatcher.title(for: candidate(), event: e, now: now) == "PVT weekly call")
    }

    @Test("without an event the title is the platform and the time")
    func generatedTitle() {
        let utc = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let at = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        #expect(DetectedCallMatcher.title(for: candidate(), event: nil, now: at, timeZone: utc, locale: us) == "Google Meet call, 8:00 AM")
    }

    @Test("an unknown platform is named after the app")
    func generatedTitleUnknownPlatform() {
        let utc = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let unknown = candidate(platform: .unknown, app: "Arc")
        #expect(DetectedCallMatcher.title(for: unknown, event: nil, now: now, timeZone: utc, locale: us) == "Arc call, 8:00 AM")
    }

    @Test("an event with a blank title falls back to the generated name")
    func blankEventTitle() {
        let utc = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let e = event("x", "   ", startsIn: 60)
        #expect(DetectedCallMatcher.title(for: candidate(), event: e, now: now, timeZone: utc, locale: us) == "Google Meet call, 8:00 AM")
    }
}
