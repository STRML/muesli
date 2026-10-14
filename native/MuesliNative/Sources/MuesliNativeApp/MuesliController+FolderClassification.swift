import Foundation
import MuesliCore

/// Controller entry points for folder suggestions. Classification itself lives in
/// `FolderClassificationCoordinator.swift`; storage in `FolderClassificationStore`.
extension MuesliController {
    var folderClassificationStore: FolderClassificationStore {
        FolderClassificationStore(databaseURL: folderClassificationRunner.classifier.databaseURL)
    }

    /// True while a meeting records, starts or stops. Classification never runs then.
    private var folderClassificationRecordingCheck: @MainActor @Sendable () -> Bool {
        { [weak self] in
            guard let self else { return true }
            return self.isMeetingRecording() || self.appState.isMeetingStarting
        }
    }

    /// Every user-initiated move goes through here so suggestions resolve and the
    /// classifier learns from it.
    func moveMeetingAndLearn(id: Int64, toFolder folderID: Int64?) {
        do {
            try folderClassificationStore.moveMeeting(id: id, toFolder: folderID)
        } catch {
            fputs("[folder-classify] move failed meeting=\(id) error=\(type(of: error))\n", stderr)
        }
    }

    func classifyMeetingAfterCompletion(_ meetingID: Int64) {
        folderClassificationRunner.enqueueCompleted(
            meetingID: meetingID,
            config: config,
            isRecording: folderClassificationRecordingCheck
        )
    }

    func classifyUnfiledMeetings() {
        guard !appState.isClassifyingUnfiledMeetings else { return }
        appState.isClassifyingUnfiledMeetings = true
        let config = config
        Task { [weak self] in
            guard let self else { return }
            await self.folderClassificationRunner.classifyUnfiled(config: config, isRecording: self.folderClassificationRecordingCheck)
            self.appState.isClassifyingUnfiledMeetings = false
            self.syncAppState()
        }
    }

    func cancelClassifyUnfiledMeetings() {
        folderClassificationRunner.cancelBatch()
    }

    /// Reads pending suggestions and lets queued post-meeting classification resume.
    func refreshFolderSuggestionInbox() {
        appState.folderSuggestionRows = (try? folderClassificationStore.pendingSuggestions()) ?? []
        folderClassificationRunner.drainQueue(config: config, isRecording: folderClassificationRecordingCheck)
    }

    func showFolderInbox() {
        appState.meetingChatDocumentTarget = nil
        appState.selectedTab = .meetings
        appState.selectedFolderID = nil
        appState.selectedMeetingID = nil
        appState.meetingsNavigationState = .browser
        syncAppState()
        appState.isFolderInboxSelected = true
    }

    func acceptFolderSuggestion(_ suggestion: FolderSuggestion) {
        guard (try? folderClassificationStore.suggestion(id: suggestion.id))?.state == .pending else { return }
        moveMeeting(id: suggestion.meetingID, toFolder: suggestion.folderID)
    }

    func dismissFolderSuggestion(_ suggestion: FolderSuggestion) {
        try? folderClassificationStore.dismissSuggestion(id: suggestion.id)
        syncAppState()
    }
}
