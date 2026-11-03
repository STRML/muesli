import Foundation
import MuesliCore

/// One committed chunk, split into the durable checkpoint rows and the lines the
/// Live tab shows. They differ only in the speaker label: checkpoints feed crash
/// recovery, which has no final diarization pass, so they never carry provisional
/// labels.
enum LiveMeetingTranscriptLines {
    struct Output: Equatable {
        let checkpointEntries: [LiveTranscriptCheckpointEntry]
        let displayLines: [String]
    }

    /// `displaySpeakers`, when present, holds one label per segment (blank
    /// segments included); a missing entry falls back to `speaker`.
    static func make(
        segments: [SpeechSegment],
        speaker: String,
        displaySpeakers: [String]?,
        meetingStart: Date
    ) -> Output {
        let calendar = Calendar(identifier: .gregorian)
        var entries: [LiveTranscriptCheckpointEntry] = []
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let components = calendar.dateComponents(
                [.hour, .minute, .second], from: meetingStart.addingTimeInterval(segment.start)
            )
            let timestamp = String(
                format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0
            )
            entries.append(LiveTranscriptCheckpointEntry(
                timestampLabel: timestamp,
                speaker: speaker,
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: text
            ))
            let shown = displaySpeakers.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? speaker
            lines.append("[\(timestamp)] \(shown): \(text)")
        }
        return Output(checkpointEntries: entries, displayLines: lines)
    }
}
