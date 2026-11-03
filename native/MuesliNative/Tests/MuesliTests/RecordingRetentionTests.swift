import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

private let mb: Int64 = 1_000_000
private let day: TimeInterval = 86_400

@Suite("Recording retention planner")
struct RecordingRetentionPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let dir = URL(fileURLWithPath: "/tmp/muesli-ret-planner/meeting-recordings", isDirectory: true)

    private func candidate(
        _ id: Int64,
        daysOld: Double = 30,
        files: [(String, Int64?)]? = nil,
        status: MeetingStatus = .completed,
        hasTranscript: Bool = true,
        pinned: Bool = false,
        active: Bool = false
    ) -> RecordingCandidate {
        let fs = files ?? [("\(dir.path)/m\(id).m4a", 10 * mb)]
        return RecordingCandidate(
            id: id,
            startDate: now.addingTimeInterval(-daysOld * day),
            files: fs.map { RecordingFile(path: $0.0, bytes: $0.1) },
            status: status,
            hasTranscript: hasTranscript,
            pinned: pinned,
            isActive: active
        )
    }

    private func plan(_ c: [RecordingCandidate], budget: Int64, minAgeDays: Int = 7) -> [PlannedRecordingDeletion] {
        RecordingRetentionPlanner.plan(
            candidates: c, budgetBytes: budget, minimumAge: TimeInterval(minAgeDays) * day,
            now: now, recordingsDirectory: dir
        )
    }

    @Test("budget 0 prunes nothing")
    func budgetZero() {
        #expect(plan([candidate(1), candidate(2)], budget: 0).isEmpty)
    }

    @Test("negative budget prunes nothing")
    func budgetNegative() {
        #expect(plan([candidate(1)], budget: -5).isEmpty)
    }

    @Test("under budget prunes nothing")
    func underBudget() {
        #expect(plan([candidate(1), candidate(2)], budget: 20 * mb).isEmpty)
    }

    @Test("over budget prunes oldest first and stops at budget")
    func oldestFirstStopsAtBudget() {
        let c = [
            candidate(1, daysOld: 10), candidate(2, daysOld: 90),
            candidate(3, daysOld: 50), candidate(4, daysOld: 20),
        ]
        // total 40 MB, budget 25 MB -> two oldest (2 then 3) leave 20 MB.
        let result = plan(c, budget: 25 * mb)
        #expect(result.map(\.meetingID) == [2, 3])
        #expect(result.map(\.bytes) == [10 * mb, 10 * mb])
    }

    @Test("pinned meetings are skipped")
    func pinnedSkipped() {
        let result = plan([candidate(1, daysOld: 90, pinned: true), candidate(2, daysOld: 40)], budget: 10 * mb)
        #expect(result.map(\.meetingID) == [2])
    }

    @Test("meetings younger than the minimum age are skipped")
    func youngSkipped() {
        let result = plan([candidate(1, daysOld: 2), candidate(2, daysOld: 30)], budget: 1 * mb, minAgeDays: 7)
        #expect(result.map(\.meetingID) == [2])
    }

    @Test("meetings without a transcript are skipped")
    func noTranscriptSkipped() {
        let result = plan([candidate(1, daysOld: 90, hasTranscript: false), candidate(2, daysOld: 40)], budget: 1 * mb)
        #expect(result.map(\.meetingID) == [2])
    }

    @Test("active and non-completed meetings are skipped")
    func activeSkipped() {
        let c = [
            candidate(1, daysOld: 90, active: true),
            candidate(2, daysOld: 89, status: .recording),
            candidate(3, daysOld: 88, status: .processing),
            candidate(4, daysOld: 87, status: .failed),
            candidate(5, daysOld: 86, status: .noteOnly),
            candidate(6, daysOld: 40),
        ]
        #expect(plan(c, budget: 1 * mb).map(\.meetingID) == [6])
    }

    @Test("paths outside the recordings directory are refused")
    func outsideRefused() {
        let c = [
            candidate(1, daysOld: 90, files: [("/Users/someone/Documents/keep.m4a", 50 * mb)]),
            candidate(2, daysOld: 80, files: [("\(dir.path)/../escape.m4a", 50 * mb)]),
            candidate(3, daysOld: 70, files: [("\(dir.path)-evil/x.m4a", 50 * mb)]),
        ]
        #expect(plan(c, budget: 1).isEmpty)
    }

    @Test("a missing file counts as zero bytes and is still cleared")
    func missingFile() {
        let c = [
            candidate(1, daysOld: 90, files: [("\(dir.path)/gone.m4a", nil)]),
            candidate(2, daysOld: 80),
        ]
        let result = plan(c, budget: 5 * mb)
        #expect(result.map(\.meetingID) == [1, 2])
        #expect(result.first?.bytes == 0)
    }

    @Test("a file shared with a protected meeting is not deleted")
    func sharedFileProtected() {
        let shared = "\(dir.path)/shared.m4a"
        let c = [
            candidate(1, daysOld: 90, files: [(shared, 10 * mb)]),
            candidate(2, daysOld: 80, files: [(shared, 10 * mb)], pinned: true),
        ]
        #expect(plan(c, budget: 1).isEmpty)
    }

    @Test("a duplicate path is counted and planned once")
    func duplicatePathOnce() {
        let p = "\(dir.path)/dup.m4a"
        let result = plan([candidate(1, daysOld: 90, files: [(p, 10 * mb), (p, 10 * mb)])], budget: 1)
        #expect(result.count == 1)
    }

    @Test("containment resolves symlinks")
    func containmentSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-ret-sym-\(UUID().uuidString)")
        let recordings = root.appendingPathComponent("meeting-recordings", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = outside.appendingPathComponent("real.m4a")
        try Data("x".utf8).write(to: target)
        let link = recordings.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let inside = recordings.appendingPathComponent("ok.m4a")
        try Data("x".utf8).write(to: inside)

        #expect(!RecordingRetentionPlanner.isContained(path: link.path, in: recordings))
        #expect(RecordingRetentionPlanner.isContained(path: inside.path, in: recordings))
        #expect(!RecordingRetentionPlanner.isContained(path: recordings.path, in: recordings))
    }
}

