import Foundation
import SQLite3

// Named speakers (voiceprints).
//
// Embeddings are biometric data. Everything in this file is device-local: none of these
// tables feed SyncTextRecord, CloudKit, telemetry, exports, CLI JSON, or logs. Public
// read models expose names and counts only, never vectors.

/// One diarized remote speaker of a meeting, as produced by the diarization pipeline.
public struct MeetingSpeakerObservation: Sendable, Equatable {
    /// The label printed in the raw transcript ("Speaker N").
    public let label: String
    /// Normalized centroid, or nil when the speaker had too little usable audio.
    public let centroid: [Float]?
    public let speechSeconds: Double
    /// Explicit speaker name supplied by live user edits (overrides automatic voiceprint matching).
    public let assignedName: String?
    /// Explicit saved profile ID supplied by live user edits (overrides automatic voiceprint matching).
    public let assignedProfileID: Int64?

    public init(
        label: String,
        centroid: [Float]?,
        speechSeconds: Double,
        assignedName: String? = nil,
        assignedProfileID: Int64? = nil
    ) {
        self.label = label
        self.centroid = centroid
        self.speechSeconds = speechSeconds
        self.assignedName = assignedName
        self.assignedProfileID = assignedProfileID
    }
}

/// A meeting's diarized speaker as shown in the naming UI.
public struct MeetingSpeaker: Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// The token currently printed for this speaker in the meeting's raw transcript.
    public let label: String
    public let profileID: Int64?
    public let profileName: String?
    /// Whether this meeting kept a centroid that can become a voiceprint.
    public let hasVoiceprintSource: Bool
    /// Whether the assigned profile holds a voiceprint taken from this meeting.
    public let hasVoiceprintFromMeeting: Bool

    public init(
        label: String,
        profileID: Int64?,
        profileName: String?,
        hasVoiceprintSource: Bool = false,
        hasVoiceprintFromMeeting: Bool = false
    ) {
        self.label = label
        self.profileID = profileID
        self.profileName = profileName
        self.hasVoiceprintSource = hasVoiceprintSource
        self.hasVoiceprintFromMeeting = hasVoiceprintFromMeeting
    }
}

public struct SavedVoiceprintProfile: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let voiceprints: [[Float]]

    public init(id: Int64, name: String, voiceprints: [[Float]]) {
        self.id = id
        self.name = name
        self.voiceprints = voiceprints
    }
}

public struct VoiceprintBackfillCandidate: Sendable, Equatable {
    public let meetingID: Int64
    public let title: String
    public let recordingPath: String
    public let startTime: String
    public let durationSeconds: Double
    public let rawTranscript: String
    public let createdAt: Date
    public let existingSpeakers: [MeetingSpeaker]

    public init(
        meetingID: Int64,
        title: String,
        recordingPath: String,
        startTime: String = "",
        durationSeconds: Double = 0,
        rawTranscript: String,
        createdAt: Date,
        existingSpeakers: [MeetingSpeaker]
    ) {
        self.meetingID = meetingID
        self.title = title
        self.recordingPath = recordingPath
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.createdAt = createdAt
        self.existingSpeakers = existingSpeakers
    }
}

public struct BackfilledVoiceprintMatch: Sendable, Equatable {
    public let label: String
    public let profileID: Int64
    public let centroid: [Float]

    public init(label: String, profileID: Int64, centroid: [Float]) {
        self.label = label
        self.profileID = profileID
        self.centroid = centroid
    }
}

public struct SpeakerProfileSummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let voiceprintCount: Int
    public let meetingCount: Int

    public init(id: Int64, name: String, voiceprintCount: Int, meetingCount: Int) {
        self.id = id
        self.name = name
        self.voiceprintCount = voiceprintCount
        self.meetingCount = meetingCount
    }
}

public struct SpeakerAssignmentResult: Sendable, Equatable {
    public let profileID: Int64
    public let profileName: String
    public let transcriptRewritten: Bool
    public let voiceprintStored: Bool
}

public enum SpeakerIdentityError: Error, Equatable, LocalizedError {
    case emptyName
    case reservedName
    case reservedLabel
    case speakerNotFound
    case nameInUseInMeeting
    case meetingNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name."
        case .reservedName: "That name is reserved for transcript labels. Choose another name."
        case .reservedLabel: "Only diarized speakers can be named."
        case .speakerNotFound: "This speaker is no longer part of the meeting."
        case .nameInUseInMeeting: "Another speaker in this meeting already has that name."
        case .meetingNotFound: "The meeting could not be found."
        }
    }
}

