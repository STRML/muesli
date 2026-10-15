import Foundation

/// What the sidebar shows above Timeline when no meeting is recording: the next calendar event
/// (from 15 minutes before it starts) or a call the monitor detected.
enum SidebarMeetingEntry: Equatable {
    case upcoming(UpcomingMeetingEntry)
    case callDetected(DetectedCallEntry)
}

struct UpcomingMeetingEntry: Equatable {
    /// Event id and start, the identity a per-event "auto-join" choice is kept under.
    let eventKey: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let meetingURL: URL?
    let autoJoinsAtStart: Bool

    /// "Starts in 4:32". The window is 15 minutes, so minutes and seconds always fit.
    func countdownLabel(now: Date) -> String {
        let remaining = max(0, Int(startsAt.timeIntervalSince(now).rounded(.up)))
        return "Starts in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }

    var joinActionLabel: String { meetingURL == nil ? "Record" : "Join & Record" }
}

struct DetectedCallEntry: Equatable {
    let candidateID: String
    let title: String
    /// The calendar event the call was matched to, when it was.
    let eventKey: String?
    let endsAt: Date?
    /// When transcription starts by itself. Nil when the user has to start it.
    let recordsAt: Date?

    func statusLabel(now: Date) -> String {
        guard let recordsAt else { return "Call detected" }
        let remaining = max(0, Int(recordsAt.timeIntervalSince(now).rounded(.up)))
        return "Call detected, recording in \(remaining) s"
    }
}

/// What the call monitor reports about a call it is following into the sidebar.
struct DetectedCallState: Equatable {
    let candidateID: String
    let title: String
    let eventKey: String?
    let endsAt: Date?
    let recordsAt: Date?
}

enum SidebarMeetingEntryPolicy {
    /// An event shows from this long before it starts.
    static let upcomingWindow: TimeInterval = 15 * 60
    /// A detected call starts transcribing by itself after this long.
    static let detectedCallCountdown: TimeInterval = 5

    /// A start timer can be suspended (menu bar apps nap), so an auto-join still fires for a meeting
    /// that started up to this long ago.
    static let autoJoinGrace: TimeInterval = 120

    /// Events whose auto-join is due now: started within the grace period, still running, joining
    /// switched on for them, and not handled before.
    static func dueAutoJoins(
        events: [UnifiedCalendarEvent],
        hiddenEventIDs: Set<String>,
        autoJoinEventKeys: Set<String>,
        autoJoinAllMeetings: Bool,
        handledEventKeys: Set<String>,
        now: Date
    ) -> [UnifiedCalendarEvent] {
        events
            .filter { event in
                let key = eventKey(id: event.id, startDate: event.startDate)
                return !event.isAllDay && !hiddenEventIDs.contains(event.id)
                    && event.startDate <= now
                    && now.timeIntervalSince(event.startDate) <= autoJoinGrace
                    && event.endDate > now
                    && (autoJoinAllMeetings || autoJoinEventKeys.contains(key))
                    && !handledEventKeys.contains(key)
            }
            .sorted { $0.startDate < $1.startDate }
    }

    static func eventKey(id: String, startDate: Date) -> String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }

    static func entry(
        events: [UnifiedCalendarEvent],
        hiddenEventIDs: Set<String>,
        detectedCall: DetectedCallState?,
        isRecordingOrStarting: Bool,
        autoJoinEventKeys: Set<String>,
        autoJoinAllMeetings: Bool,
        now: Date
    ) -> SidebarMeetingEntry? {
        guard !isRecordingOrStarting else { return nil }
        if let detectedCall {
            return .callDetected(DetectedCallEntry(
                candidateID: detectedCall.candidateID,
                title: detectedCall.title,
                eventKey: detectedCall.eventKey,
                endsAt: detectedCall.endsAt,
                recordsAt: detectedCall.recordsAt
            ))
        }
        let windowEnd = now.addingTimeInterval(upcomingWindow)
        let next = events
            .filter {
                !$0.isAllDay && !hiddenEventIDs.contains($0.id)
                    && $0.startDate > now && $0.startDate <= windowEnd
            }
            .min { $0.startDate < $1.startDate }
        guard let next else { return nil }
        let key = eventKey(id: next.id, startDate: next.startDate)
        return .upcoming(UpcomingMeetingEntry(
            eventKey: key,
            title: next.title.trimmingCharacters(in: .whitespacesAndNewlines),
            startsAt: next.startDate,
            endsAt: next.endDate,
            meetingURL: next.meetingURL,
            autoJoinsAtStart: autoJoinAllMeetings || autoJoinEventKeys.contains(key)
        ))
    }
}