@Suite("Recording retention service", .serialized)
struct RecordingRetentionServiceTests {
    private final class Env {
        let root: URL
        let recordings: URL
        let store: DictationStore
        let service: RecordingRetentionService
        final class FailSet: @unchecked Sendable { var paths: Set<String> = [] }
        let fail = FailSet()
        var failPaths: Set<String> {
            get { fail.paths }
            set { fail.paths = newValue }
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-ret-\(UUID().uuidString)", isDirectory: true)
            recordings = root.appendingPathComponent("meeting-recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            store = DictationStore(databaseURL: root.appendingPathComponent("muesli.db"))
            try store.migrateIfNeeded()
            let fail = self.fail
            service = RecordingRetentionService(
                databaseURL: root.appendingPathComponent("muesli.db"),
                recordingsDirectory: recordings,
                removeItem: { url in
                    if fail.paths.contains(url.path) || fail.paths.contains(url.resolvingSymlinksInPath().path) {
                        throw NSError(domain: "test", code: 1)
                    }
                    try FileManager.default.removeItem(at: url)
                }
            )
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func meeting(daysOld: Double, bytes: Int = 1000, transcript: String = "secret words", name: String = UUID().uuidString, withFile: Bool = true) throws -> (id: Int64, path: String) {
            let path = recordings.appendingPathComponent("\(name).m4a").path
            if withFile { try Data(count: bytes).write(to: URL(fileURLWithPath: path)) }
            let start = Date().addingTimeInterval(-daysOld * day)
            let id = try store.insertMeeting(
                title: "M", calendarEventID: nil, startTime: start, endTime: start.addingTimeInterval(60),
                rawTranscript: transcript, formattedNotes: "Notes body", micAudioPath: nil, systemAudioPath: nil,
                savedRecordingPath: path
            )
            return (id, path)
        }

        func sql(_ statement: String) {
            var db: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("muesli.db").path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
        }

        func scalar(_ statement: String) -> String? {
            var db: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("muesli.db").path, &db) == SQLITE_OK else { return nil }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }

        func run(budget: Int64, minAgeDays: Int = 7, active: Set<Int64> = []) throws -> RecordingRetentionResult {
            try service.run(budgetBytes: budget, minimumAgeDays: minAgeDays, now: Date(), activeMeetingIDs: active)
        }
    }

    @Test("budget 0 touches nothing, even dangling paths")
    func budgetZeroNoop() throws {
        let env = try Env()
        let m = try env.meeting(daysOld: 90)
        let dangling = try env.meeting(daysOld: 90, withFile: false)
        let result = try env.run(budget: 0)
        #expect(result.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: m.path))
        #expect(try env.store.meeting(id: dangling.id)?.savedRecordingPath == dangling.path)
    }

