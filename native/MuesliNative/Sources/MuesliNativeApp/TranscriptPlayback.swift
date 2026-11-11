import Foundation

extension Notification.Name {
    /// Posted with the recording path (String) as object and `["seconds": TimeInterval]`.
    static let meetingRecordingSeekRequested = Notification.Name("MuesliMeetingRecordingSeekRequested")
}

/// Maps a transcript line's `HH:mm:ss` stamp to a position in the saved recording.
/// Live meetings stamp wall-clock time; imports and re-transcriptions stamp from midnight.
struct TranscriptPlayback {
    private let anchor: Int
    private let duration: TimeInterval

    private static let secondsPerDay = 86_400

    /// Nil when the first stamp fits neither convention, so no line gets a play button.
    init?(firstTimestamp: String?, meetingStartTime: String, duration: TimeInterval, calendar: Calendar = .current) {
        guard duration > 0, let first = Self.secondsOfDay(firstTimestamp) else { return nil }
        self.duration = duration
        if let start = Self.startSecondsOfDay(meetingStartTime, calendar: calendar),
           Double(Self.wrapped(first - start)) <= duration {
            anchor = start
        } else if Double(first) <= duration {
            anchor = 0
        } else {
            return nil
        }
    }

    func offset(of timestamp: String?) -> TimeInterval? {
        guard let seconds = Self.secondsOfDay(timestamp) else { return nil }
        let offset = TimeInterval(Self.wrapped(seconds - anchor))
        return offset <= duration ? offset : nil
    }

    /// A seek request is honored only inside the recording, which a resumed meeting may cover in part.
    static func seekTarget(seconds: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard seconds >= 0, seconds <= duration else { return nil }
        return seconds
    }

    static func secondsOfDay(_ timestamp: String?) -> Int? {
        guard let timestamp else { return nil }
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]),
              (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds)
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func startSecondsOfDay(_ iso: String, calendar: Calendar) -> Int? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
        return hour * 3600 + minute * 60 + second
    }

    private static func wrapped(_ seconds: Int) -> Int {
        ((seconds % secondsPerDay) + secondsPerDay) % secondsPerDay
    }
}
