import SwiftUI

/// The sidebar entry shown above Timeline while a meeting is recording. It links to the live meeting.
struct ActiveRecordingSidebarItem: Equatable {
    let meetingID: Int64
    let title: String
    let isPaused: Bool

    var statusLabel: String { isPaused ? "Paused" : "Recording" }
    var isPulsing: Bool { !isPaused }

    static func make(
        activeMeetingID: Int64?,
        isPaused: Bool,
        titleFor: (Int64) -> String?
    ) -> ActiveRecordingSidebarItem? {
        guard let activeMeetingID else { return nil }
        let title = titleFor(activeMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ActiveRecordingSidebarItem(
            meetingID: activeMeetingID,
            title: title.isEmpty ? "Meeting" : title,
            isPaused: isPaused
        )
    }
}

/// A red dot that pulses while recording and sits still when paused.
struct RecordingPulseDot: View {
    let isPulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(MuesliTheme.recording)
            .frame(width: 9, height: 9)
            .opacity(isPulsing && dim ? 0.35 : 1)
            .animation(isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = isPulsing }
            .onChange(of: isPulsing) { _, pulsing in dim = pulsing }
    }
}