    @Test("under budget prunes nothing")
    func underBudget() throws {
        let env = try Env()
        let m = try env.meeting(daysOld: 90, bytes: 1000)
        let result = try env.run(budget: 1_000_000)
        #expect(result.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: m.path))
    }

    @Test("over budget prunes oldest first and stops at budget")
    func oldestFirst() throws {
        let env = try Env()
        let a = try env.meeting(daysOld: 100, bytes: 1000)
        let b = try env.meeting(daysOld: 50, bytes: 1000)
        let c = try env.meeting(daysOld: 20, bytes: 1000)
        let result = try env.run(budget: 1500)
        #expect(result.deletedFiles == 2)
        #expect(result.freedBytes == 2000)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: c.path))
        #expect(try env.store.meeting(id: a.id)?.savedRecordingPath == nil)
        #expect(try env.store.meeting(id: c.id)?.savedRecordingPath == c.path)
    }

    @Test("pinned, young, transcript-less and active meetings are skipped")
    func skips() throws {
        let env = try Env()
        let pinned = try env.meeting(daysOld: 100)
        let young = try env.meeting(daysOld: 1)
        let empty = try env.meeting(daysOld: 90, transcript: "   ")
        let active = try env.meeting(daysOld: 80)
        let resumable = try env.meeting(daysOld: 70)
        let processing = try env.meeting(daysOld: 60)
        try env.service.setPinned(true, meetingID: pinned.id)
        env.sql("INSERT INTO meeting_resume_snapshots (meeting_id, start_time) VALUES (\(resumable.id), '2020-01-01T00:00:00Z')")
        env.sql("UPDATE meetings SET meeting_status = 'processing' WHERE id = \(processing.id)")
        let result = try env.run(budget: 1, active: [active.id])
        #expect(result.deletedFiles == 0)
        for m in [pinned, young, empty, active, resumable, processing] {
            #expect(FileManager.default.fileExists(atPath: m.path))
        }
    }

    @Test("a path outside the recordings directory is refused and left alone")
    func outsideRefused() throws {
        let env = try Env()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-ret-outside-\(UUID().uuidString).m4a")
        try Data(count: 5000).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let start = Date().addingTimeInterval(-90 * day)
        let id = try env.store.insertMeeting(
            title: "Out", calendarEventID: nil, startTime: start, endTime: start.addingTimeInterval(60),
            rawTranscript: "words", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil,
            savedRecordingPath: outside.path
        )
        let result = try env.run(budget: 1)
        #expect(result.deletedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try env.store.meeting(id: id)?.savedRecordingPath == outside.path)
    }

