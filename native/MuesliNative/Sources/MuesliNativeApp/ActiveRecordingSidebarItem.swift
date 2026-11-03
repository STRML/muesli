import SwiftUI

/// The sidebar entry shown above Timeline while a meeting is recording. It links to the live meeting.
struct ActiveRecordingSidebarItem: Equatable {
    let meetingID: Int64
    let title: String
    let isPaused: Bool
    /// The call this recording followed has gone away. The item turns into a stop prompt.
    let isCallEnded: Bool

    var statusLabel: String {
        if isCallEnded { return "Call ended?" }
        return isPaused ? "Paused" : "Recording"
    }
    var stopActionLabel: String? { isCallEnded ? "Stop" : nil }
    var isPulsing: Bool { isCallEnded || !isPaused }
    var accessibilityLabel: String {
        "\(statusLabel)\(stopActionLabel.map { " \($0)" } ?? ""): \(title)"
    }

    var helpText: String {
        isCallEnded ? "\(accessibilityLabel). Click to open the meeting." : "\(statusLabel): \(title)"
    }

    static func make(
        activeMeetingID: Int64?,
        isPaused: Bool,
        isCallEnded: Bool = false,
        titleFor: (Int64) -> String?
    ) -> ActiveRecordingSidebarItem? {
        guard let activeMeetingID else { return nil }
        let title = titleFor(activeMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ActiveRecordingSidebarItem(
            meetingID: activeMeetingID,
            title: title.isEmpty ? "Meeting" : title,
            isPaused: isPaused,
            isCallEnded: isCallEnded
        )
    }
}

/// A dot that pulses while recording and sits still when paused. Red for a recording, amber for
/// a call-ended prompt.
struct RecordingPulseDot: View {
    let isPulsing: Bool
    var color: Color = MuesliTheme.recording
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(isPulsing && dim ? 0.35 : 1)
            .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = isPulsing }
            .onChange(of: isPulsing) { _, pulsing in dim = pulsing }
    }
}
