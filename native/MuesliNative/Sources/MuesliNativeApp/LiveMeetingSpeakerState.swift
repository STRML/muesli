import Foundation
import MuesliCore

/// Real-time status of live speaker diarization for an active meeting.
enum LiveDiarizationStatus: Equatable, Sendable {
    case off
    case modelNotDownloaded
    case downloading(progress: Double?)
    case loadingModel
    case active(speakerCount: Int)
    case failed(reason: String)
}

/// A speaker identity or provisional diarizer cluster visible in the live meeting UI.
struct LiveSpeakerEntry: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case diarizedCluster
        case savedProfile
        case participant
        case manual
    }

    let id: String
    var displayName: String
    var profileID: Int64?
    var participantIdentifier: String?
    var source: Source
    var clusterIDs: Set<String>
    let isSelf: Bool
    var isGenericCluster: Bool
}

/// One committed live caption segment with timing and speaker resolution metadata.
struct LiveTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let timestampLabel: String
    var liveClusterID: String?
    var explicitSpeakerID: String?
    let text: String
}

/// Target selected by the user in a speaker picker or quick-add flow.
enum LiveSpeakerTarget: Equatable, Sendable {
    case existingEntry(id: String)
    case savedProfile(id: Int64, name: String)
    case participant(identifier: String, name: String)
    case newName(String)
}

struct LiveSpeakerInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

struct LiveSpeakerAssignmentRecord: Equatable, Sendable {
    let clusterID: String
    let targetEntryID: String
    let displayName: String
    let profileID: Int64?
    let intervals: [LiveSpeakerInterval]
}

struct LiveTurnOverrideRecord: Equatable, Sendable {
    let turnID: UUID
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let source: String
    let targetEntryID: String
    let displayName: String
    let profileID: Int64?
}

struct LiveSpeakerReconciliationInput: Equatable, Sendable {
    let turns: [LiveTranscriptTurn]
    let clusterAssignments: [LiveSpeakerAssignmentRecord]
    let turnOverrides: [LiveTurnOverrideRecord]
    let entriesByID: [String: LiveSpeakerEntry]
    let isInPerson: Bool

    var hasExplicitEdits: Bool {
        !clusterAssignments.isEmpty || !turnOverrides.isEmpty
    }
}

/// Canonical, pure value-type state for live speakers and live transcript turns.
/// Stored on `@MainActor` `AppState` for instant UI updates and snapshotted cleanly
/// across actors at meeting stop.
struct LiveMeetingSpeakerStore: Equatable, Sendable {
    static let selfEntryID = "self:You"

    let isInPerson: Bool
    private(set) var entries: [LiveSpeakerEntry]
    private(set) var turns: [LiveTranscriptTurn] = []
    private(set) var clusterToEntryID: [String: String] = [:]

    init(isInPerson: Bool = false) {
        self.isInPerson = isInPerson
        if isInPerson {
            self.entries = []
        } else {
            self.entries = [
                LiveSpeakerEntry(
                    id: Self.selfEntryID,
                    displayName: "You",
                    profileID: nil,
                    participantIdentifier: nil,
                    source: .manual,
                    clusterIDs: ["You"],
                    isSelf: true,
                    isGenericCluster: false
                ),
            ]
            self.clusterToEntryID["You"] = Self.selfEntryID
        }
    }

    /// Active generic or named diarized cluster labels (excluding `"You"`).
    var activeClusterLabels: [String] {
        var labels: [String] = []
        var seen = Set<String>()
        for turn in turns {
            guard !isSelfTurn(turn), let cluster = effectiveClusterID(for: turn) else { continue }
            if seen.insert(cluster).inserted {
                labels.append(cluster)
            }
        }
        return labels
    }