    @Test("a missing file is cleared from the DB without error")
    func missingFile() throws {
        let env = try Env()
        let gone = try env.meeting(daysOld: 90, withFile: false)
        let other = try env.meeting(daysOld: 80, bytes: 1000)
        let result = try env.run(budget: 500)
        #expect(result.failures == 0)
        #expect(try env.store.meeting(id: gone.id)?.savedRecordingPath == nil)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test("a failed delete leaves DB paths unchanged and the run continues")
    func deleteFailureContinues() throws {
        let env = try Env()
        let a = try env.meeting(daysOld: 100)
        let b = try env.meeting(daysOld: 90)
        env.failPaths = [a.path, URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path]
        let result = try env.run(budget: 1)
        #expect(result.failures == 1)
        #expect(result.deletedFiles == 1)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(try env.store.meeting(id: a.id)?.savedRecordingPath == a.path)
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(try env.store.meeting(id: b.id)?.savedRecordingPath == nil)
    }

    @Test("crash repair clears dangling paths on the next run")
    func crashRepair() throws {
        let env = try Env()
        let crashed = try env.meeting(daysOld: 3, withFile: false) // young, file already gone
        let kept = try env.meeting(daysOld: 3, bytes: 100)
        let result = try env.run(budget: 1_000_000)
        #expect(result.repairedPaths == 1)
        #expect(try env.store.meeting(id: crashed.id)?.savedRecordingPath == nil)
        #expect(try env.store.meeting(id: kept.id)?.savedRecordingPath == kept.path)
    }

    @Test("transcript, notes and the meeting row survive pruning")
    func transcriptSurvives() throws {
        let env = try Env()
        let m = try env.meeting(daysOld: 90, transcript: "the full transcript")
        _ = try env.run(budget: 1)
        let row = try #require(try env.store.meeting(id: m.id))
        #expect(row.rawTranscript == "the full transcript")
        #expect(row.formattedNotes == "Notes body")
        #expect(row.savedRecordingPath == nil)
    }

    @Test("prune_log gets a row per file and never the transcript")
    func pruneLog() throws {
        let env = try Env()
        let m = try env.meeting(daysOld: 90, bytes: 1234, transcript: "private words")
        _ = try env.run(budget: 1)
        #expect(env.scalar("SELECT COUNT(*) FROM recording_prune_log") == "1")
        #expect(env.scalar("SELECT bytes FROM recording_prune_log") == "1234")
        #expect(env.scalar("SELECT meeting_id FROM recording_prune_log") == "\(m.id)")
        #expect(env.scalar("SELECT path FROM recording_prune_log") == m.path)
        #expect(env.scalar("SELECT reason FROM recording_prune_log")?.isEmpty == false)
    }

    @Test("running twice is idempotent")
    func idempotent() throws {
        let env = try Env()
        _ = try env.meeting(daysOld: 90)
        _ = try env.run(budget: 1)
        let second = try env.run(budget: 1)
        #expect(second.deletedFiles == 0)
        #expect(env.scalar("SELECT COUNT(*) FROM recording_prune_log") == "1")
    }

    @Test("usage sums unique recording files")
    func usage() throws {
        let env = try Env()
        _ = try env.meeting(daysOld: 5, bytes: 700)
        _ = try env.meeting(daysOld: 5, bytes: 300)
        #expect(try env.service.usageBytes() == 1000)
    }

    @Test("pin round-trips")
    func pinRoundTrip() throws {
        let env = try Env()
        let m = try env.meeting(daysOld: 5)
        #expect(try env.service.isPinned(meetingID: m.id) == false)
        try env.service.setPinned(true, meetingID: m.id)
        #expect(try env.service.isPinned(meetingID: m.id) == true)
        try env.service.setPinned(false, meetingID: m.id)
        #expect(try env.service.isPinned(meetingID: m.id) == false)
    }
}

@Suite("Recording retention schema and config")
struct RecordingRetentionSchemaTests {
    private func makeLegacyStore() throws -> (DictationStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-ret-legacy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return (DictationStore(databaseURL: url), url)
    }

    private func columnNames(_ url: URL, table: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(stmt, 1))) }
        return names
    }

    @Test("legacy database migrates twice with the pin column and prune log")
    func legacyMigratesTwice() throws {
        let (store, url) = try makeLegacyStore()
        try store.migrateIfNeeded()
        try store.migrateIfNeeded()
        #expect(columnNames(url, table: "meetings").contains("recording_pinned"))
        #expect(columnNames(url, table: "recording_prune_log") == ["id", "meeting_id", "path", "bytes", "reason", "pruned_at"])
        let start = Date()
        let id = try store.insertMeeting(
            title: "Legacy", calendarEventID: nil, startTime: start, endTime: start, rawTranscript: "t",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let service = RecordingRetentionService(databaseURL: url, recordingsDirectory: url.deletingLastPathComponent())
        #expect(try service.isPinned(meetingID: id) == false)
    }

    @Test("config defaults to no pruning and a 7 day minimum age")
    func configDefaults() throws {
        let config = AppConfig()
        #expect(config.recordingsBudgetGB == 0)
        #expect(config.recordingsMinimumAgeDays == 7)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.recordingsBudgetGB == 0)
        #expect(decoded.recordingsMinimumAgeDays == 7)
    }

    @Test("negative or garbage config values decode to no pruning")
    func configGarbage() throws {
        for json in [
            #"{"recordings_budget_gb": -5, "recordings_minimum_age_days": -1}"#,
            #"{"recordings_budget_gb": "lots", "recordings_minimum_age_days": "x"}"#,
            #"{"recordings_budget_gb": null, "recordings_minimum_age_days": null}"#,
            #"{"recordings_budget_gb": 1.5e99, "recordings_minimum_age_days": 0}"#,
        ] {
            let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            #expect(decoded.recordingsBudgetGB == 0, "\(json)")
            #expect(decoded.recordingsMinimumAgeDays == 7, "\(json)")
        }
    }

    @Test("valid config values round-trip")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.recordingsBudgetGB = 50
        config.recordingsMinimumAgeDays = 14
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.recordingsBudgetGB == 50)
        #expect(decoded.recordingsMinimumAgeDays == 14)
    }
}
