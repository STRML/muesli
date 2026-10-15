import Foundation
import SQLite3

public enum FolderSuggestionState: String, Sendable {
    case pending
    case accepted
    case rejected
    case dismissed
    /// Moved by the auto-apply policy. Never counted as a user confirmation.
    case autoApplied = "auto_applied"
}

public struct FolderSuggestion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let meetingID: Int64
    public let folderID: Int64
    public let source: FolderSuggestionSource
    public let confidence: Double
    public let reason: String
    public let state: FolderSuggestionState
}

/// A pending suggestion joined with what the Inbox shows about its meeting.
public struct FolderSuggestionInboxRow: Identifiable, Equatable, Sendable {
    public let suggestion: FolderSuggestion
    public let meetingTitle: String
    public let meetingStartTime: String
    public var id: Int64 { suggestion.id }
}

/// What the classifier needs to know about one meeting.
public struct MeetingClassificationSnapshot: Equatable, Sendable {
    public let meetingID: Int64
    public let folderID: Int64?
    public let status: MeetingStatus?
    public let isDeleted: Bool
    public let evidence: ClassificationEvidence
    public let participantNames: [String]
    /// At most the first `notesLimit` characters of the meeting notes.
    public let notes: String

    public init(
        meetingID: Int64,
        folderID: Int64?,
        status: MeetingStatus?,
        isDeleted: Bool,
        evidence: ClassificationEvidence,
        participantNames: [String],
        notes: String
    ) {
        self.meetingID = meetingID
        self.folderID = folderID
        self.status = status
        self.isDeleted = isDeleted
        self.evidence = evidence
        self.participantNames = participantNames
        self.notes = notes
    }

    public var isEligible: Bool {
        folderID == nil && !isDeleted && (status == .completed || status == .noteOnly)
    }
}

enum FolderClassificationSQL {
    static func migrate(db: OpaquePointer?) throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS folder_suggestions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                folder_id INTEGER NOT NULL REFERENCES meeting_folders(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                confidence REAL NOT NULL,
                reason TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                created_at REAL NOT NULL,
                UNIQUE(meeting_id, folder_id, source)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_folder_suggestions_state ON folder_suggestions(state, meeting_id)",
            "CREATE INDEX IF NOT EXISTS idx_folder_suggestions_folder ON folder_suggestions(folder_id)",
            """
            CREATE TABLE IF NOT EXISTS classification_memory (
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                folder_id INTEGER NOT NULL REFERENCES meeting_folders(id) ON DELETE CASCADE,
                confirmations INTEGER NOT NULL DEFAULT 0,
                contradictions INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                PRIMARY KEY(kind, key, folder_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_classification_memory_folder ON classification_memory(folder_id)",
            // One row per meeting whose current folder has been counted in
            // classification_memory. It makes learning idempotent and lets a later
            // move take back exactly the keys that were counted.
            """
            CREATE TABLE IF NOT EXISTS classification_learned (
                meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
                folder_id INTEGER NOT NULL REFERENCES meeting_folders(id) ON DELETE CASCADE,
                keys_json TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_classification_learned_folder ON classification_learned(folder_id)",
        ]
        for statement in statements {
            try MeetingChatSQL.execute(statement, db: db)
        }
    }

    /// Part of the meeting-history wipe: memory holds attendee addresses and titles.
    static func clear(db: OpaquePointer?) throws {
        for table in ["folder_suggestions", "classification_memory", "classification_learned"] {
            try MeetingChatSQL.execute("DELETE FROM \(table)", db: db)
        }
    }
}

/// Suggestion, memory and learning storage for folder auto-classification.
/// Opens the app database per operation, like `MeetingChatStore`.
public struct FolderClassificationStore: Sendable {
    public static let notesLimit = 1_500
    /// An address on at least this share of meetings with attendees is treated as the user's own.
    static let selfEmailShare = 0.8
    static let selfEmailMinimumMeetings = 5

    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    private func connection<T>(_ operation: (OpaquePointer?) throws -> T) throws -> T {
        try DictationStore(databaseURL: databaseURL).withChatDatabase(operation)
    }

