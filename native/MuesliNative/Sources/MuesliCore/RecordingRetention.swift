import Foundation
import SQLite3

// Audio retention by disk budget. Transcripts, notes and meeting rows are kept
// forever; only saved meeting audio is pruned, oldest first, once the recordings
// directory exceeds the user's budget. Nothing here ever logs transcript text.

public struct RecordingFile: Equatable, Sendable {
    public let path: String
    /// nil when the file no longer exists.
    public let bytes: Int64?

    public init(path: String, bytes: Int64?) {
        self.path = path
        self.bytes = bytes
    }
}

public struct RecordingCandidate: Sendable {
    public let id: Int64
    public let startDate: Date
    public let files: [RecordingFile]
    public let status: MeetingStatus
    public let hasTranscript: Bool
    public let pinned: Bool
    /// Recording, transcribing or resumable right now.
    public let isActive: Bool

    public init(
        id: Int64, startDate: Date, files: [RecordingFile], status: MeetingStatus,
        hasTranscript: Bool, pinned: Bool, isActive: Bool
    ) {
        self.id = id
        self.startDate = startDate
        self.files = files
        self.status = status
        self.hasTranscript = hasTranscript
        self.pinned = pinned
        self.isActive = isActive
    }
}

public struct PlannedRecordingDeletion: Equatable, Sendable {
    public let meetingID: Int64
    public let path: String
    public let bytes: Int64
}

public struct RecordingRetentionResult: Equatable, Sendable {
    public var deletedFiles = 0
    public var freedBytes: Int64 = 0
    public var failures = 0
    public var repairedPaths = 0

    public init() {}
}

public enum RecordingRetentionPlanner {
    /// Absolute path with symlinks resolved, even when the leaf (or several
    /// trailing components) does not exist: the nearest existing ancestor is
    /// resolved and the remainder appended.
    static func resolvedPath(_ path: String) -> String {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        // attributesOfItem uses lstat, so a dangling symlink still counts as existing.
        while (try? fm.attributesOfItem(atPath: url.path)) == nil, url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.path
    }

    /// True only when the file resolves to a location strictly inside `directory`.
    public static func isContained(path: String, in directory: URL) -> Bool {
        let root = resolvedPath(directory.path)
        let candidate = resolvedPath(path)
        return candidate != root && candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public static func plan(
        candidates: [RecordingCandidate],
        budgetBytes: Int64,
        minimumAge: TimeInterval,
        now: Date,
        recordingsDirectory: URL
    ) -> [PlannedRecordingDeletion] {
        guard budgetBytes > 0 else { return [] }

        func eligible(_ c: RecordingCandidate) -> Bool {
            c.status == .completed && c.hasTranscript && !c.pinned && !c.isActive
                && now.timeIntervalSince(c.startDate) >= minimumAge
        }
        func contained(_ c: RecordingCandidate) -> [(original: String, resolved: String, bytes: Int64)] {
            var seen = Set<String>()
            return c.files.compactMap { file in
                guard isContained(path: file.path, in: recordingsDirectory) else { return nil }
                let resolved = resolvedPath(file.path)
                guard seen.insert(resolved).inserted else { return nil }
                return (file.path, resolved, max(file.bytes ?? 0, 0))
            }
        }

        var protectedPaths = Set<String>()
        var sizes: [String: Int64] = [:]
        for c in candidates {
            for file in contained(c) {
                sizes[file.resolved] = max(sizes[file.resolved] ?? 0, file.bytes)
                if !eligible(c) { protectedPaths.insert(file.resolved) }
            }
        }
        var total = sizes.values.reduce(0, +)
        guard total > budgetBytes else { return [] }

        var planned: [PlannedRecordingDeletion] = []
        var plannedPaths = Set<String>()
        let oldestFirst = candidates.filter(eligible).sorted {
            ($0.startDate, $0.id) < ($1.startDate, $1.id)
        }
        for c in oldestFirst {
            for file in contained(c) where !protectedPaths.contains(file.resolved) && plannedPaths.insert(file.resolved).inserted {
                planned.append(PlannedRecordingDeletion(meetingID: c.id, path: file.original, bytes: file.bytes))
                total -= file.bytes
            }
            if total <= budgetBytes { break }
        }
        return planned
    }
}

enum RecordingRetentionSchema {
    static func migrate(db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS recording_prune_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id INTEGER,
            path TEXT,
            bytes INTEGER,
            reason TEXT,
            pruned_at REAL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RecordingRetentionService.error(db)
        }
    }
}

