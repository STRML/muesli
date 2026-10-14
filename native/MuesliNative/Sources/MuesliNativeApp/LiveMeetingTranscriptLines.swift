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

    static func make(
        segments: [SpeechSegment],
        speaker: String,
        displaySpeakers: [String]?,
        meetingStart: Date
    ) -> Output {
        Output(checkpointEntries: [], displayLines: [])
    }
}
