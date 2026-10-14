import Foundation

enum LiveCalendarEventAction: Equatable {
    case joinAndTranscribe
    case transcribe
    /// Stop the recording that is still running, then start this event.
    case switchAndJoin
    case switchAndTranscribe
}

/// What the app is recording, from the point of view of one calendar event.
enum LiveRecordingContext: Equatable {
    case idle
    case starting
    case recordingThisEvent
    case recordingOtherMeeting

    static func make(isRecording: Bool, isStarting: Bool, activeIsThisEvent: Bool) -> LiveRecordingContext {
        if isStarting { return .starting }
        guard isRecording else { return .idle }
        return activeIsThisEvent ? .recordingThisEvent : .recordingOtherMeeting
    }
}

/// Which buttons Coming Up shows beside an event that is happening now, so starting a meeting never
/// depends on catching the notification toast, and a recording that is still running from an earlier
/// meeting cannot silently swallow the next one.
enum LiveCalendarEventActions {
    /// Buttons appear this long before the scheduled start.
    static let leadTime: TimeInterval = 5 * 60

    static func visibleActions(
        start: Date,
        end: Date,
        now: Date,
        hasMeetingURL: Bool,
        recording: LiveRecordingContext
    ) -> [LiveCalendarEventAction] {
        guard start < end, now >= start.addingTimeInterval(-leadTime), now < end else { return [] }
        switch recording {
        case .starting, .recordingThisEvent:
            return []
        case .idle:
            return hasMeetingURL ? [.joinAndTranscribe, .transcribe] : [.transcribe]
        case .recordingOtherMeeting:
            return hasMeetingURL ? [.switchAndJoin, .switchAndTranscribe] : [.switchAndTranscribe]
        }
    }
}
