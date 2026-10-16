import Foundation
import MuesliCore

/// Decides whether a finished meeting may be resumed (reopened to append more
/// recording onto the same meeting row).
///
/// Resume is intentionally age-independent: users may continue transcribing into
/// an older meeting artifact when that is the right product-level grouping.
enum MeetingResumePolicy {
    /// Finalized meetings and ones still processing after Stop can be resumed.
    /// Active, note-only, and failed rows have separate lifecycle actions.
    static func canResume(status: MeetingStatus) -> Bool {
        status == .completed || status == .processing
    }

    enum Availability: Equatable {
        case hidden
        case disabled(reason: String)
        case enabled
    }

    static let retranscriptionDisabledReason =
        "Resume is unavailable while a recording is being re-transcribed. Cancel or wait for it to finish."

    /// What the Resume control does for a row right now. `hasActiveFinalization` is true while the
    /// post-Stop pipeline (transcript finalize, then summary) for this row is still running.
    static func availability(
        status: MeetingStatus,
        isRetranscriptionRunning: Bool,
        isAnotherRecordingActive: Bool,
        hasActiveFinalization: Bool
    ) -> Availability {
        guard !isAnotherRecordingActive, canResume(status: status) else { return .hidden }
        if isRetranscriptionRunning { return .disabled(reason: retranscriptionDisabledReason) }
        if status == .processing && !hasActiveFinalization { return .hidden }
        return .enabled
    }

    /// Summary results land on a row only while it is not being recorded or finalized. A row that
    /// has since been resumed (recording), is mid-finalize, or was deleted keeps whatever it has.
    static func shouldPersistSummary(rowStatus: MeetingStatus?, wasCancelled: Bool) -> Bool {
        !wasCancelled && !isBusyWithRecording(rowStatus)
    }

    /// A summary failure is only worth showing when the row is not being recorded or finalized.
    static func shouldSurfaceSummaryFailure(rowStatus: MeetingStatus?, wasCancelled: Bool) -> Bool {
        !wasCancelled && rowStatus != .recording && rowStatus != .processing
    }

    private static func isBusyWithRecording(_ status: MeetingStatus?) -> Bool {
        status == nil || status == .recording || status == .processing
    }

    /// Whether the resumed stop must run the summary again. New speech always does; so does a
    /// transcript whose summary was cancelled before it ever produced notes.
    static func needsSummaryRegeneration(hasNewContent: Bool, existingNotes: String?, combinedTranscript: String) -> Bool {
        if hasNewContent { return true }
        let notesAreBlank = (existingNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTranscript = !combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return notesAreBlank && hasTranscript
    }

    /// A resumed meeting that began from a calendar event keeps the call-ended warning that a
    /// scheduled start has. Treating every resume as a manual start meant it never warned when the
    /// call ended, so a resumed recording could run on through the next meeting.
    static func startOrigin(hasCalendarEvent: Bool) -> MeetingRecordingStartOrigin {
        hasCalendarEvent ? .scheduledMeetingPrompt : .manual
    }

    /// Separator inserted between the prior transcript and the newly recorded one
    /// when a meeting is resumed (Approach A — concatenate, see the PRD).
    static let resumeSeparator = "\n\n— Resumed —\n\n"

    /// Concatenates the prior transcript with the newly recorded one. If nothing
    /// new was captured (empty/whitespace), the prior transcript is returned
    /// unchanged so a no-op resume never appends a dangling separator.
    static func combinedResumeTranscript(prior: String, new: String) -> String {
        let trimmedPrior = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return prior }
        guard !trimmedPrior.isEmpty else { return new }
        return prior + resumeSeparator + new
    }

    static func hasNewTranscriptContent(prior: String, new: String) -> Bool {
        combinedResumeTranscript(prior: prior, new: new) != prior
    }

    /// Combined visual context is prefix-capped so repeated resumes cannot grow
    /// the stored value without bound (each session's drain is already capped
    /// by MeetingScreenContextCollector).
    static let combinedVisualContextLimit = 20_000

    /// Merges the resumed meeting's stored visual context with the context the
    /// resumed session captured, mirroring combinedResumeTranscript: either
    /// side may be missing, and a no-op side never appends a dangling separator.
    /// At the cap, the oldest prior content is dropped first so the resumed
    /// session's context (the freshest) always survives whole.
    static func combinedResumeVisualContext(prior: String?, new: String?) -> String? {
        let trimmedPrior = prior?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedNew = new?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedNew.isEmpty { return trimmedPrior.isEmpty ? nil : prior }
        guard !trimmedPrior.isEmpty, let prior, let new else { return new }
        return String((prior + resumeSeparator + new).suffix(combinedVisualContextLimit))
    }
}
