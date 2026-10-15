import Foundation

/// Ties a detected call to the calendar event it belongs to and names the meeting.
enum DetectedCallMatcher {
    /// An event counts as the call from this long before it starts until it has ended.
    static let earlyJoinWindow: TimeInterval = 10 * 60
    /// A call that runs past the scheduled end still belongs to the event for this long.
    static let lateJoinWindow: TimeInterval = 10 * 60

    /// The event the call belongs to, or nil. A room URL that equals an event's link decides it. Without
    /// one, the call belongs to the event that is on now or about to start, unless the event's link says
    /// it is another room or another platform.
    static func event(
        for candidate: MeetingCandidate,
        in events: [UnifiedCalendarEvent],
        now: Date
    ) -> UnifiedCalendarEvent? {
        let eligible = events.filter { isEligible($0, now: now) }

        if let room = candidate.url,
           let match = eligible
            .filter({ link(of: $0)?.url == room })
            .min(by: { distance($0, now: now) < distance($1, now: now) }) {
            return match
        }

        return eligible
            .filter { !conflicts($0, with: candidate) }
            .min { lhs, rhs in
                let lhsLinked = link(of: lhs) != nil
                let rhsLinked = link(of: rhs) != nil
                if lhsLinked != rhsLinked { return lhsLinked }
                return distance(lhs, now: now) < distance(rhs, now: now)
            }
    }

    /// The event's title, or the platform (the app when the platform is unknown) and the time.
    static func title(
        for candidate: MeetingCandidate,
        event: UnifiedCalendarEvent?,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        if let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let source = candidate.platform == .unknown ? candidate.appName : candidate.platform.displayName
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style.locale = locale
        // Recent ICU puts a narrow no-break space before AM and PM.
        let clock = now.formatted(style).replacingOccurrences(of: "\u{202F}", with: " ")
        return "\(source) call, \(clock)"
    }

    private static func isEligible(_ event: UnifiedCalendarEvent, now: Date) -> Bool {
        !event.isAllDay
            && now >= event.startDate.addingTimeInterval(-earlyJoinWindow)
            && now <= event.endDate.addingTimeInterval(lateJoinWindow)
    }

    private static func distance(_ event: UnifiedCalendarEvent, now: Date) -> TimeInterval {
        abs(event.startDate.timeIntervalSince(now))
    }

    private static func link(of event: UnifiedCalendarEvent) -> NormalizedMeetingURL? {
        event.meetingURL.flatMap { MeetingURLNormalizer.normalize($0.absoluteString) }
    }

    /// The event's link names another room or another platform than the call.
    private static func conflicts(_ event: UnifiedCalendarEvent, with candidate: MeetingCandidate) -> Bool {
        guard let link = link(of: event) else { return false }
        if let room = candidate.url, room != link.url { return true }
        guard candidate.platform != .unknown, link.platform != .unknown else { return false }
        return candidate.platform != link.platform
    }
}