    // MARK: - Reads

    public func snapshot(meetingID: Int64) throws -> MeetingClassificationSnapshot? {
        try connection { db in try snapshot(meetingID: meetingID, db: db) }
    }

    public func selfEmails() throws -> Set<String> {
        try connection { db in try selfEmails(db: db) }
    }

    public func memory(for keys: [ClassificationMemoryKey]) throws -> [ClassificationMemory] {
        try connection { db in try memory(for: keys, db: db) }
    }

    public func pendingSuggestions() throws -> [FolderSuggestionInboxRow] {
        try connection { db in
            try MeetingChatSQL.rows(
                """
                SELECT \(Self.suggestionColumns), m.title, m.start_time
                FROM folder_suggestions s JOIN meetings m ON m.id = s.meeting_id
                WHERE s.state = 'pending' AND m.folder_id IS NULL AND m.deleted_at IS NULL
                ORDER BY m.start_time DESC, s.confidence DESC, s.id
                """,
                db: db
            ) { statement in
                FolderSuggestionInboxRow(
                    suggestion: try Self.suggestion(statement),
                    meetingTitle: MeetingChatSQL.text(statement, 8),
                    meetingStartTime: MeetingChatSQL.text(statement, 9)
                )
            }
        }
    }

    public func pendingMeetingCount() throws -> Int {
        try connection { db in
            try MeetingChatSQL.rows(
                """
                SELECT COUNT(DISTINCT s.meeting_id) FROM folder_suggestions s JOIN meetings m ON m.id = s.meeting_id
                WHERE s.state = 'pending' AND m.folder_id IS NULL AND m.deleted_at IS NULL
                """,
                db: db
            ) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    public func suggestion(id: Int64) throws -> FolderSuggestion? {
        try connection { db in
            try MeetingChatSQL.rows("SELECT \(Self.suggestionColumns) FROM folder_suggestions s WHERE s.id = ?", [.integer(id)], db: db) {
                try Self.suggestion($0)
            }.first
        }
    }

    public func suggestions(meetingID: Int64) throws -> [FolderSuggestion] {
        try connection { db in
            try MeetingChatSQL.rows("SELECT \(Self.suggestionColumns) FROM folder_suggestions s WHERE s.meeting_id = ? ORDER BY s.id", [.integer(meetingID)], db: db) {
                try Self.suggestion($0)
            }
        }
    }

    public func hasAnySuggestion(meetingID: Int64) throws -> Bool {
        try connection { db in
            !(try MeetingChatSQL.rows("SELECT 1 FROM folder_suggestions WHERE meeting_id = ? LIMIT 1", [.integer(meetingID)], db: db) { _ in true }).isEmpty
        }
    }

    /// Unfiled, finished, not deleted meetings, newest first, paged by id.
    public func unfiledMeetingIDs(before afterID: Int64? = nil, limit: Int) throws -> [Int64] {
        try connection { db in
            try MeetingChatSQL.rows(
                """
                SELECT id FROM meetings
                WHERE folder_id IS NULL AND deleted_at IS NULL
                  AND meeting_status IN ('completed', 'note_only') AND id < ?
                ORDER BY id DESC LIMIT ?
                """,
                [.integer(afterID ?? Int64.max), .integer(Int64(limit))],
                db: db
            ) { sqlite3_column_int64($0, 0) }
        }
    }

    // MARK: - Writes

    /// Stores a pending suggestion. Returns false when this meeting, folder and source
    /// already have a suggestion in any state, so a dismissal is never re-created.
    @discardableResult
    public func recordSuggestion(meetingID: Int64, candidate: FolderSuggestionCandidate, now: Date = Date()) throws -> Bool {
        try connection { db in
            try insertSuggestion(meetingID: meetingID, candidate: candidate, state: .pending, now: now, db: db)
        }
    }

    /// Files an unfiled meeting by policy. Records the suggestion as auto-applied and
    /// does not touch classification memory. Returns false, and moves nothing, when
    /// the meeting was filed meanwhile or this suggestion already exists.
    @discardableResult
    public func autoApply(meetingID: Int64, candidate: FolderSuggestionCandidate, now: Date = Date()) throws -> Bool {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard try currentFolder(meetingID: meetingID, db: db) == .some(nil) else { return false }
            guard try insertSuggestion(meetingID: meetingID, candidate: candidate, state: .autoApplied, now: now, db: db) else { return false }
            try MeetingChatSQL.execute(
                "UPDATE meetings SET folder_id = ? WHERE id = ? AND folder_id IS NULL",
                [.integer(candidate.folderID), .integer(meetingID)], db: db
            )
            return sqlite3_changes(db) > 0
        } }
    }

