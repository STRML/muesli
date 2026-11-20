import Foundation
import MuesliCore

/// One committed chunk, split into the durable checkpoint rows, structured live turn
/// drafts, and the lines the Live tab shows. Checkpoints feed crash recovery, which has
/// no final diarization pass, so they never carry provisional `Speaker N` labels (and
/// private meetings keep raw source labels only).
enum LiveMeetingTranscriptLines {
    struct TurnDraft: Equatable, Sendable {
        let source: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let timestampLabel: String
        let liveClusterID: String?
        let text: String
    }

    struct Output: Equatable {
        let checkpointEntries: [LiveTranscriptCheckpointEntry]
        let displayLines: [String]
        let turnDrafts: [TurnDraft]
    }

    /// `displaySpeakers`, when present, holds one label per segment (blank
    /// segments included); a missing entry falls back to `speaker`.
    static func make(
        segments: [SpeechSegment],
        speaker: String,
        displaySpeakers: [String]?,
        meetingStart: Date,
        resolvedNamedSpeakers: [String: String] = [:],
        isPrivate: Bool = false
    ) -> Output {
        let calendar = Calendar(identifier: .gregorian)
        var entries: [LiveTranscriptCheckpointEntry] = []
        var lines: [String] = []
        var turnDrafts: [TurnDraft] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let components = calendar.dateComponents(
                [.hour, .minute, .second], from: meetingStart.addingTimeInterval(segment.start)
            )
            let timestamp = String(
                format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0
            )
            let clusterLabel = displaySpeakers.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            let checkpointSpeaker: String
            if !isPrivate, let clusterLabel, let named = resolvedNamedSpeakers[clusterLabel] {
                checkpointSpeaker = named
            } else if !isPrivate, let named = resolvedNamedSpeakers[speaker] {
                checkpointSpeaker = named
            } else {
                checkpointSpeaker = speaker
            }
            entries.append(LiveTranscriptCheckpointEntry(
                timestampLabel: timestamp,
                speaker: checkpointSpeaker,
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: text
            ))
            let shown = clusterLabel ?? speaker
            lines.append("[\(timestamp)] \(shown): \(text)")
            turnDrafts.append(TurnDraft(
                source: speaker,
                startSeconds: segment.start,
                endSeconds: segment.end,
                timestampLabel: timestamp,
                liveClusterID: clusterLabel,
                text: text
            ))
        }
        return Output(checkpointEntries: entries, displayLines: lines, turnDrafts: turnDrafts)
    }
}
