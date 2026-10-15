import AppKit
import Foundation
import MuesliCore

/// Who is actually on a browser call, read from the call page while it is recorded.
/// Design and failure matrix: docs/call-roster.md.
extension MuesliController {
    private static let firstRosterPassDelay: Duration = .seconds(8)
    private static let rosterPassInterval: Duration = .seconds(30)

    /// Starts sampling when the recording follows a Google Meet room in a browser.
    func startCallRosterSampling(source: MeetingAutoStopSource?) {
        stopCallRosterSampling()
        guard config.readCallParticipants, let source, source.platform == .googleMeet,
              let room = source.normalizedURL else { return }
        callRosterTracker = CallRosterTracker()
        let preferredBundleID = source.sourceBundleID
        callRosterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstRosterPassDelay)
            while !Task.isCancelled {
                await self?.sampleCallRoster(room: room, preferredBundleID: preferredBundleID)
                try? await Task.sleep(for: Self.rosterPassInterval)
            }
        }
    }

    func stopCallRosterSampling() {
        callRosterTask?.cancel()
        callRosterTask = nil
    }

    /// Every name seen on the call so far, for naming speakers when the meeting ends.
    var callRosterNames: [String] { callRosterTracker.seenNames }

    /// The names that stand for the user: they are on the call but are not someone else.
    static var callRosterSelfNames: Set<String> { [NSFullUserName(), NSUserName()] }

    private func sampleCallRoster(room: String, preferredBundleID: String?) async {
        guard config.readCallParticipants, isMeetingRecording(), !isMeetingRecordingPaused(),
              let meetingID = activeMeetingID,
              !isMeetingPrivateFailingClosed(id: meetingID) else { return }

        let pids = browserProcessIDs(preferring: preferredBundleID)
        let nodes = await Task.detached(priority: .utility) { () -> [CallRosterTextNode]? in
            for pid in pids {
                if let nodes = CallRosterReader.read(processIdentifier: pid, roomURL: room) { return nodes }
            }
            return nil
        }.value
        guard let nodes, !Task.isCancelled else { return }

        let existing = ((try? await meetingParticipants(meetingID: meetingID)) ?? []).map(\.displayName)
        let roster = CallRosterParser.names(from: nodes, selfNames: Self.callRosterSelfNames, knownNames: existing)
        let added = callRosterTracker.newNames(roster: roster, existing: existing)
        guard !added.isEmpty else { return }
        for name in added {
            let draft = MeetingParticipantDraft(
                participantIdentifier: "call:\(CallRosterParser.normalized(name))",
                displayName: name
            )
            try? await attachMeetingParticipant(meetingID: meetingID, participant: draft)
        }
        // Counts only: names stay out of the log.
        fputs("[call-roster] meeting \(meetingID): \(added.count) new on the call, \(callRosterTracker.seenNames.count) seen\n", stderr)
        NotificationCenter.default.post(name: .meetingParticipantsDidChange, object: meetingID)
    }

    private func browserProcessIDs(preferring bundleID: String?) -> [pid_t] {
        let browsers = Set(MeetingCandidateResolver.browserApps.keys)
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map(browsers.contains) == true
        }
        let preferred = running.filter { $0.bundleIdentifier == bundleID }
        return (preferred + running.filter { $0.bundleIdentifier != bundleID }).map(\.processIdentifier)
    }
}
