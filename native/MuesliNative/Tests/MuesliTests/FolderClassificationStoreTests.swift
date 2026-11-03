import Testing
import Foundation
import MuesliCore
import SQLite3

/// Shared fixtures for folder-classification tests that need a real database.
struct FolderClassificationFixture {
    let store: DictationStore
    let classification: FolderClassificationStore

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-classify-\(UUID().uuidString).db")
        store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        classification = FolderClassificationStore(databaseURL: url)
    }

    @discardableResult
    func meeting(
        title: String = "Rush weekly sync",
        series: String? = nil,
        emails: [String] = [],
        notes: String = "",
        status: MeetingStatus = .completed
    ) throws -> Int64 {
        let now = Date()
        let occurrence = series.map {
            CalendarOccurrenceReference(provider: .eventKit, calendarID: "cal", eventID: "event-\(UUID().uuidString)", seriesID: $0, originalStartTime: now)
        }
        let id = try store.insertMeeting(
            title: title,
            calendarEventID: occurrence?.eventID,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "transcript",
            formattedNotes: notes,
            micAudioPath: nil,
            systemAudioPath: nil,
            calendarOccurrence: occurrence
        )
        if !emails.isEmpty {
            try store.attachCalendarMeetingParticipants(
                meetingID: id,
                participants: emails.map { MeetingParticipantDraft(participantIdentifier: "calendar:\($0)", displayName: $0, emailAddress: "mailto:\($0)") }
            )
        }
        if status != .completed { try store.updateMeetingStatus(id: id, status: status) }
        return id
    }

    func memory(_ kind: ClassificationMemoryKind, _ key: String) throws -> [ClassificationMemory] {
        try classification.memory(for: [ClassificationMemoryKey(kind: kind, key: key)])
    }

    func rawCount(_ table: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

@Suite("Folder classification store", .serialized)
struct FolderClassificationStoreTests {
    private func candidate(_ folderID: Int64, _ source: FolderSuggestionSource = .series) -> FolderSuggestionCandidate {
        FolderSuggestionCandidate(folderID: folderID, source: source, confidence: 0.9, reason: "reason")
    }

    // MARK: - Schema

    @Test("legacy database gains the classification tables and migrates twice")
    func legacyMigratesTwice() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-classify-legacy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let legacy = """
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
        INSERT INTO meetings (title, start_time) VALUES ('Old meeting', '2025-01-01T00:00:00Z');
        """
        #expect(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        try store.migrateIfNeeded()

        let classification = FolderClassificationStore(databaseURL: url)
        let folder = try store.createFolder(name: "Rush")
        #expect(try classification.recordSuggestion(meetingID: 1, candidate: candidate(folder)))
        #expect(try classification.pendingMeetingCount() == 1)
        try classification.moveMeeting(id: 1, toFolder: folder)
        #expect(try classification.memory(for: [.init(kind: .title, key: "old meeting")]).first?.confirmations == 1)
    }

    @Test("deleting a folder cascades its suggestions, memory and learned markers")
    func folderDeleteCascades() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let filed = try fixture.meeting(series: "s1")
        let unfiled = try fixture.meeting(series: "s1")
        try fixture.classification.moveMeeting(id: filed, toFolder: rush)
        try fixture.classification.recordSuggestion(meetingID: unfiled, candidate: candidate(rush))
        #expect(try fixture.rawCount("folder_suggestions") == 1)
        #expect(try fixture.rawCount("classification_memory") > 0)

        try fixture.store.deleteFolder(id: rush)

        #expect(try fixture.rawCount("folder_suggestions") == 0)
        #expect(try fixture.rawCount("classification_memory") == 0)
        #expect(try fixture.rawCount("classification_learned") == 0)
    }

    @Test("deleting a meeting cascades its suggestions")
    func meetingDeleteCascades() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting()
        try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush))
        var db: OpaquePointer?
        #expect(sqlite3_open(fixture.store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA foreign_keys=ON; DELETE FROM meetings WHERE id = \(id)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(try fixture.rawCount("folder_suggestions") == 0)
    }

    @Test("clearing meeting history also clears suggestions and learned memory")
    func historyWipeClearsMemory() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let filed = try fixture.meeting(series: "s1", emails: ["a@x.com"])
        try fixture.classification.moveMeeting(id: filed, toFolder: rush)
        let unfiled = try fixture.meeting()
        try fixture.classification.recordSuggestion(meetingID: unfiled, candidate: candidate(rush))

        try fixture.store.clearMeetings()

        #expect(try fixture.rawCount("folder_suggestions") == 0)
        #expect(try fixture.rawCount("classification_memory") == 0)
        #expect(try fixture.rawCount("classification_learned") == 0)
    }

    @Test("recording a move that did not happen learns nothing")
    func recordMoveRequiresTheMove() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(series: "s1")
        try fixture.classification.recordMove(meetingID: id, toFolder: rush)
        #expect(try fixture.memory(.series, "s1").isEmpty)
    }

    // MARK: - Snapshot

    @Test("snapshot carries series, emails, names and at most 1,500 characters of notes")
    func snapshotContents() throws {
        let fixture = try FolderClassificationFixture()
        let id = try fixture.meeting(series: "s1", emails: ["a@x.com"], notes: String(repeating: "n", count: 4_000))
        let snapshot = try #require(try fixture.classification.snapshot(meetingID: id))
        #expect(snapshot.evidence.seriesID == "s1")
        #expect(snapshot.evidence.emails == ["mailto:a@x.com"])
        #expect(snapshot.participantNames == ["a@x.com"])
        #expect(snapshot.notes.count == 1_500)
        #expect(snapshot.isEligible)
    }

    @Test("recording, foldered and deleted meetings are not eligible")
    func eligibility() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let recording = try fixture.meeting(status: .recording)
        let filed = try fixture.meeting()
        try fixture.store.moveMeeting(id: filed, toFolder: rush)
        #expect(try fixture.classification.snapshot(meetingID: recording)?.isEligible == false)
        #expect(try fixture.classification.snapshot(meetingID: filed)?.isEligible == false)
        #expect(try fixture.classification.unfiledMeetingIDs(limit: 10).isEmpty)
    }

    // MARK: - Learning

    @Test("a manual move learns series, attendee and title once")
    func moveLearnsOnce() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(title: "Zoom: Rush sync 10/13", series: "s1", emails: ["A@x.com"])

        try fixture.classification.moveMeeting(id: id, toFolder: rush)
        try fixture.classification.moveMeeting(id: id, toFolder: rush)

        #expect(try fixture.memory(.series, "s1").map(\.confirmations) == [1])
        #expect(try fixture.memory(.email, "a@x.com").map(\.confirmations) == [1])
        #expect(try fixture.memory(.title, "rush sync").map(\.confirmations) == [1])
    }

    @Test("moving to another folder takes the earlier confirmation back")
    func moveAwayUnlearns() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let v12 = try fixture.store.createFolder(name: "V12")
        let id = try fixture.meeting(series: "s1")

        try fixture.classification.moveMeeting(id: id, toFolder: rush)
        try fixture.classification.moveMeeting(id: id, toFolder: v12)

        let rows = try fixture.memory(.series, "s1")
        #expect(rows.first(where: { $0.folderID == rush })?.confirmations == 0)
        #expect(rows.first(where: { $0.folderID == v12 })?.confirmations == 1)
    }

    @Test("the user's own address is not learned once it is recognizable")
    func selfEmailNotLearned() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        for index in 0..<5 {
            try fixture.meeting(title: "Other \(index)", emails: ["me@me.com", "p\(index)@x.com"])
        }
        #expect(try fixture.classification.selfEmails() == ["me@me.com"])
        let id = try fixture.meeting(emails: ["me@me.com", "a@x.com"])
        try fixture.classification.moveMeeting(id: id, toFolder: rush)
        #expect(try fixture.memory(.email, "me@me.com").isEmpty)
        #expect(try fixture.memory(.email, "a@x.com").count == 1)
    }

    @Test("self detection needs enough meetings")
    func selfEmailNeedsHistory() throws {
        let fixture = try FolderClassificationFixture()
        for _ in 0..<3 { try fixture.meeting(emails: ["me@me.com"]) }
        #expect(try fixture.classification.selfEmails().isEmpty)
    }

    // MARK: - Suggestions

    @Test("accepting a suggestion moves the meeting and learns once, even when accepted twice")
    func acceptLearnsOnce() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(series: "s1")
        try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush))

        try fixture.classification.moveMeeting(id: id, toFolder: rush)
        try fixture.classification.moveMeeting(id: id, toFolder: rush)

        #expect(try fixture.store.meeting(id: id)?.folderID == rush)
        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.accepted])
        #expect(try fixture.memory(.series, "s1").map(\.confirmations) == [1])
        #expect(try fixture.classification.pendingMeetingCount() == 0)
    }

    @Test("moving elsewhere rejects a pending rule suggestion and contradicts the memory that voted")
    func rejectIncrementsContradictions() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let v12 = try fixture.store.createFolder(name: "V12")
        let earlier = try fixture.meeting(series: "s1", emails: ["a@x.com"])
        try fixture.classification.moveMeeting(id: earlier, toFolder: rush)
        let id = try fixture.meeting(series: "s1", emails: ["a@x.com"])
        try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush, .series))

        try fixture.classification.moveMeeting(id: id, toFolder: v12)

        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.rejected])
        let seriesRush = try fixture.memory(.series, "s1").first(where: { $0.folderID == rush })
        #expect(seriesRush?.contradictions == 1)
        // Only the memory kind that voted is contradicted.
        #expect(try fixture.memory(.email, "a@x.com").first(where: { $0.folderID == rush })?.contradictions == 0)
    }

    @Test("a rejected LLM suggestion contradicts no memory")
    func llmRejectLeavesMemory() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let v12 = try fixture.store.createFolder(name: "V12")
        let earlier = try fixture.meeting(series: "s1")
        try fixture.classification.moveMeeting(id: earlier, toFolder: rush)
        let id = try fixture.meeting(series: "s1")
        try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush, .llm))
        try fixture.classification.moveMeeting(id: id, toFolder: v12)
        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.rejected])
        #expect(try fixture.memory(.series, "s1").allSatisfy { $0.contradictions == 0 })
    }

    @Test("a dismissed suggestion is not re-created")
    func dismissedStaysDismissed() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting()
        try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush))
        let suggestion = try #require(try fixture.classification.suggestions(meetingID: id).first)
        try fixture.classification.dismissSuggestion(id: suggestion.id)
        #expect(try fixture.classification.recordSuggestion(meetingID: id, candidate: candidate(rush)) == false)
        #expect(try fixture.classification.pendingSuggestions().isEmpty)
    }

    @Test("auto-apply files an unfiled meeting without learning")
    func autoApplyDoesNotLearn() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let id = try fixture.meeting(series: "s1")
        #expect(try fixture.classification.autoApply(meetingID: id, candidate: candidate(rush)))
        #expect(try fixture.store.meeting(id: id)?.folderID == rush)
        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.autoApplied])
        #expect(try fixture.memory(.series, "s1").isEmpty)
    }

    @Test("auto-filing into a private folder marks the meeting for sync so iCloud gets a tombstone")
    func autoApplyIntoPrivateFolderMarksDirty() throws {
        let fixture = try FolderClassificationFixture()
        let legal = try fixture.store.createFolder(name: "Legal")
        let cases = try fixture.store.createFolder(name: "Cases", parentID: legal)
        let rush = try fixture.store.createFolder(name: "Rush")
        try fixture.store.setFolderPrivate(id: legal, isPrivate: true)
        let privateTarget = try fixture.meeting()
        let plainTarget = try fixture.meeting()

        func syncState(_ id: Int64) throws -> (dirty: Int64, updatedAt: Double) {
            var db: OpaquePointer?
            guard sqlite3_open(fixture.store.resolvedDatabaseURL.path, &db) == SQLITE_OK else { return (-1, -1) }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT sync_dirty, updated_at FROM meetings WHERE id = \(id)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return (-1, -1) }
            return (sqlite3_column_int64(statement, 0), sqlite3_column_double(statement, 1))
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(fixture.store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE meetings SET sync_dirty = 0, updated_at = 100", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(try fixture.classification.autoApply(meetingID: privateTarget, candidate: candidate(cases)))
        #expect(try fixture.classification.autoApply(meetingID: plainTarget, candidate: candidate(rush)))

        let flipped = try syncState(privateTarget)
        #expect(flipped.dirty == 1)
        #expect(flipped.updatedAt > 100)
        let untouched = try syncState(plainTarget)
        #expect(untouched.dirty == 0)
        #expect(untouched.updatedAt == 100)
    }

    @Test("auto-apply never moves a meeting that already has a folder")
    func autoApplyRespectsExistingFolder() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let v12 = try fixture.store.createFolder(name: "V12")
        let id = try fixture.meeting()
        try fixture.store.moveMeeting(id: id, toFolder: v12)
        #expect(try fixture.classification.autoApply(meetingID: id, candidate: candidate(rush)) == false)
        #expect(try fixture.store.meeting(id: id)?.folderID == v12)
        #expect(try fixture.classification.suggestions(meetingID: id).isEmpty)
    }

    @Test("undoing an auto-apply rejects it and contradicts the voting memory")
    func undoAutoApplyRejects() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let earlier = try fixture.meeting(series: "s1")
        try fixture.classification.moveMeeting(id: earlier, toFolder: rush)
        let id = try fixture.meeting(series: "s1")
        try fixture.classification.autoApply(meetingID: id, candidate: candidate(rush))
        try fixture.classification.moveMeeting(id: id, toFolder: nil)
        #expect(try fixture.classification.suggestions(meetingID: id).map(\.state) == [.rejected])
        #expect(try fixture.memory(.series, "s1").first?.contradictions == 1)
    }

    @Test("the Inbox lists only pending suggestions of unfiled meetings")
    func inboxRows() throws {
        let fixture = try FolderClassificationFixture()
        let rush = try fixture.store.createFolder(name: "Rush")
        let a = try fixture.meeting(title: "A")
        let b = try fixture.meeting(title: "B")
        try fixture.classification.recordSuggestion(meetingID: a, candidate: candidate(rush))
        try fixture.classification.recordSuggestion(meetingID: b, candidate: candidate(rush))
        try fixture.store.moveMeeting(id: b, toFolder: rush)
        let rows = try fixture.classification.pendingSuggestions()
        #expect(rows.map(\.meetingTitle) == ["A"])
        #expect(try fixture.classification.pendingMeetingCount() == 1)
    }
}