    public func dismissSuggestion(id: Int64) throws {
        try connection { db in
            try MeetingChatSQL.execute("UPDATE folder_suggestions SET state = 'dismissed' WHERE id = ? AND state = 'pending'", [.integer(id)], db: db)
        }
    }

    /// A user's move: files the meeting, then records it with `recordMove`.
    public func moveMeeting(id meetingID: Int64, toFolder folderID: Int64?, now: Date = Date()) throws {
        try DictationStore(databaseURL: databaseURL).moveMeeting(id: meetingID, toFolder: folderID)
        try recordMove(meetingID: meetingID, toFolder: folderID, now: now)
    }

    /// Call after a user moved a meeting with `DictationStore.moveMeeting`: resolves its
    /// suggestions and learns from the move, all or nothing. Learning counts a meeting
    /// once per folder it is filed in; moving it again takes the earlier count back.
    public func recordMove(meetingID: Int64, toFolder folderID: Int64?, now: Date = Date()) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard let snapshot = try snapshot(meetingID: meetingID, db: db), snapshot.folderID == folderID else { return }
            let keys = FolderClassificationRules.memoryKeys(for: snapshot.evidence, selfEmails: try selfEmails(db: db))
            try resolveSuggestions(meetingID: meetingID, movedTo: folderID, keys: keys, now: now, db: db)
            try learn(meetingID: meetingID, folderID: folderID, keys: keys, now: now, db: db)
        } }
    }

    // MARK: - Internals

    private static let suggestionColumns = "s.id, s.meeting_id, s.folder_id, s.source, s.confidence, s.reason, s.state, s.created_at"

    private static func suggestion(_ statement: OpaquePointer?) throws -> FolderSuggestion {
        guard let source = FolderSuggestionSource(rawValue: MeetingChatSQL.text(statement, 3)),
              let state = FolderSuggestionState(rawValue: MeetingChatSQL.text(statement, 6)) else {
            throw NSError(domain: "FolderClassificationDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown folder suggestion row."])
        }
        return FolderSuggestion(
            id: sqlite3_column_int64(statement, 0),
            meetingID: sqlite3_column_int64(statement, 1),
            folderID: sqlite3_column_int64(statement, 2),
            source: source,
            confidence: sqlite3_column_double(statement, 4),
            reason: MeetingChatSQL.text(statement, 5),
            state: state
        )
    }

    private func insertSuggestion(
        meetingID: Int64,
        candidate: FolderSuggestionCandidate,
        state: FolderSuggestionState,
        now: Date,
        db: OpaquePointer?
    ) throws -> Bool {
        try MeetingChatSQL.execute(
            """
            INSERT OR IGNORE INTO folder_suggestions (meeting_id, folder_id, source, confidence, reason, state, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.integer(meetingID), .integer(candidate.folderID), .text(candidate.source.rawValue),
             .real(min(max(candidate.confidence, 0), 1)), .text(candidate.reason), .text(state.rawValue),
             .real(now.timeIntervalSince1970)],
            db: db
        )
        return sqlite3_changes(db) > 0
    }

    /// `.some(nil)` is an unfiled meeting; `nil` is a missing one.
    private func currentFolder(meetingID: Int64, db: OpaquePointer?) throws -> Int64?? {
        try MeetingChatSQL.rows("SELECT folder_id FROM meetings WHERE id = ?", [.integer(meetingID)], db: db) { statement -> Int64? in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        }.first
    }

    private func snapshot(meetingID: Int64, db: OpaquePointer?) throws -> MeetingClassificationSnapshot? {
        let rows = try MeetingChatSQL.rows(
            """
            SELECT title, folder_id, meeting_status, deleted_at, calendar_series_id,
                   SUBSTR(COALESCE(NULLIF(TRIM(formatted_notes), ''), manual_notes, ''), 1, ?)
            FROM meetings WHERE id = ?
            """,
            [.integer(Int64(Self.notesLimit)), .integer(meetingID)],
            db: db
        ) { statement in
            (
                title: MeetingChatSQL.text(statement, 0),
                folderID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1) as Int64?,
                status: MeetingStatus(rawValue: MeetingChatSQL.text(statement, 2)),
                isDeleted: sqlite3_column_type(statement, 3) != SQLITE_NULL,
                seriesID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : MeetingChatSQL.text(statement, 4) as String?,
                notes: MeetingChatSQL.text(statement, 5)
            )
        }
        guard let row = rows.first else { return nil }
        let participants = try MeetingChatSQL.rows(
            """
            SELECT display_name, email_address FROM meeting_participants
            WHERE meeting_id = ? AND is_suppressed = 0 ORDER BY insertion_order
            """,
            [.integer(meetingID)], db: db
        ) { statement in
            (name: MeetingChatSQL.text(statement, 0), email: MeetingChatSQL.text(statement, 1))
        }
        return MeetingClassificationSnapshot(
            meetingID: meetingID,
            folderID: row.folderID,
            status: row.status,
            isDeleted: row.isDeleted,
            evidence: ClassificationEvidence(
                seriesID: row.seriesID,
                emails: participants.map(\.email).filter { !$0.isEmpty },
                title: row.title
            ),
            participantNames: participants.map(\.name).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            notes: String(row.notes.prefix(Self.notesLimit))
        )
    }

    private func selfEmails(db: OpaquePointer?) throws -> Set<String> {
        let normalized = "REPLACE(LOWER(TRIM(p.email_address)), 'mailto:', '')"
        let attended = """
            SELECT DISTINCT p.meeting_id AS meeting_id, \(normalized) AS email
            FROM meeting_participants p JOIN meetings m ON m.id = p.meeting_id
            WHERE p.is_suppressed = 0 AND m.deleted_at IS NULL AND p.email_address LIKE '%@%'
            """
        let total = try MeetingChatSQL.rows("SELECT COUNT(DISTINCT meeting_id) FROM (\(attended))", db: db) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
        guard total >= Self.selfEmailMinimumMeetings else { return [] }
        let threshold = Int((Double(total) * Self.selfEmailShare).rounded(.up))
        let emails = try MeetingChatSQL.rows(
            "SELECT email FROM (\(attended)) GROUP BY email HAVING COUNT(*) >= ?",
            [.integer(Int64(threshold))], db: db
        ) { MeetingChatSQL.text($0, 0) }
        return Set(emails.compactMap(FolderClassificationRules.normalizeEmail))
    }

    private func memory(for keys: [ClassificationMemoryKey], db: OpaquePointer?) throws -> [ClassificationMemory] {
        try keys.flatMap { key in
            try MeetingChatSQL.rows(
                "SELECT folder_id, confirmations, contradictions FROM classification_memory WHERE kind = ? AND key = ?",
                [.text(key.kind.rawValue), .text(key.key)], db: db
            ) { statement in
                ClassificationMemory(
                    kind: key.kind,
                    key: key.key,
                    folderID: sqlite3_column_int64(statement, 0),
                    confirmations: Int(sqlite3_column_int64(statement, 1)),
                    contradictions: Int(sqlite3_column_int64(statement, 2))
                )
            }
        }
    }

    private func resolveSuggestions(
        meetingID: Int64,
        movedTo folderID: Int64?,
        keys: [ClassificationMemoryKey],
        now: Date,
        db: OpaquePointer?
    ) throws {
        let open = try MeetingChatSQL.rows(
            "SELECT \(Self.suggestionColumns) FROM folder_suggestions s WHERE s.meeting_id = ? AND s.state IN ('pending', 'auto_applied')",
            [.integer(meetingID)], db: db
        ) { try Self.suggestion($0) }
        for suggestion in open {
            if suggestion.folderID == folderID {
                if suggestion.state == .pending { try setState(.accepted, id: suggestion.id, db: db) }
                continue
            }
            // Moving to Unfiled leaves a pending suggestion open but undoes an auto-apply.
            guard folderID != nil || suggestion.state == .autoApplied else { continue }
            try setState(.rejected, id: suggestion.id, db: db)
            guard let kind = suggestion.source.memoryKind else { continue }
            for key in keys where key.kind == kind {
                try MeetingChatSQL.execute(
                    """
                    UPDATE classification_memory SET contradictions = contradictions + 1, updated_at = ?
                    WHERE kind = ? AND key = ? AND folder_id = ?
                    """,
                    [.real(now.timeIntervalSince1970), .text(kind.rawValue), .text(key.key), .integer(suggestion.folderID)],
                    db: db
                )
            }
        }
    }

    private func setState(_ state: FolderSuggestionState, id: Int64, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("UPDATE folder_suggestions SET state = ? WHERE id = ?", [.text(state.rawValue), .integer(id)], db: db)
    }

    private struct LearnedKey: Codable {
        let kind: String
        let key: String
    }

    private func learn(meetingID: Int64, folderID: Int64?, keys: [ClassificationMemoryKey], now: Date, db: OpaquePointer?) throws {
        let previous = try MeetingChatSQL.rows(
            "SELECT folder_id, keys_json FROM classification_learned WHERE meeting_id = ?",
            [.integer(meetingID)], db: db
        ) { (folderID: sqlite3_column_int64($0, 0), keys: MeetingChatSQL.text($0, 1)) }.first
        if let previous, previous.folderID == folderID { return }
        if let previous {
            for learned in (try? MeetingChatSQL.decode([LearnedKey].self, previous.keys)) ?? [] {
                try MeetingChatSQL.execute(
                    """
                    UPDATE classification_memory SET confirmations = MAX(confirmations - 1, 0), updated_at = ?
                    WHERE kind = ? AND key = ? AND folder_id = ?
                    """,
                    [.real(now.timeIntervalSince1970), .text(learned.kind), .text(learned.key), .integer(previous.folderID)],
                    db: db
                )
            }
            try MeetingChatSQL.execute("DELETE FROM classification_learned WHERE meeting_id = ?", [.integer(meetingID)], db: db)
        }
        guard let folderID else { return }
        for key in keys {
            try MeetingChatSQL.execute(
                """
                INSERT INTO classification_memory (kind, key, folder_id, confirmations, contradictions, updated_at)
                VALUES (?, ?, ?, 1, 0, ?)
                ON CONFLICT(kind, key, folder_id) DO UPDATE SET
                    confirmations = confirmations + 1, updated_at = excluded.updated_at
                """,
                [.text(key.kind.rawValue), .text(key.key), .integer(folderID), .real(now.timeIntervalSince1970)],
                db: db
            )
        }
        let learned = keys.map { LearnedKey(kind: $0.kind.rawValue, key: $0.key) }
        try MeetingChatSQL.execute(
            "INSERT INTO classification_learned (meeting_id, folder_id, keys_json) VALUES (?, ?, ?)",
            [.integer(meetingID), .integer(folderID), .text(try MeetingChatSQL.encode(learned))],
            db: db
        )
    }
}
