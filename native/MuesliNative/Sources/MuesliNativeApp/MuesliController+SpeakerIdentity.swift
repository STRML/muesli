import FluidAudio
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
    func resolveMeetingSpeakers(
        meetingID: Int64,
        observations: [MeetingSpeakerObservation],
        preservingExisting: Bool = false
    ) async -> [String: String] {
        let renderNames = !isMeetingPrivateFailingClosed(id: meetingID)
        let databaseURL = speakerIdentityDatabaseURL
        do {
            let names = try await Task.detached(priority: .userInitiated) {
                try DictationStore(databaseURL: databaseURL).recordMeetingSpeakers(
                    meetingID: meetingID,
                    observations: observations,
                    renderNames: renderNames,
                    preservingExisting: preservingExisting
                )
            }.value
            fputs("[speakers] meeting \(meetingID): \(observations.count) speakers, \(names.count) recognized\n", stderr)
            let resolved = await nameFromCallRoster(meetingID: meetingID, observations: observations, recognized: names, renderNames: renderNames)
            NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: meetingID)
            return resolved
        } catch {
            fputs("[speakers] meeting \(meetingID): could not record speakers\n", stderr)
            return [:]
        }
    }

    @discardableResult
    func recordAndApplyPostDiarizationSpeakers(
        meetingID: Int64,
        segments: [TimedSpeakerSegment],
        speakerCentroids: [String: [Float]],
        existingTranscript: String
    ) async -> String {
        let observations = SpeakerCentroidBuilder.observations(from: segments, speakerEmbeddings: speakerCentroids)
        guard !observations.isEmpty else { return existingTranscript }
        let resolvedNames = await resolveMeetingSpeakers(meetingID: meetingID, observations: observations)
        guard !resolvedNames.isEmpty else { return existingTranscript }

        var rewritten = existingTranscript
        for (sourceLabel, targetName) in resolvedNames where sourceLabel != targetName {
            rewritten = DictationStore.rewriteSpeakerLabel(in: rewritten, from: sourceLabel, to: targetName)
        }
        guard rewritten != existingTranscript else { return existingTranscript }
        do {
            try await onSpeakerStore {
                try $0.updateMeetingTranscript(id: meetingID, rawTranscript: rewritten)
            }
            speakerIdentityDidRewriteTranscript()
        } catch {
            fputs("[speakers] meeting \(meetingID): could not update transcript labels\n", stderr)
        }
        return rewritten
    }

    /// Refreshes saved speaker profiles and meeting participants off the main actor
    /// and syncs active participants into `appState.liveMeetingSpeakerStore`.
    func refreshLiveSpeakerDirectory(meetingID: Int64?) {
        let expectedMeetingID = meetingID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let profiles = (try? await self.speakerProfiles()) ?? []
            self.appState.liveSpeakerProfiles = profiles
            guard let expectedMeetingID else {
                if self.activeMeetingID == nil {
                    self.appState.liveMeetingParticipants = []
                }
                return
            }
            let participants = (try? await self.meetingParticipants(meetingID: expectedMeetingID)) ?? []
            guard self.activeMeetingID == expectedMeetingID || self.appState.liveMeetingTranscriptOwnerID == expectedMeetingID else {
                return
            }
            self.appState.liveMeetingParticipants = participants
            self.appState.liveMeetingSpeakerStore.syncParticipants(participants)
        }
    }

    func addLiveSpeaker(name: String, profileID: Int64? = nil, participantIdentifier: String? = nil) {
        guard let entry = try? appState.liveMeetingSpeakerStore.addSpeaker(
            name: name,
            profileID: profileID,
            participantIdentifier: participantIdentifier
        ) else {
            return
        }
        if entry.profileID == nil {
            persistLiveSpeakerProfileIfNeeded(displayName: entry.displayName, entryID: entry.id)
        }
    }

    func assignLiveSpeaker(clusterID: String, selection: SpeakerPickerSelection) {
        let target: LiveSpeakerTarget
        if let mergeCluster = selection.mergeClusterLabel {
            let trimmedCluster = mergeCluster.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingID = appState.liveMeetingSpeakerStore.clusterToEntryID[trimmedCluster]
                ?? appState.liveMeetingSpeakerStore.entries.first(where: {
                    $0.clusterIDs.contains(trimmedCluster)
                        || $0.displayName.caseInsensitiveCompare(trimmedCluster) == .orderedSame
                })?.id {
                target = .existingEntry(id: existingID)
            } else {
                target = liveSpeakerTarget(from: selection)
            }
        } else {
            target = liveSpeakerTarget(from: selection)
        }

        guard let entry = try? appState.liveMeetingSpeakerStore.assignCluster(clusterID, to: target) else {
            return
        }
        syncLiveMeetingSpeakerTranscript()
        if entry.profileID == nil && !entry.isGenericCluster {
            persistLiveSpeakerProfileIfNeeded(displayName: entry.displayName, entryID: entry.id)
        }
    }

    func reassignLiveTurn(turnID: UUID, selection: SpeakerPickerSelection) {
        guard let entry = try? appState.liveMeetingSpeakerStore.reassignTurn(
            turnID,
            to: liveSpeakerTarget(from: selection)
        ) else {
            return
        }
        syncLiveMeetingSpeakerTranscript()
        if entry.profileID == nil && !entry.isGenericCluster {
            persistLiveSpeakerProfileIfNeeded(displayName: entry.displayName, entryID: entry.id)
        }
    }

    func renameLiveSpeaker(entryID: String, selection: SpeakerPickerSelection) {
        if let mergeCluster = selection.mergeClusterLabel {
            let trimmedTarget = mergeCluster.trimmingCharacters(in: .whitespacesAndNewlines)
            if let destID = appState.liveMeetingSpeakerStore.clusterToEntryID[trimmedTarget]
                ?? appState.liveMeetingSpeakerStore.entries.first(where: {
                    $0.clusterIDs.contains(trimmedTarget)
                        || $0.displayName.caseInsensitiveCompare(trimmedTarget) == .orderedSame
                })?.id,
               destID != entryID,
               let destEntry = appState.liveMeetingSpeakerStore.entries.first(where: { $0.id == destID }) {
                if !destEntry.isGenericCluster {
                    if let merged = try? appState.liveMeetingSpeakerStore.renameEntry(entryID, to: destEntry.displayName) {
                        syncLiveMeetingSpeakerTranscript()
                        if merged.profileID == nil && !merged.isGenericCluster {
                            persistLiveSpeakerProfileIfNeeded(displayName: merged.displayName, entryID: merged.id)
                        }
                    }
                    return
                }
                if appState.liveMeetingSpeakerStore.mergeEntry(entryID, into: destID) != nil {
                    syncLiveMeetingSpeakerTranscript()
                }
                return
            }
        }

        guard let updated = try? appState.liveMeetingSpeakerStore.renameEntry(entryID, to: selection.name) else {
            return
        }
        appState.liveMeetingSpeakerStore.setEntryMetadata(
            entryID: updated.id,
            profileID: selection.profileID,
            participantIdentifier: selection.participantIdentifier
        )
        syncLiveMeetingSpeakerTranscript()
        let finalEntry = appState.liveMeetingSpeakerStore.entries.first(where: { $0.id == updated.id }) ?? updated
        if finalEntry.profileID == nil && !finalEntry.isGenericCluster {
            persistLiveSpeakerProfileIfNeeded(displayName: finalEntry.displayName, entryID: finalEntry.id)
        }
    }

    func applyLiveSpeakerSelection(clusterID: String?, turnID: UUID?, selection: SpeakerPickerSelection) {
        if selection.scope == .singleTurn, let turnID {
            reassignLiveTurn(turnID: turnID, selection: selection)
        } else if let clusterID, !clusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assignLiveSpeaker(clusterID: clusterID, selection: selection)
        } else if let turnID {
            reassignLiveTurn(turnID: turnID, selection: selection)
        } else {
            addLiveSpeaker(
                name: selection.name,
                profileID: selection.profileID,
                participantIdentifier: selection.participantIdentifier
            )
        }
    }

    func enableLiveSpeakerLabelsQuickAction() {
        updateConfig { $0.enableLiveSpeakerLabels = true }
        if LiveSpeakerModelStore.isDownloaded() {
            if let session = activeMeetingSession {
                session.enableLiveSpeakerLabelsMidMeeting()
                appState.liveDiarizationStatus = session.currentLiveDiarizationStatus()
            } else {
                appState.liveDiarizationStatus = .off
            }
            return
        }

        appState.liveDiarizationStatus = .downloading(progress: nil)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try await LiveSpeakerModelStore.download()
                }.value
                fputs("[muesli-native] live speaker label model downloaded\n", stderr)
                guard let self else { return }
                if let session = self.activeMeetingSession {
                    if self.config.enableLiveSpeakerLabels {
                        session.enableLiveSpeakerLabelsMidMeeting()
                        self.appState.liveDiarizationStatus = session.currentLiveDiarizationStatus()
                    }
                } else {
                    self.appState.liveDiarizationStatus = .off
                }
            } catch {
                fputs("[muesli-native] live speaker label model download failed\n", stderr)
                self?.appState.liveDiarizationStatus = .failed(reason: error.localizedDescription)
            }
        }
    }

    func assignPostCallSpeaker(meetingID: Int64, label: String, selection: SpeakerPickerSelection) async throws {
        let result: SpeakerAssignmentResult
        if let mergeTarget = selection.mergeClusterLabel {
            let trimmedTarget = mergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTarget.isEmpty {
                result = try await onSpeakerStore {
                    try $0.mergeMeetingSpeakerLabels(meetingID: meetingID, sourceLabel: label, targetLabel: trimmedTarget)
                }
            } else {
                result = try await onSpeakerStore {
                    try $0.assignSpeaker(meetingID: meetingID, label: label, name: selection.name, allowMerge: true)
                }
            }
        } else {
            result = try await onSpeakerStore {
                try $0.assignSpeaker(meetingID: meetingID, label: label, name: selection.name, allowMerge: true)
            }
        }
        if result.transcriptRewritten { speakerIdentityDidRewriteTranscript() }
        NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: meetingID)
    }

    private func liveSpeakerTarget(from selection: SpeakerPickerSelection) -> LiveSpeakerTarget {
        if let profileID = selection.profileID {
            return .savedProfile(id: profileID, name: selection.name)
        }
        if let participantIdentifier = selection.participantIdentifier {
            return .participant(identifier: participantIdentifier, name: selection.name)
        }
        if !selection.isNewName,
           let existing = appState.liveMeetingSpeakerStore.entries.first(where: {
               !$0.isGenericCluster && !$0.isSelf &&
               $0.displayName.caseInsensitiveCompare(selection.name) == .orderedSame
           }) {
            return .existingEntry(id: existing.id)
        }
        return .newName(selection.name)
    }

    private func persistLiveSpeakerProfileIfNeeded(displayName: String, entryID: String) {
        let generation = liveMeetingTranscriptGeneration
        let ownerID = appState.liveMeetingTranscriptOwnerID
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let profile = try? await self.onSpeakerStore({
                try $0.findOrCreateSpeakerProfile(name: displayName)
            }) else { return }
            if !self.appState.liveSpeakerProfiles.contains(where: { $0.id == profile.id }) {
                self.appState.liveSpeakerProfiles.append(profile)
                self.appState.liveSpeakerProfiles.sort {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            if let ownerID, let generation,
               self.isCurrentLiveMeetingTranscriptSession(ownerID: ownerID, generation: generation) {
                self.appState.liveMeetingSpeakerStore.setEntryMetadata(entryID: entryID, profileID: profile.id)
            }
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

    // MARK: Voiceprint backfill

    func refreshVoiceprintBackfillEligibility() {
        voiceprintBackfillEligibilityTask?.cancel()
        let databaseURL = speakerIdentityDatabaseURL
        voiceprintBackfillEligibilityTask = Task { @MainActor [weak self] in
            do {
                let count = try await Task.detached(priority: .utility) {
                    try DictationStore(databaseURL: databaseURL).meetingsEligibleForVoiceprintBackfill().count
                }.value
                guard let self, !Task.isCancelled else { return }
                self.appState.voiceprintBackfillEligibleCount = count
            } catch is CancellationError {
                return
            } catch {
                fputs("[speakers] backfill eligibility check failed\n", stderr)
            }
        }
    }

    func startVoiceprintBackfill() {
        if case .running = appState.voiceprintBackfillState { return }
        if voiceprintBackfillTask != nil { return }

        let attemptID = UUID()
        voiceprintBackfillAttemptID = attemptID
        let coordinator = transcriptionCoordinator
        let databaseURL = speakerIdentityDatabaseURL

        appState.voiceprintBackfillState = .running(completed: 0, total: 0, learned: 0, currentTitle: "")

        voiceprintBackfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.voiceprintBackfillAttemptID == attemptID {
                    self.voiceprintBackfillTask = nil
                    self.voiceprintBackfillAttemptID = nil
                }
            }

            do {
                let (candidates, profiles) = try await Task.detached(priority: .userInitiated) {
                    let store = DictationStore(databaseURL: databaseURL)
                    return (try store.meetingsEligibleForVoiceprintBackfill(), try store.speakerProfiles())
                }.value
                try Task.checkCancellation()
                guard self.voiceprintBackfillAttemptID == attemptID else { return }

                guard !candidates.isEmpty else {
                    self.appState.voiceprintBackfillEligibleCount = 0
                    self.appState.voiceprintBackfillState = .finished(learned: 0, scanned: 0)
                    return
                }

                self.appState.voiceprintBackfillState = .running(
                    completed: 0,
                    total: candidates.count,
                    learned: 0,
                    currentTitle: candidates[0].title
                )

                await coordinator.preloadDiarizer(trigger: .retranscription)
                try Task.checkCancellation()
                guard self.voiceprintBackfillAttemptID == attemptID else { return }

                guard let diarizer = await coordinator.getDiarizerManager(),
                      diarizer.isAvailable else {
                    self.appState.voiceprintBackfillState = .failed("Speaker identification model is unavailable.")
                    return
                }

                var totalLearned = 0
                var scanned = 0
                var diarizationFailures = 0
                var lastFailureMessage: String?

                for (index, candidate) in candidates.enumerated() {
                    try Task.checkCancellation()
                    guard self.voiceprintBackfillAttemptID == attemptID else { return }

                    self.appState.voiceprintBackfillState = .running(
                        completed: index,
                        total: candidates.count,
                        learned: totalLearned,
                        currentTitle: candidate.title
                    )

                    let recordingURL = URL(fileURLWithPath: candidate.recordingPath)
                    guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                        scanned += 1
                        continue
                    }

                    do {
                        let diarizationResult = try await coordinator.diarizeRecordedAudioWithCentroids(at: recordingURL)
                        try Task.checkCancellation()
                        guard self.voiceprintBackfillAttemptID == attemptID else { return }

                        let matches = await Task.detached(priority: .userInitiated) {
                            VoiceprintBackfiller.match(
                                candidate: candidate,
                                segments: diarizationResult.segments,
                                speakerCentroids: diarizationResult.speakerCentroids,
                                profiles: profiles
                            )
                        }.value

                        if !matches.isEmpty {
                            let stored = try await Task.detached(priority: .userInitiated) {
                                try DictationStore(databaseURL: databaseURL).applyBackfilledVoiceprints(
                                    meetingID: candidate.meetingID,
                                    matches: matches
                                )
                            }.value
                            totalLearned += stored
                        }
                        scanned += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        diarizationFailures += 1
                        lastFailureMessage = error.localizedDescription
                        fputs("[speakers] backfill meeting \(candidate.meetingID): diarization failed\n", stderr)
                    }
                }

                try Task.checkCancellation()
                guard self.voiceprintBackfillAttemptID == attemptID else { return }

                let (updatedProfiles, remainingEligible) = try await Task.detached(priority: .utility) {
                    let store = DictationStore(databaseURL: databaseURL)
                    return (
                        try store.speakerProfiles(),
                        try store.meetingsEligibleForVoiceprintBackfill().count
                    )
                }.value
                guard self.voiceprintBackfillAttemptID == attemptID else { return }

                self.appState.liveSpeakerProfiles = updatedProfiles
                self.appState.voiceprintBackfillEligibleCount = remainingEligible
                if totalLearned > 0 {
                    NotificationCenter.default.post(name: .meetingSpeakersDidChange, object: nil)
                }

                if scanned == 0, diarizationFailures > 0, let lastFailureMessage {
                    self.appState.voiceprintBackfillState = .failed(lastFailureMessage)
                } else {
                    fputs("[speakers] backfill finished: scanned=\(scanned) learned=\(totalLearned) failed=\(diarizationFailures)\n", stderr)
                    self.appState.voiceprintBackfillState = .finished(learned: totalLearned, scanned: scanned)
                }
            } catch is CancellationError {
                guard self.voiceprintBackfillAttemptID == attemptID else { return }
                self.appState.voiceprintBackfillState = .idle
                self.refreshVoiceprintBackfillEligibility()
            } catch {
                guard self.voiceprintBackfillAttemptID == attemptID else { return }
                fputs("[speakers] backfill failed\n", stderr)
                self.appState.voiceprintBackfillState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelVoiceprintBackfill() {
        let wasRunning = voiceprintBackfillTask != nil
        voiceprintBackfillAttemptID = nil
        voiceprintBackfillTask?.cancel()
        voiceprintBackfillTask = nil
        if case .running = appState.voiceprintBackfillState {
            appState.voiceprintBackfillState = .idle
        }
        refreshVoiceprintBackfillEligibility()
        if wasRunning {
            refreshLiveSpeakerDirectory(meetingID: activeMeetingID)
        }
    }

    // MARK: Live voiceprint recognition

    func prepareLiveVoiceprintRecognition(
        meetingID: Int64,
        generation: UUID,
        session: MeetingSession
    ) {
        liveVoiceprintSessionState?.task?.cancel()
        let coordinator = transcriptionCoordinator
        let audioBuffer = session.voiceprintAudioBuffer
        let extractor = FluidAudioLiveVoiceprintExtractor { [weak coordinator] samples in
            await coordinator?.diarizeLiveVoiceprintClip(samples)
        }
        let voiceprintCoordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            sliceAudio: { [weak audioBuffer] intervals in
                audioBuffer?.slice(intervals: intervals)
            }
        )
        liveVoiceprintSessionState = (
            ownerID: meetingID,
            generation: generation,
            coordinator: voiceprintCoordinator,
            task: nil
        )
    }

    func resetLiveVoiceprintRecognition() {
        liveVoiceprintSessionState?.task?.cancel()
        liveVoiceprintSessionState = nil
    }

    func scheduleLiveVoiceprintRecognition(meetingID: Int64, generation: UUID) {
        guard isCurrentLiveMeetingTranscriptSession(ownerID: meetingID, generation: generation),
              !isMeetingPrivateFailingClosed(id: meetingID),
              let state = liveVoiceprintSessionState,
              state.ownerID == meetingID,
              state.generation == generation,
              state.task == nil else {
            return
        }
        let storeSnapshot = appState.liveMeetingSpeakerStore
        guard !storeSnapshot.unnamedLiveClustersEligibleForVoiceprint(
            minimumSeconds: LiveVoiceprintCoordinator.defaultMinimumFirstAttemptSeconds
        ).isEmpty else {
            return
        }

        let databaseURL = speakerIdentityDatabaseURL
        let voiceprintCoordinator = state.coordinator
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let current = self.liveVoiceprintSessionState,
                   current.ownerID == meetingID,
                   current.generation == generation {
                    self.liveVoiceprintSessionState?.task = nil
                }
            }

            let savedProfiles: [LiveVoiceprintProfile]
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try DictationStore(databaseURL: databaseURL).savedVoiceprintProfiles()
                }.value
                savedProfiles = loaded.map {
                    LiveVoiceprintProfile(id: $0.id, name: $0.name, voiceprints: $0.voiceprints)
                }
            } catch {
                fputs("[speakers] live voiceprint profile load failed\n", stderr)
                return
            }

            guard !Task.isCancelled,
                  !savedProfiles.isEmpty,
                  self.isCurrentLiveMeetingTranscriptSession(ownerID: meetingID, generation: generation),
                  !self.isMeetingPrivateFailingClosed(id: meetingID) else {
                return
            }

            let matches = await voiceprintCoordinator.evaluate(
                store: storeSnapshot,
                profiles: savedProfiles,
                isPrivate: false
            )
            guard !Task.isCancelled,
                  !matches.isEmpty,
                  self.isCurrentLiveMeetingTranscriptSession(ownerID: meetingID, generation: generation),
                  !self.isMeetingPrivateFailingClosed(id: meetingID) else {
                return
            }

            var appliedCount = 0
            for match in matches {
                if self.appState.liveMeetingSpeakerStore.autoAssignCluster(
                    match.clusterID,
                    profileID: match.profileID,
                    name: match.name
                ) {
                    appliedCount += 1
                }
            }
            if appliedCount > 0 {
                fputs("[speakers] meeting \(meetingID): live voiceprint matched \(appliedCount) cluster(s)\n", stderr)
                self.syncLiveMeetingSpeakerTranscript()
                if let session = self.activeMeetingSession {
                    self.appState.liveDiarizationStatus = session.currentLiveDiarizationStatus()
                }
            }
        }
        liveVoiceprintSessionState?.task = task
    }

    private func onSpeakerStore<T: Sendable>(_ operation: @escaping @Sendable (DictationStore) throws -> T) async throws -> T {
        let databaseURL = speakerIdentityDatabaseURL
        return try await Task.detached(priority: .userInitiated) {
            try operation(DictationStore(databaseURL: databaseURL))
        }.value
    }
}