public final class RecordingRetentionService: @unchecked Sendable {
    private static let pathColumns = ["saved_recording_path", "mic_audio_path", "system_audio_path"]

    private let databaseURL: URL
    private let recordingsDirectory: URL
    private let removeItem: @Sendable (URL) throws -> Void

    /// Deletes the file outright. Pruning exists to stay under a disk budget, and a file moved to the
    /// Trash would keep using that space until the Trash is emptied.
    public static let removePermanently: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.removeItem(at: url)
    }

    public init(
        databaseURL: URL,
        recordingsDirectory: URL,
        removeItem: @escaping @Sendable (URL) throws -> Void = RecordingRetentionService.removePermanently
    ) {
        self.databaseURL = databaseURL
        self.recordingsDirectory = recordingsDirectory
        self.removeItem = removeItem
    }

    // MARK: - Public API

    public func run(
        budgetBytes: Int64,
        minimumAgeDays: Int,
        now: Date = Date(),
        activeMeetingIDs: Set<Int64> = []
    ) throws -> RecordingRetentionResult {
        var result = RecordingRetentionResult()
        guard budgetBytes > 0 else { return result }
        let db = try open()
        defer { sqlite3_close(db) }

        result.repairedPaths = try repairDanglingPaths(db: db, activeMeetingIDs: activeMeetingIDs, now: now)
        let candidates = try loadCandidates(db: db, activeMeetingIDs: activeMeetingIDs)
        let plan = RecordingRetentionPlanner.plan(
            candidates: candidates,
            budgetBytes: budgetBytes,
            minimumAge: TimeInterval(max(minimumAgeDays, 1)) * 86_400,
            now: now,
            recordingsDirectory: recordingsDirectory
        )
        for item in plan {
            execute(item, db: db, now: now, result: &result)
        }
        return result
    }

    /// Total bytes of distinct saved recording files inside the recordings directory.
    public func usageBytes() throws -> Int64 {
        let db = try open()
        defer { sqlite3_close(db) }
        var sizes: [String: Int64] = [:]
        for candidate in try loadCandidates(db: db, activeMeetingIDs: []) {
            for file in candidate.files where RecordingRetentionPlanner.isContained(path: file.path, in: recordingsDirectory) {
                sizes[RecordingRetentionPlanner.resolvedPath(file.path)] = file.bytes ?? 0
            }
        }
        return sizes.values.reduce(0, +)
    }

    public func setPinned(_ pinned: Bool, meetingID: Int64) throws {
        let db = try open()
        defer { sqlite3_close(db) }
        try run("UPDATE meetings SET recording_pinned = ? WHERE id = ?", db: db) { stmt in
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, meetingID)
        }
    }

    public func isPinned(meetingID: Int64) throws -> Bool {
        let db = try open()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT recording_pinned FROM meetings WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw Self.error(db)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, meetingID)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) != 0
    }

    // MARK: - Execution

    private func execute(_ item: PlannedRecordingDeletion, db: OpaquePointer?, now: Date, result: inout RecordingRetentionResult) {
        // Re-check at delete time: the plan may be stale and a symlink may have appeared.
        guard RecordingRetentionPlanner.isContained(path: item.path, in: recordingsDirectory) else {
            result.failures += 1
            return
        }
        let url = URL(fileURLWithPath: item.path)
        let existed = (try? FileManager.default.attributesOfItem(atPath: item.path)) != nil
        if existed {
            do { try removeItem(url) } catch {
                result.failures += 1
                return
            }
        }
        // Only now that the file is gone do the DB paths change.
        let reason = existed ? "budget" : "missing_file"
        do {
            try clearPath(item.path, meetingID: item.meetingID, bytes: existed ? item.bytes : 0, reason: reason, db: db, now: now)
            if existed {
                result.deletedFiles += 1
                result.freedBytes += item.bytes
            }
        } catch {
            // The file is already gone; the next run repairs the stale path.
            result.failures += 1
        }
    }

    private func clearPath(_ path: String, meetingID: Int64, bytes: Int64, reason: String, db: OpaquePointer?, now: Date) throws {
        try run("BEGIN IMMEDIATE", db: db) { _ in }
        do {
            for column in Self.pathColumns {
                try run("UPDATE meetings SET \(column) = NULL WHERE \(column) = ?", db: db) { sqlite3_bind_text($0, 1, path, -1, Self.transient) }
            }
            try run(
                "INSERT INTO recording_prune_log (meeting_id, path, bytes, reason, pruned_at) VALUES (?, ?, ?, ?, ?)",
                db: db
            ) { stmt in
                sqlite3_bind_int64(stmt, 1, meetingID)
                sqlite3_bind_text(stmt, 2, path, -1, Self.transient)
                sqlite3_bind_int64(stmt, 3, bytes)
                sqlite3_bind_text(stmt, 4, reason, -1, Self.transient)
                sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
            }
            try run("COMMIT", db: db) { _ in }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// A crash between deleting a file and updating the DB leaves a path that
    /// points at nothing. Clear those for finished meetings.
    private func repairDanglingPaths(db: OpaquePointer?, activeMeetingIDs: Set<Int64>, now: Date) throws -> Int {
        var repaired = 0
        for candidate in try loadCandidates(db: db, activeMeetingIDs: activeMeetingIDs)
        where candidate.status == .completed && !candidate.isActive {
            for file in candidate.files
            where file.bytes == nil && RecordingRetentionPlanner.isContained(path: file.path, in: recordingsDirectory) {
                try clearPath(file.path, meetingID: candidate.id, bytes: 0, reason: "repair_missing", db: db, now: now)
                repaired += 1
            }
        }
        return repaired
    }

    // MARK: - SQLite

    private func loadCandidates(db: OpaquePointer?, activeMeetingIDs: Set<Int64>) throws -> [RecordingCandidate] {
        let sql = """
        SELECT id, start_time, saved_recording_path, mic_audio_path, system_audio_path, meeting_status,
               COALESCE(TRIM(raw_transcript, ' ' || char(9) || char(10) || char(13)), '') != '',
               recording_pinned,
               EXISTS(SELECT 1 FROM meeting_resume_snapshots r WHERE r.meeting_id = meetings.id)
        FROM meetings
        WHERE saved_recording_path IS NOT NULL OR mic_audio_path IS NOT NULL OR system_audio_path IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Self.error(db) }
        defer { sqlite3_finalize(stmt) }
        let formatter = ISO8601DateFormatter()
        var candidates: [RecordingCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            // An unparseable start time sorts as "now" so the age rule protects it.
            let start = text(stmt, 1).flatMap { formatter.date(from: $0) } ?? Date.distantFuture
            let files: [RecordingFile] = (2...4).compactMap { index in
                guard let path = text(stmt, Int32(index)), !path.isEmpty else { return nil }
                return RecordingFile(path: path, bytes: fileSize(path))
            }
            candidates.append(RecordingCandidate(
                id: id,
                startDate: start,
                files: files,
                status: text(stmt, 5).flatMap(MeetingStatus.init(rawValue:)) ?? .failed,
                hasTranscript: sqlite3_column_int(stmt, 6) != 0,
                pinned: sqlite3_column_int(stmt, 7) != 0,
                isActive: activeMeetingIDs.contains(id) || sqlite3_column_int(stmt, 8) != 0
            ))
        }
        return candidates
    }

    private func fileSize(_ path: String) -> Int64? {
        guard RecordingRetentionPlanner.isContained(path: path, in: recordingsDirectory) else { return nil }
        let resolved = RecordingRetentionPlanner.resolvedPath(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func open() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            let failure = Self.error(db)
            sqlite3_close(db)
            throw failure
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    private func run(_ sql: String, db: OpaquePointer?, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Self.error(db) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Self.error(db) }
    }

    static func error(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MuesliDB",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