enum SpeakerIdentitySQL {
    static func migrate(db: OpaquePointer?) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS speaker_profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_speaker_profiles_name
            ON speaker_profiles(name COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS speaker_voiceprints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES speaker_profiles(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL,
            dimension INTEGER NOT NULL,
            source_meeting_id INTEGER,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_speaker_voiceprints_profile
            ON speaker_voiceprints(profile_id, source_meeting_id);
        CREATE TABLE IF NOT EXISTS meeting_speakers (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            embedding BLOB,
            profile_id INTEGER REFERENCES speaker_profiles(id) ON DELETE SET NULL,
            PRIMARY KEY (meeting_id, label)
        );
        """, db: db)
    }

    /// Meetings are soft-deleted, so `ON DELETE CASCADE` never fires for them. The
    /// meeting delete paths call this so a deleted meeting keeps no biometric centroid.
    static func deleteMeetingSpeakers(meetingID: Int64?, db: OpaquePointer?) throws {
        if let meetingID {
            try execute("DELETE FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)], db: db)
        } else {
            try execute("DELETE FROM meeting_speakers", db: db)
        }
    }

    enum Value {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }

    static func execute(_ sql: String, _ values: [Value] = [], db: OpaquePointer?) throws {
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
            return
        }
        _ = try rows(sql, values, db: db) { _ in () }
    }

    static func rows<T>(_ sql: String, _ values: [Value] = [], db: OpaquePointer?, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(db) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error(db) }
            result.append(try map(statement))
        }
    }

    static func transaction<T>(db: OpaquePointer?, _ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let result = try operation()
            try execute("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    static func integer(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    static func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    /// Float32, host byte order (little-endian on every supported Mac).
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Generic message: SQLite error text can quote values, and these rows hold names.
    private static func error(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "SpeakerIdentityDB", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "Speaker storage could not be updated."])
    }
}

extension DictationStore {
    // MARK: Pipeline

    /// Highest numeric suffix among `"Speaker N"` labels in `existingLabels` or line
    /// prefixes in `transcript`. Used when resuming a meeting so new sessions do not
    /// reuse earlier `"Speaker N"` labels.
    public static func highestSpeakerNumber(inTranscript transcript: String, existingLabels: [String]) -> Int {
        var highest = 0
        if let labelRegex = try? NSRegularExpression(pattern: "^Speaker (\\d+)$") {
            for label in existingLabels {
                let range = NSRange(label.startIndex..., in: label)
                if let match = labelRegex.firstMatch(in: label, range: range),
                   let numberRange = Range(match.range(at: 1), in: label),
                   let number = Int(label[numberRange]) {
                    highest = max(highest, number)
                }
            }
        }
        if let transcriptRegex = try? NSRegularExpression(pattern: "(?m)^(?:\\[[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\\]\\s+)?Speaker (\\d+):") {
            let range = NSRange(transcript.startIndex..., in: transcript)
            transcriptRegex.enumerateMatches(in: transcript, range: range) { match, _, _ in
                guard let match,
                      let numberRange = Range(match.range(at: 1), in: transcript),
                      let number = Int(transcript[numberRange]) else { return }
                highest = max(highest, number)
            }
        }
        return highest
    }

    /// Next available `"Speaker N"` index for a meeting, strictly greater than any
    /// existing `"Speaker N"` in `meeting_speakers` or its transcript.
    public func nextSpeakerNumber(forMeetingID meetingID: Int64, priorTranscript: String? = nil) throws -> Int {
        try withChatDatabase { db in
            try nextSpeakerNumber(forMeetingID: meetingID, priorTranscript: priorTranscript, db: db)
        }
    }

    private func nextSpeakerNumber(forMeetingID meetingID: Int64, priorTranscript: String?, db: OpaquePointer?) throws -> Int {
        let existingLabels = try SpeakerIdentitySQL.rows(
            "SELECT label FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)], db: db
        ) { SpeakerIdentitySQL.text($0, 0) ?? "" }
        let dbTranscript = try SpeakerIdentitySQL.rows(
            "SELECT COALESCE(raw_transcript, '') FROM meetings WHERE id = ?", [.integer(meetingID)], db: db
        ) { SpeakerIdentitySQL.text($0, 0) ?? "" }.first ?? ""
        let combined = [dbTranscript, priorTranscript ?? ""].joined(separator: "\n")
        return Self.highestSpeakerNumber(inTranscript: combined, existingLabels: existingLabels) + 1
    }

    /// Replaces (or merges into, when `preservingExisting` is true for resumed meetings) this
    /// meeting's speaker rows with the new diarization, honors explicit live assignments first,
    /// and matches remaining centroids against saved voiceprints.
    /// Returns `observed label -> rendered name` when `renderNames` is true; when false (private
    /// meetings) assignments and voiceprint matches are recorded locally without returning names
    /// for the transcript.
    public func recordMeetingSpeakers(
        meetingID: Int64,
        observations: [MeetingSpeakerObservation],
        renderNames: Bool,
        preservingExisting: Bool = false
    ) throws -> [String: String] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                if !preservingExisting {
                    try SpeakerIdentitySQL.deleteMeetingSpeakers(meetingID: meetingID, db: db)
                }
                // A discard or delete can race with the end of processing; never leave a
                // centroid behind for a meeting that is gone.
                let live = try SpeakerIdentitySQL.rows(
                    "SELECT 1 FROM meetings WHERE id = ? AND deleted_at IS NULL", [.integer(meetingID)], db: db
                ) { _ in true }
                guard !live.isEmpty else { return [:] }

                let speakers = observations.filter { !SpeakerVoiceprintMatcher.reservedLabels.contains($0.label) }
                let existingRows = preservingExisting ? try loadMeetingSpeakerRows(meetingID: meetingID, db: db) : []
                var usedLabels = Set(existingRows.map(\.label))
                var nextSpeakerNumber = Self.nextSpeakerNumber(existingLabels: usedLabels)
                let minimumSpeakerNumber = preservingExisting ? nextSpeakerNumber : 1

                // 1. Resolve explicit live assignments first so automatic voiceprint matching never
                // steals a profile the user explicitly bound to another speaker.
                var explicitProfiles: [String: Int64] = [:]
                var explicitlyUsedProfileIDs = Set<Int64>()
                for speaker in speakers {
                    if let profileID = try resolveExplicitProfileID(for: speaker, db: db) {
                        explicitProfiles[speaker.label] = profileID
                        explicitlyUsedProfileIDs.insert(profileID)
                    }
                }

                // 2. Match remaining unnamed observations against saved voiceprints.
                let unnamedCandidates = speakers
                    .filter { explicitProfiles[$0.label] == nil }
                    .map { SpeakerVoiceprintMatcher.Candidate(label: $0.label, centroid: $0.centroid) }
                let availableProfiles = try loadMatcherProfiles(db: db)
                    .filter { !explicitlyUsedProfileIDs.contains($0.id) }
                let matchedProfiles = SpeakerVoiceprintMatcher.match(
                    candidates: unnamedCandidates,
                    profiles: availableProfiles
                )

                var allProfileIDs = Set(explicitProfiles.values).union(matchedProfiles.values)
                allProfileIDs.formUnion(existingRows.compactMap(\.profileID))
                let names = try profileNames(ids: Array(allProfileIDs), db: db)

                // 3. Fold multiple observations that resolved to the same profile (e.g. merged clusters).
                var resolvedByProfile: [Int64: (labels: [String], centroid: [Float]?, isExplicit: Bool)] = [:]
                var orderedProfileIDs: [Int64] = []
                var unnamedSpeakers: [MeetingSpeakerObservation] = []

                for speaker in speakers {
                    let explicitID = explicitProfiles[speaker.label]
                    let resolvedID = explicitID ?? matchedProfiles[speaker.label]
                    if let profileID = resolvedID {
                        if var group = resolvedByProfile[profileID] {
                            group.labels.append(speaker.label)
                            group.centroid = Self.combinedNormalizedVectors(group.centroid, speaker.centroid)
                            group.isExplicit = group.isExplicit || (explicitID != nil)
                            resolvedByProfile[profileID] = group
                        } else {
                            orderedProfileIDs.append(profileID)
                            resolvedByProfile[profileID] = (
                                labels: [speaker.label],
                                centroid: Self.usableVector(speaker.centroid),
                                isExplicit: explicitID != nil
                            )
                        }
                    } else {
                        unnamedSpeakers.append(speaker)
                    }
                }

                var rendered: [String: String] = [:]

                for profileID in orderedProfileIDs {
                    guard let group = resolvedByProfile[profileID],
                          let profileName = names[profileID] else { continue }

                    if preservingExisting,
                       let existing = existingRows.first(where: { $0.profileID == profileID }) {
                        let combinedData = Self.combinedEmbeddingData(
                            existing.embedding,
                            group.centroid.map(SpeakerIdentitySQL.encode)
                        )
                        try SpeakerIdentitySQL.execute(
                            "UPDATE meeting_speakers SET embedding = ? WHERE meeting_id = ? AND label = ?",
                            [combinedData.map { .blob($0) } ?? .null, .integer(meetingID), .text(existing.label)],
                            db: db
                        )
                        if group.isExplicit {
                            _ = try storeVoiceprint(combinedData, profileID: profileID, meetingID: meetingID, replaceExisting: true, db: db)
                        }
                        if renderNames {
                            for observedLabel in group.labels {
                                rendered[observedLabel] = existing.label
                            }
                        }
                        continue
                    }

                    let rowLabel: String
                    if renderNames {
                        rowLabel = profileName
                    } else {
                        let preferred = group.labels.first ?? "Speaker \(nextSpeakerNumber)"
                        rowLabel = Self.allocateLabel(preferred: preferred, used: &usedLabels, nextNumber: &nextSpeakerNumber, minimumSpeakerNumber: minimumSpeakerNumber)
                    }
                    usedLabels.insert(rowLabel)

                    let embeddingData = group.centroid.map(SpeakerIdentitySQL.encode)
                    try SpeakerIdentitySQL.execute(
                        "INSERT OR REPLACE INTO meeting_speakers (meeting_id, label, embedding, profile_id) VALUES (?, ?, ?, ?)",
                        [.integer(meetingID), .text(rowLabel), embeddingData.map { .blob($0) } ?? .null, .integer(profileID)],
                        db: db
                    )
                    if group.isExplicit {
                        _ = try storeVoiceprint(embeddingData, profileID: profileID, meetingID: meetingID, replaceExisting: true, db: db)
                    }
                    if renderNames {
                        for observedLabel in group.labels {
                            rendered[observedLabel] = profileName
                        }
                    }
                }

                for speaker in unnamedSpeakers {
                    let rowLabel: String
                    if preservingExisting {
                        rowLabel = Self.allocateLabel(preferred: speaker.label, used: &usedLabels, nextNumber: &nextSpeakerNumber, minimumSpeakerNumber: minimumSpeakerNumber)
                    } else {
                        rowLabel = speaker.label
                        usedLabels.insert(rowLabel)
                    }
                    if renderNames, rowLabel != speaker.label {
                        rendered[speaker.label] = rowLabel
                    }
                    let embeddingData = Self.usableVector(speaker.centroid).map(SpeakerIdentitySQL.encode)
                    try SpeakerIdentitySQL.execute(
                        "INSERT OR REPLACE INTO meeting_speakers (meeting_id, label, embedding, profile_id) VALUES (?, ?, ?, NULL)",
                        [.integer(meetingID), .text(rowLabel), embeddingData.map { .blob($0) } ?? .null],
                        db: db
                    )
                }

                return rendered
            }
        }
    }

    // MARK: Reads

    public func meetingSpeakers(meetingID: Int64) throws -> [MeetingSpeaker] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.rows("""
            SELECT ms.label, ms.profile_id, sp.name, ms.embedding IS NOT NULL,
                   EXISTS(SELECT 1 FROM speaker_voiceprints v WHERE v.profile_id = ms.profile_id AND v.source_meeting_id = ms.meeting_id)
            FROM meeting_speakers ms LEFT JOIN speaker_profiles sp ON sp.id = ms.profile_id
            WHERE ms.meeting_id = ?
            ORDER BY ms.rowid
            """, [.integer(meetingID)], db: db) { statement in
                MeetingSpeaker(
                    label: SpeakerIdentitySQL.text(statement, 0) ?? "",
                    profileID: SpeakerIdentitySQL.integer(statement, 1),
                    profileName: SpeakerIdentitySQL.text(statement, 2),
                    hasVoiceprintSource: sqlite3_column_int(statement, 3) != 0,
                    hasVoiceprintFromMeeting: sqlite3_column_int(statement, 4) != 0
                )
            }
        }
    }

    public func speakerProfiles() throws -> [SpeakerProfileSummary] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.rows("""
            SELECT p.id, p.name,
                   (SELECT COUNT(*) FROM speaker_voiceprints v WHERE v.profile_id = p.id),
                   (SELECT COUNT(DISTINCT ms.meeting_id) FROM meeting_speakers ms WHERE ms.profile_id = p.id)
            FROM speaker_profiles p
            ORDER BY p.name COLLATE NOCASE
            """, db: db) { statement in
                SpeakerProfileSummary(
                    id: sqlite3_column_int64(statement, 0),
                    name: SpeakerIdentitySQL.text(statement, 1) ?? "",
                    voiceprintCount: Int(sqlite3_column_int64(statement, 2)),
                    meetingCount: Int(sqlite3_column_int64(statement, 3))
                )
            }
        }
    }

    /// Loads saved profiles that have at least one usable biometric voiceprint for in-process matching.
    public func savedVoiceprintProfiles() throws -> [SavedVoiceprintProfile] {
        try withChatDatabase { db in
            let rows = try SpeakerIdentitySQL.rows("""
            SELECT p.id, p.name, v.embedding
            FROM speaker_profiles p
            JOIN speaker_voiceprints v ON v.profile_id = p.id
            ORDER BY p.id, v.id
            """, db: db) {
                (
                    sqlite3_column_int64($0, 0),
                    SpeakerIdentitySQL.text($0, 1) ?? "",
                    SpeakerIdentitySQL.blob($0, 2).map(SpeakerIdentitySQL.decode) ?? []
                )
            }
            var grouped: [Int64: (name: String, voiceprints: [[Float]])] = [:]
            for (id, name, embedding) in rows where !name.isEmpty && SpeakerVoiceprintMatcher.isUsable(embedding) {
                if var existing = grouped[id] {
                    existing.voiceprints.append(embedding)
                    grouped[id] = existing
                } else {
                    grouped[id] = (name: name, voiceprints: [embedding])
                }
            }
            return grouped.keys.sorted().compactMap { id in
                guard let entry = grouped[id], !entry.voiceprints.isEmpty else { return nil }
                return SavedVoiceprintProfile(id: id, name: entry.name, voiceprints: entry.voiceprints)
            }
        }
    }

    /// Finds or creates a speaker profile by name (case-insensitive) without requiring a
    /// diarized `meeting_speakers` row, so mid-call pre-added speakers can be linked immediately.
    @discardableResult
    public func findOrCreateSpeakerProfile(name rawName: String) throws -> SpeakerProfileSummary {
        let name = try Self.validatedSpeakerName(rawName)
        return try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                let profileID = try findOrCreateProfile(named: name, db: db)
                let rows = try SpeakerIdentitySQL.rows("""
                SELECT p.id, p.name,
                       (SELECT COUNT(*) FROM speaker_voiceprints v WHERE v.profile_id = p.id),
                       (SELECT COUNT(DISTINCT ms.meeting_id) FROM meeting_speakers ms WHERE ms.profile_id = p.id)
                FROM speaker_profiles p
                WHERE p.id = ?
                """, [.integer(profileID)], db: db) { statement in
                    SpeakerProfileSummary(
                        id: sqlite3_column_int64(statement, 0),
                        name: SpeakerIdentitySQL.text(statement, 1) ?? name,
                        voiceprintCount: Int(sqlite3_column_int64(statement, 2)),
                        meetingCount: Int(sqlite3_column_int64(statement, 3))
                    )
                }
                guard let summary = rows.first else { throw SpeakerIdentityError.speakerNotFound }
                return summary
            }
        }
    }

    // MARK: Naming

    /// Names a meeting speaker ("This is Alex"). In one transaction: finds or creates the
    /// profile (case-insensitive, so an existing name merges), rewrites the label in the
    /// raw transcript unless the meeting is private, stores this meeting's centroid as a
    /// voiceprint, and moves any voiceprint this meeting gave a previous profile.
    /// When `allowMerge` is true, assigning a name already used by another cluster in this
    /// meeting folds the source cluster into that target speaker and merges their centroids.
    /// Repeating the same call is a no-op.
    @discardableResult
    public func assignSpeaker(
        meetingID: Int64,
        label: String,
        name rawName: String,
        allowMerge: Bool = false
    ) throws -> SpeakerAssignmentResult {
        let name = try Self.validatedSpeakerName(rawName)
        guard !SpeakerVoiceprintMatcher.reservedLabels.contains(label) else { throw SpeakerIdentityError.reservedLabel }
        let isPrivate = try isMeetingPrivate(id: meetingID)
        return try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                try assignSpeaker(meetingID: meetingID, label: label, name: name, rewrite: !isPrivate, allowMerge: allowMerge, db: db)
            }
        }
    }

    /// Convenience alias for merging `sourceLabel` into `intoTargetName` within a meeting.
    @discardableResult
    public func mergeMeetingSpeakers(
        meetingID: Int64,
        sourceLabel: String,
        intoTargetName rawName: String
    ) throws -> SpeakerAssignmentResult {
        try assignSpeaker(meetingID: meetingID, label: sourceLabel, name: rawName, allowMerge: true)
    }

    /// Merges `sourceLabel` into `targetLabel` within a meeting, supporting both named
    /// speakers and generic cluster labels (e.g. merging `"Speaker 1"` into `"Speaker 2"`).
    @discardableResult
    public func mergeMeetingSpeakerLabels(
        meetingID: Int64,
        sourceLabel: String,
        targetLabel: String
    ) throws -> SpeakerAssignmentResult {
        let trimmedTarget = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validName = try? Self.validatedSpeakerName(trimmedTarget) {
            return try assignSpeaker(meetingID: meetingID, label: sourceLabel, name: validName, allowMerge: true)
        }
        guard !SpeakerVoiceprintMatcher.reservedLabels.contains(sourceLabel),
              !SpeakerVoiceprintMatcher.reservedLabels.contains(trimmedTarget),
              !trimmedTarget.isEmpty,
              sourceLabel != trimmedTarget else {
            throw SpeakerIdentityError.reservedLabel
        }
        let isPrivate = try isMeetingPrivate(id: meetingID)
        let rewrite = !isPrivate
        return try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                guard let sourceRow = try meetingSpeakerRow(meetingID: meetingID, label: sourceLabel, db: db),
                      let targetRow = try meetingSpeakerRow(meetingID: meetingID, label: trimmedTarget, db: db) else {
                    throw SpeakerIdentityError.speakerNotFound
                }
                if let previous = sourceRow.profileID, previous != targetRow.profileID {
                    try forgetVoiceprints(profileID: previous, sourceMeetingID: meetingID, db: db)
                }
                let combinedEmbedding = Self.combinedEmbeddingData(targetRow.embedding, sourceRow.embedding)
                try SpeakerIdentitySQL.execute(
                    "UPDATE meeting_speakers SET embedding = ? WHERE meeting_id = ? AND label = ?",
                    [combinedEmbedding.map { .blob($0) } ?? .null, .integer(meetingID), .text(trimmedTarget)],
                    db: db
                )
                try SpeakerIdentitySQL.execute(
                    "DELETE FROM meeting_speakers WHERE meeting_id = ? AND label = ?",
                    [.integer(meetingID), .text(sourceLabel)],
                    db: db
                )
                let stored: Bool
                if let targetProfileID = targetRow.profileID {
                    stored = try storeVoiceprint(combinedEmbedding, profileID: targetProfileID, meetingID: meetingID, replaceExisting: true, db: db)
                } else {
                    stored = false
                }
                let rewritten = rewrite ? try rewriteTranscriptLabel(meetingID: meetingID, from: sourceLabel, to: trimmedTarget, db: db) : false
                return SpeakerAssignmentResult(
                    profileID: targetRow.profileID ?? 0,
                    profileName: trimmedTarget,
                    transcriptRewritten: rewritten,
                    voiceprintStored: stored
                )
            }
        }
    }

    private func assignSpeaker(
        meetingID: Int64,
        label: String,
        name: String,
        rewrite: Bool,
        allowMerge: Bool,
        db: OpaquePointer?
    ) throws -> SpeakerAssignmentResult {
        let profileID = try findOrCreateProfile(named: name, db: db)
        let profileName = try profileNames(ids: [profileID], db: db)[profileID] ?? name
        guard let row = try meetingSpeakerRow(meetingID: meetingID, label: label, db: db) else {
            return try alreadyAssigned(meetingID: meetingID, label: profileName, profileID: profileID, db: db)
        }
        let newLabel = rewrite ? profileName : label
        let otherByProfile = try otherMeetingSpeakerRow(meetingID: meetingID, profileID: profileID, excludingLabel: label, db: db)
        let otherByLabel = newLabel != label ? try meetingSpeakerRow(meetingID: meetingID, label: newLabel, db: db).map { (label: newLabel, row: $0) } : nil

        if let target = otherByProfile ?? otherByLabel {
            guard allowMerge else { throw SpeakerIdentityError.nameInUseInMeeting }
            if let previous = row.profileID, previous != profileID {
                try forgetVoiceprints(profileID: previous, sourceMeetingID: meetingID, db: db)
            }
            let combinedEmbedding = Self.combinedEmbeddingData(target.row.embedding, row.embedding)
            try SpeakerIdentitySQL.execute(
                "UPDATE meeting_speakers SET embedding = ?, profile_id = ? WHERE meeting_id = ? AND label = ?",
                [combinedEmbedding.map { .blob($0) } ?? .null, .integer(profileID), .integer(meetingID), .text(target.label)],
                db: db
            )
            try SpeakerIdentitySQL.execute(
                "DELETE FROM meeting_speakers WHERE meeting_id = ? AND label = ?",
                [.integer(meetingID), .text(label)],
                db: db
            )
            let stored = try storeVoiceprint(combinedEmbedding, profileID: profileID, meetingID: meetingID, replaceExisting: true, db: db)
            let rewritten = (rewrite && target.label != label) ? try rewriteTranscriptLabel(meetingID: meetingID, from: label, to: target.label, db: db) : false
            return SpeakerAssignmentResult(profileID: profileID, profileName: profileName, transcriptRewritten: rewritten, voiceprintStored: stored)
        }

        if let previous = row.profileID, previous != profileID {
            try forgetVoiceprints(profileID: previous, sourceMeetingID: meetingID, db: db)
        }
        let stored = try storeVoiceprint(row.embedding, profileID: profileID, meetingID: meetingID, replaceExisting: false, db: db)
        try SpeakerIdentitySQL.execute(
            "UPDATE meeting_speakers SET label = ?, profile_id = ? WHERE meeting_id = ? AND label = ?",
            [.text(newLabel), .integer(profileID), .integer(meetingID), .text(label)], db: db
        )
        let rewritten = newLabel != label ? try rewriteTranscriptLabel(meetingID: meetingID, from: label, to: newLabel, db: db) : false
        return SpeakerAssignmentResult(profileID: profileID, profileName: profileName, transcriptRewritten: rewritten, voiceprintStored: stored)
    }

    /// A concurrent or repeated rename already moved the row to the new name.
    private func alreadyAssigned(meetingID: Int64, label: String, profileID: Int64, db: OpaquePointer?) throws -> SpeakerAssignmentResult {
        guard let row = try meetingSpeakerRow(meetingID: meetingID, label: label, db: db), row.profileID == profileID else {
            throw SpeakerIdentityError.speakerNotFound
        }
        return SpeakerAssignmentResult(profileID: profileID, profileName: label, transcriptRewritten: false, voiceprintStored: false)
    }

    // MARK: Forget / delete

    /// Deletes voiceprints of a profile; the profile stays. `sourceMeetingID == nil`
    /// forgets every voiceprint of the person.
    public func forgetVoiceprints(profileID: Int64, sourceMeetingID: Int64?) throws {
        try withChatDatabase { db in
            try forgetVoiceprints(profileID: profileID, sourceMeetingID: sourceMeetingID, db: db)
        }
    }

    /// Deletes the person. Voiceprints cascade; meeting rows keep their label (the typed
    /// name stays in transcripts) with `profile_id` set to NULL.
    public func deleteSpeakerProfile(id: Int64) throws {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.execute("DELETE FROM speaker_profiles WHERE id = ?", [.integer(id)], db: db)
        }
    }

    // MARK: Transcript rewrite

    /// Replaces `label` only where it is the speaker prefix of a transcript line
    /// (`[HH:MM:SS] label: `). Body text and longer labels ("Speaker 12") are untouched.
    public static func rewriteSpeakerLabel(in transcript: String, from label: String, to replacement: String) -> String {
        let pattern = "(?m)^(\\[\\d{2}:\\d{2}:\\d{2}\\] )" + NSRegularExpression.escapedPattern(for: label) + "(?=: )"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return transcript }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: replacement)
        let range = NSRange(transcript.startIndex..., in: transcript)
        return regex.stringByReplacingMatches(in: transcript, range: range, withTemplate: template)
    }

    public static func validatedSpeakerName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeakerIdentityError.emptyName }
        // A name becomes a transcript line prefix, so it must not break that format.
        guard !isReservedSpeakerName(name), !name.contains(":"), !name.contains(where: \.isNewline) else {
            throw SpeakerIdentityError.reservedName
        }
        return name
    }

    public static func isReservedSpeakerName(_ name: String) -> Bool {
        if SpeakerVoiceprintMatcher.reservedLabels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return true
        }
        return name.range(of: "^speaker \\d+$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Private helpers

    private struct MeetingSpeakerRow {
        let embedding: Data?
        let profileID: Int64?
    }

    private struct StoredMeetingSpeakerRow {
        let label: String
        let embedding: Data?
        let profileID: Int64?
    }

    private func loadMeetingSpeakerRows(meetingID: Int64, db: OpaquePointer?) throws -> [StoredMeetingSpeakerRow] {
        try SpeakerIdentitySQL.rows(
            "SELECT label, embedding, profile_id FROM meeting_speakers WHERE meeting_id = ? ORDER BY rowid",
            [.integer(meetingID)],
            db: db
        ) {
            StoredMeetingSpeakerRow(
                label: SpeakerIdentitySQL.text($0, 0) ?? "",
                embedding: SpeakerIdentitySQL.blob($0, 1),
                profileID: SpeakerIdentitySQL.integer($0, 2)
            )
        }
    }

    private func resolveExplicitProfileID(for observation: MeetingSpeakerObservation, db: OpaquePointer?) throws -> Int64? {
        if let profileID = observation.assignedProfileID {
            let exists = try !SpeakerIdentitySQL.rows(
                "SELECT 1 FROM speaker_profiles WHERE id = ?",
                [.integer(profileID)],
                db: db
            ) { _ in () }.isEmpty
            if exists { return profileID }
        }
        if let rawName = observation.assignedName,
           let validName = try? Self.validatedSpeakerName(rawName) {
            return try findOrCreateProfile(named: validName, db: db)
        }
        return nil
    }

    private static func nextSpeakerNumber(existingLabels: Set<String>) -> Int {
        var maxNumber = 0
        for label in existingLabels {
            if label.hasPrefix("Speaker "), let number = Int(label.dropFirst("Speaker ".count)) {
                maxNumber = max(maxNumber, number)
            }
        }
        return maxNumber + 1
    }

    private static func allocateLabel(
        preferred: String,
        used: inout Set<String>,
        nextNumber: inout Int,
        minimumSpeakerNumber: Int = 1
    ) -> String {
        let preferredNumber = speakerNumber(for: preferred)
        if !used.contains(preferred), preferredNumber.map({ $0 >= minimumSpeakerNumber }) ?? true {
            used.insert(preferred)
            return preferred
        }
        while used.contains("Speaker \(nextNumber)") {
            nextNumber += 1
        }
        let allocated = "Speaker \(nextNumber)"
        used.insert(allocated)
        nextNumber += 1
        return allocated
    }

    private static func speakerNumber(for label: String) -> Int? {
        guard label.hasPrefix("Speaker ") else { return nil }
        return Int(label.dropFirst("Speaker ".count))
    }

    private static func usableVector(_ vector: [Float]?) -> [Float]? {
        guard let vector, SpeakerVoiceprintMatcher.isUsable(vector) else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        let unit = vector.map { $0 / norm }
        return SpeakerVoiceprintMatcher.isUsable(unit) ? unit : nil
    }

    private static func combinedNormalizedVectors(_ lhs: [Float]?, _ rhs: [Float]?) -> [Float]? {
        let left = usableVector(lhs)
        let right = usableVector(rhs)
        switch (left, right) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?):
            guard l.count == r.count else { return l }
            let sum = zip(l, r).map(+)
            return usableVector(sum) ?? l
        }
    }

    private static func combinedEmbeddingData(_ lhs: Data?, _ rhs: Data?) -> Data? {
        let left = lhs.map(SpeakerIdentitySQL.decode)
        let right = rhs.map(SpeakerIdentitySQL.decode)
        return combinedNormalizedVectors(left, right).map(SpeakerIdentitySQL.encode)
    }

    private func meetingSpeakerRow(meetingID: Int64, label: String, db: OpaquePointer?) throws -> MeetingSpeakerRow? {
        try SpeakerIdentitySQL.rows(
            "SELECT embedding, profile_id FROM meeting_speakers WHERE meeting_id = ? AND label = ?",
            [.integer(meetingID), .text(label)], db: db
        ) { MeetingSpeakerRow(embedding: SpeakerIdentitySQL.blob($0, 0), profileID: SpeakerIdentitySQL.integer($0, 1)) }.first
    }

    private func otherMeetingSpeakerRow(
        meetingID: Int64,
        profileID: Int64,
        excludingLabel label: String,
        db: OpaquePointer?
    ) throws -> (label: String, row: MeetingSpeakerRow)? {
        try SpeakerIdentitySQL.rows(
            "SELECT label, embedding, profile_id FROM meeting_speakers WHERE meeting_id = ? AND profile_id = ? AND label <> ? ORDER BY rowid LIMIT 1",
            [.integer(meetingID), .integer(profileID), .text(label)], db: db
        ) {
            (
                label: SpeakerIdentitySQL.text($0, 0) ?? "",
                row: MeetingSpeakerRow(embedding: SpeakerIdentitySQL.blob($0, 1), profileID: SpeakerIdentitySQL.integer($0, 2))
            )
        }.first
    }

    private func findOrCreateProfile(named name: String, db: OpaquePointer?) throws -> Int64 {
        try SpeakerIdentitySQL.execute(
            "INSERT OR IGNORE INTO speaker_profiles (name, created_at) VALUES (?, ?)",
            [.text(name), .real(Date().timeIntervalSince1970)], db: db
        )
        let ids = try SpeakerIdentitySQL.rows(
            "SELECT id FROM speaker_profiles WHERE name = ? COLLATE NOCASE", [.text(name)], db: db
        ) { sqlite3_column_int64($0, 0) }
        guard let id = ids.first else { throw SpeakerIdentityError.speakerNotFound }
        return id
    }

    private func profileNames(ids: [Int64], db: OpaquePointer?) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for id in Set(ids) {
            let rows = try SpeakerIdentitySQL.rows("SELECT name FROM speaker_profiles WHERE id = ?", [.integer(id)], db: db) {
                SpeakerIdentitySQL.text($0, 0)
            }
            names[id] = rows.first ?? nil
        }
        return names
    }

    private func storeVoiceprint(
        _ embedding: Data?,
        profileID: Int64,
        meetingID: Int64,
        replaceExisting: Bool = false,
        db: OpaquePointer?
    ) throws -> Bool {
        guard let embedding else { return false }
        let vector = SpeakerIdentitySQL.decode(embedding)
        guard SpeakerVoiceprintMatcher.isUsable(vector) else { return false }
        let existing = try SpeakerIdentitySQL.rows(
            "SELECT id FROM speaker_voiceprints WHERE profile_id = ? AND source_meeting_id = ? ORDER BY id LIMIT 1",
            [.integer(profileID), .integer(meetingID)], db: db
        ) { sqlite3_column_int64($0, 0) }
        if let existingID = existing.first {
            if replaceExisting {
                try SpeakerIdentitySQL.execute(
                    "UPDATE speaker_voiceprints SET embedding = ?, dimension = ?, created_at = ? WHERE id = ?",
                    [.blob(embedding), .integer(Int64(vector.count)), .real(Date().timeIntervalSince1970), .integer(existingID)],
                    db: db
                )
            }
            return true
        }
        try SpeakerIdentitySQL.execute(
            "INSERT INTO speaker_voiceprints (profile_id, embedding, dimension, source_meeting_id, created_at) VALUES (?, ?, ?, ?, ?)",
            [.integer(profileID), .blob(embedding), .integer(Int64(vector.count)), .integer(meetingID), .real(Date().timeIntervalSince1970)],
            db: db
        )
        return true
    }

    private func forgetVoiceprints(profileID: Int64, sourceMeetingID: Int64?, db: OpaquePointer?) throws {
        if let sourceMeetingID {
            try SpeakerIdentitySQL.execute(
                "DELETE FROM speaker_voiceprints WHERE profile_id = ? AND source_meeting_id = ?",
                [.integer(profileID), .integer(sourceMeetingID)], db: db
            )
        } else {
            try SpeakerIdentitySQL.execute("DELETE FROM speaker_voiceprints WHERE profile_id = ?", [.integer(profileID)], db: db)
        }
    }

    private func loadMatcherProfiles(db: OpaquePointer?) throws -> [SpeakerVoiceprintMatcher.Profile] {
        let rows = try SpeakerIdentitySQL.rows(
            "SELECT profile_id, embedding FROM speaker_voiceprints ORDER BY profile_id, id", db: db
        ) { (sqlite3_column_int64($0, 0), SpeakerIdentitySQL.blob($0, 1).map(SpeakerIdentitySQL.decode) ?? []) }
        let grouped = Dictionary(grouping: rows, by: \.0)
        return grouped.keys.sorted().map { id in
            SpeakerVoiceprintMatcher.Profile(id: id, voiceprints: grouped[id]?.map(\.1) ?? [])
        }
    }

    private func rewriteTranscriptLabel(meetingID: Int64, from label: String, to name: String, db: OpaquePointer?) throws -> Bool {
        let rows = try SpeakerIdentitySQL.rows(
            "SELECT COALESCE(raw_transcript, ''), COALESCE(manual_notes, '') FROM meetings WHERE id = ?",
            [.integer(meetingID)], db: db
        ) { (SpeakerIdentitySQL.text($0, 0) ?? "", SpeakerIdentitySQL.text($0, 1) ?? "") }
        guard let (transcript, manualNotes) = rows.first else { throw SpeakerIdentityError.meetingNotFound }
        let rewritten = Self.rewriteSpeakerLabel(in: transcript, from: label, to: name)
        guard rewritten != transcript else { return false }
        let wordCount = Self.countWords(in: rewritten) + Self.countWords(in: manualNotes)
        try SpeakerIdentitySQL.execute(
            "UPDATE meetings SET raw_transcript = ?, word_count = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?",
            [.text(rewritten), .integer(Int64(wordCount)), .real(Date().timeIntervalSince1970), .integer(meetingID)], db: db
        )
        return true
    }

    // MARK: Voiceprint backfill

    private struct VoiceprintKey: Hashable {
        let profileID: Int64
        let meetingID: Int64
    }

    private struct BackfillMeetingRow {
        let id: Int64
        let title: String
        let recordingPath: String
        let startTime: String
        let durationSeconds: Double
        let rawTranscript: String
        let createdAtRaw: String
    }

    private struct BackfillMatchedRow {
        let row: BackfillMeetingRow
        let existingSpeakers: [MeetingSpeaker]
    }

    /// Returns meetings with an existing saved recording on disk where at least one
    /// named speaker lacks a voiceprint derived from that meeting.
    public func meetingsEligibleForVoiceprintBackfill(
        requireExistingFile: Bool = true
    ) throws -> [VoiceprintBackfillCandidate] {
        let matchedRows: [BackfillMatchedRow] = try withChatDatabase { db in
            let profiles: [(Int64, String)] = try SpeakerIdentitySQL.rows(
                "SELECT id, name FROM speaker_profiles",
                db: db
            ) { (sqlite3_column_int64($0, 0), SpeakerIdentitySQL.text($0, 1) ?? "") }
            let profilesByLowerName = Dictionary(
                profiles.map { ($0.1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.0) },
                uniquingKeysWith: { first, _ in first }
            )

            let voiceprintRows: [VoiceprintKey] = try SpeakerIdentitySQL.rows(
                "SELECT profile_id, source_meeting_id FROM speaker_voiceprints WHERE source_meeting_id IS NOT NULL",
                db: db
            ) {
                VoiceprintKey(
                    profileID: sqlite3_column_int64($0, 0),
                    meetingID: sqlite3_column_int64($0, 1)
                )
            }
            let existingVoiceprints = Set(voiceprintRows)

            let speakerRows: [(Int64, MeetingSpeaker)] = try SpeakerIdentitySQL.rows("""
            SELECT ms.meeting_id, ms.label, ms.profile_id, sp.name, ms.embedding IS NOT NULL
            FROM meeting_speakers ms
            LEFT JOIN speaker_profiles sp ON sp.id = ms.profile_id
            ORDER BY ms.meeting_id, ms.rowid
            """, db: db) { statement in
                let meetingID = sqlite3_column_int64(statement, 0)
                let label = SpeakerIdentitySQL.text(statement, 1) ?? ""
                let profileID = SpeakerIdentitySQL.integer(statement, 2)
                let profileName = SpeakerIdentitySQL.text(statement, 3)
                let hasSource = sqlite3_column_int(statement, 4) != 0
                let hasVoiceprint = profileID.map {
                    existingVoiceprints.contains(VoiceprintKey(profileID: $0, meetingID: meetingID))
                } ?? false
                return (
                    meetingID,
                    MeetingSpeaker(
                        label: label,
                        profileID: profileID,
                        profileName: profileName,
                        hasVoiceprintSource: hasSource,
                        hasVoiceprintFromMeeting: hasVoiceprint
                    )
                )
            }
            let speakersByMeeting = Dictionary(grouping: speakerRows, by: \.0)
                .mapValues { $0.map(\.1) }

            let meetingRows: [BackfillMeetingRow] = try SpeakerIdentitySQL.rows("""
            SELECT id, title, saved_recording_path, start_time, COALESCE(duration_seconds, 0),
                   COALESCE(raw_transcript, ''), COALESCE(created_at, '')
            FROM meetings
            WHERE deleted_at IS NULL
              AND meeting_status <> 'recording'
              AND saved_recording_path IS NOT NULL
              AND TRIM(saved_recording_path) <> ''
            ORDER BY julianday(start_time) DESC, id DESC
            """, db: db) { statement in
                BackfillMeetingRow(
                    id: sqlite3_column_int64(statement, 0),
                    title: SpeakerIdentitySQL.text(statement, 1) ?? "",
                    recordingPath: SpeakerIdentitySQL.text(statement, 2) ?? "",
                    startTime: SpeakerIdentitySQL.text(statement, 3) ?? "",
                    durationSeconds: sqlite3_column_double(statement, 4),
                    rawTranscript: SpeakerIdentitySQL.text(statement, 5) ?? "",
                    createdAtRaw: SpeakerIdentitySQL.text(statement, 6) ?? ""
                )
            }

            return meetingRows.compactMap { row in
                let existingSpeakers = speakersByMeeting[row.id] ?? []
                let hasSpeakerNeedingVoiceprint = existingSpeakers.contains { speaker in
                    guard let profileID = speaker.profileID else { return false }
                    return !existingVoiceprints.contains(
                        VoiceprintKey(profileID: profileID, meetingID: row.id)
                    )
                }
                if hasSpeakerNeedingVoiceprint {
                    return BackfillMatchedRow(row: row, existingSpeakers: existingSpeakers)
                }

                // Also eligible when raw_transcript references an existing speaker profile
                // (even if no meeting_speakers row exists yet) that lacks a voiceprint here.
                let transcriptSpeakers = Self.transcriptSpeakerNames(in: row.rawTranscript)
                let hasTranscriptMatch = transcriptSpeakers.contains { label in
                    guard let profileID = profilesByLowerName[label.lowercased()] else { return false }
                    return !existingVoiceprints.contains(
                        VoiceprintKey(profileID: profileID, meetingID: row.id)
                    )
                }
                return hasTranscriptMatch
                    ? BackfillMatchedRow(row: row, existingSpeakers: existingSpeakers)
                    : nil
            }
        }

        let dateParser = MeetingHistoryDateParser()
        let sqliteDateFormatter = DateFormatter()
        sqliteDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        sqliteDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        sqliteDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var candidates: [VoiceprintBackfillCandidate] = []
        for entry in matchedRows {
            let row = entry.row
            if requireExistingFile, !FileManager.default.fileExists(atPath: row.recordingPath) {
                continue
            }
            let createdAt = sqliteDateFormatter.date(from: row.createdAtRaw)
                ?? dateParser.date(row.startTime)
                ?? Date(timeIntervalSince1970: 0)
            candidates.append(
                VoiceprintBackfillCandidate(
                    meetingID: row.id,
                    title: row.title,
                    recordingPath: row.recordingPath,
                    startTime: row.startTime,
                    durationSeconds: row.durationSeconds,
                    rawTranscript: row.rawTranscript,
                    createdAt: createdAt,
                    existingSpeakers: entry.existingSpeakers
                )
            )
        }
        return candidates
    }

    /// Persists backfilled voiceprints and speaker embeddings for `meetingID` inside one
    /// SQLite transaction without modifying `raw_transcript` or `formatted_notes`, and
    /// without removing existing `meeting_speakers` rows.
    @discardableResult
    public func applyBackfilledVoiceprints(
        meetingID: Int64,
        matches: [BackfilledVoiceprintMatch]
    ) throws -> Int {
        guard !matches.isEmpty else { return 0 }
        return try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                let live = try SpeakerIdentitySQL.rows(
                    "SELECT 1 FROM meetings WHERE id = ? AND deleted_at IS NULL",
                    [.integer(meetingID)], db: db
                ) { _ in true }
                guard !live.isEmpty else { return 0 }

                var storedProfileIDs = Set<Int64>()
                for match in matches {
                    guard let normalized = Self.usableVector(match.centroid) else { continue }
                    let profileRows = try SpeakerIdentitySQL.rows(
                        "SELECT name FROM speaker_profiles WHERE id = ?",
                        [.integer(match.profileID)], db: db
                    ) { SpeakerIdentitySQL.text($0, 0) }
                    guard let profileName = profileRows.first.flatMap({ $0 }) else { continue }

                    let trimmedLabel = match.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let targetLabel = trimmedLabel.isEmpty ? profileName : trimmedLabel
                    let embeddingData = SpeakerIdentitySQL.encode(normalized)

                    if try meetingSpeakerRow(meetingID: meetingID, label: targetLabel, db: db) != nil {
                        try SpeakerIdentitySQL.execute(
                            "UPDATE meeting_speakers SET embedding = ?, profile_id = ? WHERE meeting_id = ? AND label = ?",
                            [.blob(embeddingData), .integer(match.profileID), .integer(meetingID), .text(targetLabel)],
                            db: db
                        )
                    } else if let existingByProfile = try otherMeetingSpeakerRow(
                        meetingID: meetingID,
                        profileID: match.profileID,
                        excludingLabel: targetLabel,
                        db: db
                    ) {
                        try SpeakerIdentitySQL.execute(
                            "UPDATE meeting_speakers SET embedding = ? WHERE meeting_id = ? AND label = ?",
                            [.blob(embeddingData), .integer(meetingID), .text(existingByProfile.label)],
                            db: db
                        )
                    } else {
                        try SpeakerIdentitySQL.execute(
                            "INSERT INTO meeting_speakers (meeting_id, label, embedding, profile_id) VALUES (?, ?, ?, ?)",
                            [.integer(meetingID), .text(targetLabel), .blob(embeddingData), .integer(match.profileID)],
                            db: db
                        )
                    }

                    if try storeVoiceprint(
                        embeddingData,
                        profileID: match.profileID,
                        meetingID: meetingID,
                        replaceExisting: true,
                        db: db
                    ) {
                        storedProfileIDs.insert(match.profileID)
                    }
                }
                return storedProfileIDs.count
            }
        }
    }

    private static func transcriptSpeakerNames(in transcript: String) -> Set<String> {
        guard !transcript.isEmpty else { return [] }
        var names = Set<String>()
        for rawLine in transcript.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["),
                  let bracketEnd = line.firstIndex(of: "]") else { continue }
            let remainder = line[line.index(after: bracketEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = remainder.firstIndex(of: ":") else { continue }
            let candidate = remainder[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.count <= 64,
                  !isReservedSpeakerName(candidate),
                  candidate.range(of: #"^local\s+speaker(\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) == nil else {
                continue
            }
            names.insert(candidate)
        }
        return names
    }
}