    /// Appends a committed segment to the live turn list, ensuring a cluster entry exists
    /// when a provisional speaker label is present.
    @discardableResult
    mutating func appendTurn(
        id: UUID = UUID(),
        source: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        timestampLabel: String,
        liveClusterID: String?,
        text: String
    ) -> LiveTranscriptTurn? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedCluster: String?
        if source == "You" && !isInPerson {
            normalizedCluster = "You"
        } else if let liveClusterID, !liveClusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanCluster = liveClusterID.trimmingCharacters(in: .whitespacesAndNewlines)
            ensureClusterEntryIfNeeded(clusterID: cleanCluster)
            normalizedCluster = cleanCluster
        } else {
            normalizedCluster = nil
        }

        let turn = LiveTranscriptTurn(
            id: id,
            source: source,
            startSeconds: startSeconds,
            endSeconds: max(endSeconds, startSeconds),
            timestampLabel: timestampLabel,
            liveClusterID: normalizedCluster,
            explicitSpeakerID: nil,
            text: trimmed
        )
        turns.append(turn)
        return turn
    }

    /// Retroactively updates an early turn emitted while the live diarizer was loading
    /// or before its audio range was covered. Never overwrites explicit user overrides or
    /// an already-assigned specific cluster.
    @discardableResult
    mutating func relabelRetroactiveCluster(turnID: UUID, clusterID: String) -> Bool {
        let cleanCluster = clusterID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCluster.isEmpty,
              let index = turns.firstIndex(where: { $0.id == turnID }) else { return false }
        let turn = turns[index]
        guard !isSelfTurn(turn), turn.explicitSpeakerID == nil else { return false }
        if let existing = turn.liveClusterID, existing != LiveSpeakerLabeler.fallbackLabel {
            return false
        }
        guard turn.liveClusterID != cleanCluster else { return false }
        ensureClusterEntryIfNeeded(clusterID: cleanCluster)
        turns[index].liveClusterID = cleanCluster
        return true
    }

    /// Pre-adds or links a speaker mid-call (before or after they speak).
    @discardableResult
    mutating func addSpeaker(
        name rawName: String,
        profileID: Int64? = nil,
        participantIdentifier: String? = nil
    ) throws -> LiveSpeakerEntry {
        let name = try DictationStore.validatedSpeakerName(rawName)
        let source: LiveSpeakerEntry.Source = profileID != nil ? .savedProfile : (participantIdentifier != nil ? .participant : .manual)
        return upsertNamedEntry(
            displayName: name,
            profileID: profileID,
            participantIdentifier: participantIdentifier,
            source: source
        )
    }

    /// Assigns an entire live cluster (e.g. `"Speaker 1"` or `"Others"`) to a target speaker.
    /// Assigning two different clusters to the same target automatically merges them.
    @discardableResult
    mutating func assignCluster(_ clusterID: String, to target: LiveSpeakerTarget) throws -> LiveSpeakerEntry {
        let cleanCluster = clusterID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCluster.isEmpty, cleanCluster.caseInsensitiveCompare("You") != .orderedSame else {
            throw SpeakerIdentityError.reservedLabel
        }
        let targetEntry = try resolveTargetEntry(target)
        guard !targetEntry.isSelf else { throw SpeakerIdentityError.reservedLabel }

        let oldEntryID = clusterToEntryID[cleanCluster]
        if let oldEntryID, oldEntryID != targetEntry.id,
           let oldIndex = entries.firstIndex(where: { $0.id == oldEntryID }) {
            entries[oldIndex].clusterIDs.remove(cleanCluster)
            let wasGeneric = entries[oldIndex].isGenericCluster
            if wasGeneric {
                for index in turns.indices where turns[index].explicitSpeakerID == oldEntryID {
                    turns[index].explicitSpeakerID = targetEntry.id
                }
            }
            if wasGeneric && entries[oldIndex].clusterIDs.isEmpty && !turns.contains(where: { $0.explicitSpeakerID == oldEntryID }) {
                entries.remove(at: oldIndex)
            }
        }

        clusterToEntryID[cleanCluster] = targetEntry.id
        if let targetIndex = entries.firstIndex(where: { $0.id == targetEntry.id }) {
            entries[targetIndex].clusterIDs.insert(cleanCluster)
            return entries[targetIndex]
        }
        return targetEntry
    }

    /// Reassigns only one specific turn without changing other turns in its cluster.
    @discardableResult
    mutating func reassignTurn(_ turnID: UUID, to target: LiveSpeakerTarget) throws -> LiveSpeakerEntry {
        guard let turnIndex = turns.firstIndex(where: { $0.id == turnID }) else {
            throw SpeakerIdentityError.speakerNotFound
        }
        let targetEntry = try resolveTargetEntry(target)
        turns[turnIndex].explicitSpeakerID = targetEntry.id
        return targetEntry
    }

    /// Renames an entry (or folds it if another named entry already has `rawName`).
    @discardableResult
    mutating func renameEntry(_ entryID: String, to rawName: String) throws -> LiveSpeakerEntry {
        let name = try DictationStore.validatedSpeakerName(rawName)
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            throw SpeakerIdentityError.speakerNotFound
        }
        guard !entries[index].isSelf else { throw SpeakerIdentityError.reservedLabel }

        if let existingIndex = entries.firstIndex(where: {
            $0.id != entryID && !$0.isGenericCluster && !$0.isSelf &&
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            let sourceEntry = entries[index]
            let destinationID = entries[existingIndex].id
            for cluster in sourceEntry.clusterIDs {
                clusterToEntryID[cluster] = destinationID
                entries[existingIndex].clusterIDs.insert(cluster)
            }
            for turnIndex in turns.indices where turns[turnIndex].explicitSpeakerID == entryID {
                turns[turnIndex].explicitSpeakerID = destinationID
            }
            if entries[existingIndex].profileID == nil { entries[existingIndex].profileID = sourceEntry.profileID }
            if entries[existingIndex].participantIdentifier == nil {
                entries[existingIndex].participantIdentifier = sourceEntry.participantIdentifier
            }
            let updated = entries[existingIndex]
            entries.remove(at: index)
            return updated
        }

        entries[index].displayName = name
        if entries[index].isGenericCluster {
            entries[index].isGenericCluster = false
            entries[index].source = .manual
        }
        return entries[index]
    }

    /// Folds all clusters and single-turn overrides from `sourceEntryID` into `destinationEntryID`,
    /// preserving any existing metadata and removing `sourceEntryID` when done.
    @discardableResult
    mutating func mergeEntry(_ sourceEntryID: String, into destinationEntryID: String) -> LiveSpeakerEntry? {
        guard sourceEntryID != destinationEntryID,
              let sourceIndex = entries.firstIndex(where: { $0.id == sourceEntryID }),
              let destinationIndex = entries.firstIndex(where: { $0.id == destinationEntryID }) else {
            return nil
        }
        let sourceEntry = entries[sourceIndex]
        guard !sourceEntry.isSelf, !entries[destinationIndex].isSelf else { return nil }

        for cluster in sourceEntry.clusterIDs {
            clusterToEntryID[cluster] = destinationEntryID
            entries[destinationIndex].clusterIDs.insert(cluster)
        }
        for turnIndex in turns.indices where turns[turnIndex].explicitSpeakerID == sourceEntryID {
            turns[turnIndex].explicitSpeakerID = destinationEntryID
        }
        if entries[destinationIndex].profileID == nil {
            entries[destinationIndex].profileID = sourceEntry.profileID
        }
        if entries[destinationIndex].participantIdentifier == nil {
            entries[destinationIndex].participantIdentifier = sourceEntry.participantIdentifier
        }
        let updated = entries[destinationIndex]
        entries.remove(at: sourceIndex)
        return updated
    }

    /// Attaches missing profile or participant metadata to an existing speaker entry.
    mutating func setEntryMetadata(
        entryID: String,
        profileID: Int64? = nil,
        participantIdentifier: String? = nil
    ) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        if let profileID, entries[index].profileID == nil {
            entries[index].profileID = profileID
        }
        if let participantIdentifier, entries[index].participantIdentifier == nil {
            entries[index].participantIdentifier = participantIdentifier
        }
    }

    /// Merges calendar/call-roster participants into the live speaker roster without
    /// duplicating existing entries or overwriting custom speaker assignments.
    mutating func syncParticipants(_ participants: [MeetingParticipant]) {
        for participant in participants {
            let trimmed = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard (try? DictationStore.validatedSpeakerName(trimmed)) != nil else { continue }
            if !isInPerson && trimmed.caseInsensitiveCompare("You") == .orderedSame { continue }
            _ = upsertNamedEntry(
                displayName: trimmed,
                profileID: nil,
                participantIdentifier: participant.participantIdentifier,
                source: .participant
            )
        }
    }

    func resolvedSpeakerName(for turn: LiveTranscriptTurn) -> String {
        if let explicitID = turn.explicitSpeakerID,
           let entry = entries.first(where: { $0.id == explicitID }) {
            return entry.displayName
        }
        if let cluster = effectiveClusterID(for: turn),
           let entryID = clusterToEntryID[cluster],
           let entry = entries.first(where: { $0.id == entryID }) {
            return entry.displayName
        }
        return turn.liveClusterID ?? turn.source
    }

    func renderedTranscript() -> String {
        guard !turns.isEmpty else { return "" }
        return turns.map { turn in
            "[\(turn.timestampLabel)] \(resolvedSpeakerName(for: turn)): \(turn.text)"
        }.joined(separator: "\n") + "\n"
    }

    func reconciliationSnapshot() -> LiveSpeakerReconciliationInput {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var intervalsByCluster: [String: [LiveSpeakerInterval]] = [:]
        var overrides: [LiveTurnOverrideRecord] = []

        for turn in turns where !isSelfTurn(turn) {
            let interval = LiveSpeakerInterval(start: turn.startSeconds, end: max(turn.endSeconds, turn.startSeconds + 0.1))
            if let cluster = effectiveClusterID(for: turn) {
                intervalsByCluster[cluster, default: []].append(interval)
            }
            if let explicitID = turn.explicitSpeakerID,
               let entry = entriesByID[explicitID],
               !entry.isGenericCluster {
                overrides.append(
                    LiveTurnOverrideRecord(
                        turnID: turn.id,
                        startSeconds: turn.startSeconds,
                        endSeconds: max(turn.endSeconds, turn.startSeconds + 0.1),
                        source: turn.source,
                        targetEntryID: entry.id,
                        displayName: entry.displayName,
                        profileID: entry.profileID
                    )
                )
            }
        }

        var assignments: [LiveSpeakerAssignmentRecord] = []
        for (clusterID, entryID) in clusterToEntryID.sorted(by: { $0.key < $1.key }) {
            guard clusterID != "You",
                  let entry = entriesByID[entryID],
                  !entry.isSelf,
                  !entry.isGenericCluster else { continue }
            assignments.append(
                LiveSpeakerAssignmentRecord(
                    clusterID: clusterID,
                    targetEntryID: entry.id,
                    displayName: entry.displayName,
                    profileID: entry.profileID,
                    intervals: intervalsByCluster[clusterID] ?? []
                )
            )
        }

        return LiveSpeakerReconciliationInput(
            turns: turns,
            clusterAssignments: assignments,
            turnOverrides: overrides,
            entriesByID: entriesByID,
            isInPerson: isInPerson
        )
    }

    // MARK: - Private helpers

    private func isSelfTurn(_ turn: LiveTranscriptTurn) -> Bool {
        !isInPerson && turn.source == "You"
    }

    private func effectiveClusterID(for turn: LiveTranscriptTurn) -> String? {
        if let cluster = turn.liveClusterID { return cluster }
        return isSelfTurn(turn) ? "You" : "Others"
    }

    private mutating func ensureClusterEntryIfNeeded(clusterID: String) {
        if let existingID = clusterToEntryID[clusterID],
           entries.contains(where: { $0.id == existingID }) {
            return
        }
        let id = "cluster:\(clusterID)"
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].clusterIDs.insert(clusterID)
            clusterToEntryID[clusterID] = id
            return
        }
        let entry = LiveSpeakerEntry(
            id: id,
            displayName: clusterID,
            profileID: nil,
            participantIdentifier: nil,
            source: .diarizedCluster,
            clusterIDs: [clusterID],
            isSelf: false,
            isGenericCluster: true
        )
        entries.append(entry)
        clusterToEntryID[clusterID] = id
    }

    private mutating func resolveTargetEntry(_ target: LiveSpeakerTarget) throws -> LiveSpeakerEntry {
        switch target {
        case .existingEntry(let id):
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw SpeakerIdentityError.speakerNotFound
            }
            return entry
        case .savedProfile(let id, let rawName):
            let name = try DictationStore.validatedSpeakerName(rawName)
            return upsertNamedEntry(displayName: name, profileID: id, participantIdentifier: nil, source: .savedProfile)
        case .participant(let identifier, let rawName):
            let name = try DictationStore.validatedSpeakerName(rawName)
            return upsertNamedEntry(displayName: name, profileID: nil, participantIdentifier: identifier, source: .participant)
        case .newName(let rawName):
            let name = try DictationStore.validatedSpeakerName(rawName)
            return upsertNamedEntry(displayName: name, profileID: nil, participantIdentifier: nil, source: .manual)
        }
    }

    private mutating func upsertNamedEntry(
        displayName: String,
        profileID: Int64?,
        participantIdentifier: String?,
        source: LiveSpeakerEntry.Source
    ) -> LiveSpeakerEntry {
        if let existingIndex = matchingNamedEntryIndex(
            displayName: displayName,
            profileID: profileID,
            participantIdentifier: participantIdentifier
        ) {
            if entries[existingIndex].profileID == nil, let profileID {
                entries[existingIndex].profileID = profileID
            }
            if entries[existingIndex].participantIdentifier == nil, let participantIdentifier {
                entries[existingIndex].participantIdentifier = participantIdentifier
            }
            if source == .savedProfile {
                entries[existingIndex].source = .savedProfile
            }
            return entries[existingIndex]
        }

        let id: String
        if let profileID {
            id = "profile:\(profileID)"
        } else if let participantIdentifier {
            id = "participant:\(participantIdentifier)"
        } else {
            id = "manual:\(UUID().uuidString)"
        }

        let entry = LiveSpeakerEntry(
            id: id,
            displayName: displayName,
            profileID: profileID,
            participantIdentifier: participantIdentifier,
            source: source,
            clusterIDs: [],
            isSelf: false,
            isGenericCluster: false
        )
        entries.append(entry)
        return entry
    }

    private func matchingNamedEntryIndex(
        displayName: String,
        profileID: Int64?,
        participantIdentifier: String?
    ) -> Int? {
        if let profileID,
           let index = entries.firstIndex(where: { !$0.isGenericCluster && !$0.isSelf && $0.profileID == profileID }) {
            return index
        }
        if let participantIdentifier,
           let index = entries.firstIndex(where: { !$0.isGenericCluster && !$0.isSelf && $0.participantIdentifier == participantIdentifier }) {
            return index
        }
        return entries.firstIndex(where: {
            !$0.isGenericCluster && !$0.isSelf &&
            $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame
        })
    }
}
