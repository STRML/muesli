import Foundation

enum LiveCalendarEventAction: Equatable {
    case joinAndTranscribe
    case transcribe
}

/// Which buttons Coming Up shows beside an event that is happening now, so starting a meeting never
/// depends on catching the notification toast.
enum LiveCalendarEventActions {
    /// Buttons appear this long before the scheduled start.
    static let leadTime: TimeInterval = 5 * 60

    static func visibleActions(
        start: Date,
        end: Date,
        now: Date,
        hasMeetingURL: Bool,
        isRecordingBusy: Bool
    ) -> [LiveCalendarEventAction] {
        guard !isRecordingBusy, start < end else { return [] }
        guard now >= start.addingTimeInterval(-leadTime), now < end else { return [] }
        return hasMeetingURL ? [.joinAndTranscribe, .transcribe] : [.transcribe]
    }
}
