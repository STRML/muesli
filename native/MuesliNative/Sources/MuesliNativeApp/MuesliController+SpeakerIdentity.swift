import Foundation
import MuesliCore

extension Notification.Name {
    /// Posted with the meeting ID (Int64) as object, or nil when profiles changed globally.
    static let meetingSpeakersDidChange = Notification.Name("MuesliMeetingSpeakersDidChange")
}

/// Named speakers. All database work runs off the main actor. Logs carry counts only:
/// never names, labels, or vectors.
extension MuesliController {
    /// Called by `MeetingSession` after diarization. Private meetings (failing closed)
    /// record matches locally but never get names rendered into their transcript.
    func resolveMeetingSpeakers(meetingID: Int64, observations: [MeetingSpeakerObservation]) async -> [String: String] {
        let renderNames = !isMeetingPrivateFailingClosed(id: meetingID)
        let databaseURL = speakerIdentityDatabaseURL
        do {
            let names = try await Task.detached(priority: .userInitiated) {
                try DictationStore(databaseURL: databaseURL).recordMeetingSpeakers(
                    meetingID: meetingID, observations: observations, renderNames: renderNames
                )
            }.value
            fputs("[speakers] meeting \(meetingID): \(observations.count) speakers, \(names.count) recognized\n", stderr)
            return await nameFromCallRoster(meetingID: meetingID, observations: observations, recognized: names, renderNames: renderNames)
        } catch {
            fputs("[speakers] meeting \(meetingID): could not record speakers\n", stderr)
            return [:]
        }
    }

    /// When one speaker and one name from the call are left unmatched, they are the same person.
    /// Any other count stays "Speaker N": the Speakers popover offers the call's names instead.
    private func nameFromCallRoster(
        meetingID: Int64,
        observations: [MeetingSpeakerObservation],
        recognized: [String: String],
        renderNames: Bool
    ) async -> [String: String] {
        guard renderNames, let assignment = CallRosterNaming.assignment(
            unnamedLabels: observations.map(\.label).filter { recognized[$0] == nil },
            rosterNames: callRosterNames(for: meetingID),
            namedAlready: Set(recognized.values.map(CallRosterParser.normalized)),
            selfNames: Self.callRosterSelfNames
        ) else { return recognized }
        guard let result = try? await onSpeakerStore({
            try $0.assignSpeaker(meetingID: meetingID, label: assignment.label, name: assignment.name)
        }) else { return recognized }
        fputs("[speakers] meeting \(meetingID): 1 speaker named from the call roster\n", stderr)
        var resolved = recognized
        resolved[assignment.label] = result.profileName
        return resolved
    }

    func meetingSpeakers(meetingID: Int64) async throws -> [MeetingSpeaker] {
        try await onSpeakerStore { try $0.meetingSpeakers(meetingID: meetingID) }
    }

    func speakerProfiles() async throws -> [SpeakerProfileSummary] {
        try await onSpeakerStore { try $0.speakerProfiles() }
    }

    @discardableResult
    func assignMeetingSpeaker(meetingID: Int64, label: String, name: String) async throws -> SpeakerAssignmentResult {
        let result = try await onSpeakerStore { try $0.assignSpeaker(meetingID: meetingID, label: label, name: name) }
        if result.transcriptRewritten { speakerIdentityDidRewriteTranscript() }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: meetingID)
        return result
    }

    func forgetSpeakerVoiceprints(profileID: Int64, sourceMeetingID: Int64?) async throws {
        try await onSpeakerStore { try $0.forgetVoiceprints(profileID: profileID, sourceMeetingID: sourceMeetingID) }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: nil)
    }

    func deleteSpeakerProfile(id: Int64) async throws {
        try await onSpeakerStore { try $0.deleteSpeakerProfile(id: id) }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: nil)
    }

    private func onSpeakerStore<T: Sendable>(_ operation: @escaping @Sendable (DictationStore) throws -> T) async throws -> T {
        let databaseURL = speakerIdentityDatabaseURL
        return try await Task.detached(priority: .userInitiated) {
            try operation(DictationStore(databaseURL: databaseURL))
        }.value
    }
}
