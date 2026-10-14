import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting vault export (kept in sync)", .serialized)
struct MeetingVaultExporterTests {

    // MARK: - Fixtures

    private struct Env {
        let store: DictationStore
        let root: URL
        let exporter: MeetingVaultExporter
        var config: AppConfig
    }

    private func makeEnv(byFolder: Bool = true) throws -> Env {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-export-\(UUID()).db"))
        try store.migrateIfNeeded()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = AppConfig()
        config.autoExportKeepInSync = true
        config.autoExportByFolder = byFolder
        config.autoExportMarkdownFolderPath = root.path
        return Env(store: store, root: root, exporter: MeetingVaultExporter(store: store), config: config)
    }

    @discardableResult
    private func meeting(_ store: DictationStore, title: String = "Weekly Sync", notes: String = "## Summary\nShipped it.",
                         transcript: String = "alice: hello") throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_774_000_000)
        let id = try store.createLiveMeeting(title: title, calendarEventID: nil, startTime: start)
        try store.completeLiveMeeting(id: id, title: title, calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(600), rawTranscript: transcript, formattedNotes: notes,
            micAudioPath: nil, systemAudioPath: nil)
        return id
    }

    private func files(under root: URL) -> [String] {
        // The temp directory is a symlink on macOS (/var -> /private/var), so compare resolved paths.
        let base = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { ($0 as? URL) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(base.count + 1)) }
            .sorted()
    }

    // MARK: - Naming and containment (pure)

    @Test("filenames carry the date, a sanitized title and the meeting id")
    func filenameShape() {
        let date = Date(timeIntervalSince1970: 1_774_000_000)
        let name = MeetingVaultNaming.filename(title: "Weekly Sync", date: date, id: 42)
        #expect(name.hasSuffix(" - Weekly Sync (42).md"))
        #expect(name.range(of: #"^\d{4}-\d{2}-\d{2} - "#, options: .regularExpression) != nil)
    }

    @Test("hostile titles cannot add path components or hidden files")
    func hostileTitlesSanitized() {
        let date = Date(timeIntervalSince1970: 1_774_000_000)
        for title in ["a/../../.claude/commands/x", "../../etc/passwd", "x\nup: \"[[Legal]]\"", ".hidden", "name\u{0}null", "con:colon"] {
            let name = MeetingVaultNaming.filename(title: title, date: date, id: 1)
            #expect(!name.contains("/"), "slash in \(name)")
            #expect(!name.contains("\n") && !name.contains("\u{0}"), "control char in \(name)")
            #expect(!name.hasPrefix("."), "hidden file \(name)")
            #expect(!name.contains(".."), "dotdot in \(name)")
        }
    }

    @Test("an empty or whitespace title falls back to a readable name")
    func emptyTitleFallback() {
        let name = MeetingVaultNaming.filename(title: "  \n ", date: nil, id: 5)
        #expect(name.contains("Untitled meeting"))
        #expect(name.hasSuffix("(5).md"))
    }

    @Test("very long titles are capped")
    func longTitleCapped() {
        let name = MeetingVaultNaming.filename(title: String(repeating: "x", count: 500), date: nil, id: 5)
        #expect(name.count < 140)
    }

    @Test("folder components are sanitized and dot components are neutralized")
    func folderComponentsSanitized() {
        let folders = [
            MeetingFolder(id: 1, name: "..", parentID: nil, createdAt: ""),
            MeetingFolder(id: 2, name: "Cases/2026", parentID: 1, createdAt: ""),
        ]
        let components = MeetingVaultNaming.folderComponents(for: 2, folders: folders)
        #expect(components.count == 2)
        #expect(components.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") && !$0.isEmpty })
    }

    @Test("a cyclic folder tree terminates")
    func folderCycleTerminates() {
        let folders = [
            MeetingFolder(id: 1, name: "A", parentID: 2, createdAt: ""),
            MeetingFolder(id: 2, name: "B", parentID: 1, createdAt: ""),
        ]
        #expect(MeetingVaultNaming.folderComponents(for: 1, folders: folders).count <= 2)
    }

    @Test("a destination that escapes the root through a symlink is refused")
    func symlinkEscapeRefused() throws {
        let env = try makeEnv()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: env.root.appendingPathComponent("Escape"), withDestinationURL: outside)

        let url = MeetingVaultNaming.destination(root: env.root, components: ["Escape"], filename: "note.md")
        #expect(url == nil)
    }

    @Test("a normal destination stays under the root")
    func destinationUnderRoot() throws {
        let env = try makeEnv()
        let url = try #require(MeetingVaultNaming.destination(root: env.root, components: ["Rush"], filename: "note.md"))
        #expect(url.path.hasPrefix(env.root.standardizedFileURL.path))
    }

    // MARK: - Frontmatter (pure)

    @Test("YAML strings are quoted and escape newlines, quotes and separators")
    func yamlEscaping() {
        let quoted = MeetingVaultMarkdown.yamlString("a\"b\nup: \"[[Legal]]\"\n---\\")
        #expect(quoted.hasPrefix("\"") && quoted.hasSuffix("\""))
        #expect(!quoted.contains("\n"))
        #expect(quoted.contains("\\n"))
        #expect(quoted.contains("\\\""))
    }

    @Test("a hostile title cannot add frontmatter keys")
    func hostileTitleDoesNotInjectKeys() throws {
        let env = try makeEnv()
        let id = try meeting(env.store, title: "x\nup: \"[[Legal]]\"\ntype: project")
        let record = try #require(try env.store.meeting(id: id))
        let note = MeetingVaultMarkdown.note(meeting: record, folderPath: ["Rush"], attendees: ["Evil\nstatus: done"], content: .notes)
        let frontmatter = note.components(separatedBy: "---")[1]
        let keys = frontmatter.split(separator: "\n").compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
            .filter { !$0.hasPrefix(" ") && !$0.hasPrefix("-") }
        #expect(Set(keys) == ["muesli_id", "title", "date", "folder", "attendees", "tags"])
    }

    @Test("the meeting id can be read back from a note")
    func frontmatterIDRoundTrip() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        let record = try #require(try env.store.meeting(id: id))
        let note = MeetingVaultMarkdown.note(meeting: record, folderPath: [], attendees: [], content: .notes)
        #expect(MeetingVaultMarkdown.frontmatterMeetingID(in: note) == id)
        #expect(MeetingVaultMarkdown.frontmatterMeetingID(in: "no frontmatter") == nil)
        #expect(MeetingVaultMarkdown.frontmatterMeetingID(in: "---\nmuesli_id: abc\n---\n") == nil)
    }

    // MARK: - Writing and updating

    @Test("a completed meeting is written to a stable per-folder path and recorded")
    func writesStableFile() throws {
        let env = try makeEnv()
        let folder = try env.store.createFolder(name: "Rush")
        let id = try meeting(env.store)
        try env.store.moveMeeting(id: id, toFolder: folder)

        env.exporter.refresh(meetingID: id, config: env.config)

        let written = files(under: env.root)
        #expect(written.count == 1)
        #expect(written[0].hasPrefix("Rush/") && written[0].hasSuffix("Weekly Sync (\(id)).md"))
        let text = try String(contentsOf: env.root.appendingPathComponent(written[0]), encoding: .utf8)
        #expect(text.contains("Shipped it."))
        #expect(MeetingVaultMarkdown.frontmatterMeetingID(in: text) == id)
        #expect(try env.store.meetingExport(for: id)?.path == env.root.appendingPathComponent(written[0]).path)
    }

    @Test("by-folder off writes everything at the root")
    func flatLayout() throws {
        let env = try makeEnv(byFolder: false)
        let folder = try env.store.createFolder(name: "Rush")
        let id = try meeting(env.store)
        try env.store.moveMeeting(id: id, toFolder: folder)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).allSatisfy { !$0.contains("/") })
    }

    @Test("an unfiled meeting is written at the root")
    func unfiledAtRoot() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).count == 1)
        #expect(files(under: env.root)[0].contains("/") == false)
    }

    @Test("re-exporting after an edit updates the same file instead of creating another")
    func updatesInPlace() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        let first = files(under: env.root)

        try env.store.updateMeetingNotes(id: id, formattedNotes: "## Summary\nRevised notes.")
        env.exporter.refresh(meetingID: id, config: env.config)

        #expect(files(under: env.root) == first)
        let text = try String(contentsOf: env.root.appendingPathComponent(first[0]), encoding: .utf8)
        #expect(text.contains("Revised notes."))
        #expect(!text.contains("Shipped it."))
    }

    @Test("an unchanged meeting is not rewritten")
    func unchangedNotRewritten() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        let url = env.root.appendingPathComponent(files(under: env.root)[0])
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)

        env.exporter.refresh(meetingID: id, config: env.config)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("moving the meeting to another folder moves the file")
    func moveFolderMovesFile() throws {
        let env = try makeEnv()
        let a = try env.store.createFolder(name: "Rush")
        let b = try env.store.createFolder(name: "V12")
        let id = try meeting(env.store)
        try env.store.moveMeeting(id: id, toFolder: a)
        env.exporter.refresh(meetingID: id, config: env.config)

        try env.store.moveMeeting(id: id, toFolder: b)
        env.exporter.refresh(meetingID: id, config: env.config)

        let written = files(under: env.root)
        #expect(written.count == 1)
        #expect(written[0].hasPrefix("V12/"))
    }

    @Test("renaming the meeting renames the file")
    func titleChangeRenames() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)

        try env.store.updateMeetingTitle(id: id, title: "Renamed Call")
        env.exporter.refresh(meetingID: id, config: env.config)

        let written = files(under: env.root)
        #expect(written.count == 1)
        #expect(written[0].contains("Renamed Call"))
    }

    @Test("two meetings with the same title and date get distinct files")
    func sameTitleDistinct() throws {
        let env = try makeEnv()
        let a = try meeting(env.store, title: "Standup")
        let b = try meeting(env.store, title: "Standup")
        env.exporter.refresh(meetingID: a, config: env.config)
        env.exporter.refresh(meetingID: b, config: env.config)
        #expect(files(under: env.root).count == 2)
    }

    @Test("the content setting chooses notes, transcript or both")
    func contentSetting() throws {
        var env = try makeEnv()
        let id = try meeting(env.store, notes: "NOTES-BODY", transcript: "TRANSCRIPT-BODY")
        env.config.autoExportMarkdownContent = MeetingExportContent.transcript.rawValue
        env.exporter.refresh(meetingID: id, config: env.config)
        var text = try String(contentsOf: env.root.appendingPathComponent(files(under: env.root)[0]), encoding: .utf8)
        #expect(text.contains("TRANSCRIPT-BODY") && !text.contains("NOTES-BODY"))

        env.config.autoExportMarkdownContent = MeetingExportContent.fullMeeting.rawValue
        env.exporter.refresh(meetingID: id, config: env.config)
        text = try String(contentsOf: env.root.appendingPathComponent(files(under: env.root)[0]), encoding: .utf8)
        #expect(text.contains("TRANSCRIPT-BODY") && text.contains("NOTES-BODY"))
    }

    @Test("nothing is written when keep-in-sync is off")
    func offIsNoop() throws {
        var env = try makeEnv()
        env.config.autoExportKeepInSync = false
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).isEmpty)
    }

    @Test("a relative or empty destination is skipped")
    func badDestinationSkipped() throws {
        var env = try makeEnv()
        let id = try meeting(env.store)
        for path in ["", "   ", "relative/dir"] {
            env.config.autoExportMarkdownFolderPath = path
            env.exporter.refresh(meetingID: id, config: env.config)
        }
        #expect(files(under: env.root).isEmpty)
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("a meeting that is still recording is not exported")
    func recordingNotExported() throws {
        let env = try makeEnv()
        let id = try env.store.createLiveMeeting(title: "Live", calendarEventID: nil, startTime: Date())
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).isEmpty)
    }

    // MARK: - Privacy and retraction

    @Test("a private meeting is never written, even when refresh is called directly")
    func privateNeverWritten() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).isEmpty)
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("marking an exported meeting private removes its file")
    func markingPrivateRetracts() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).count == 1)

        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)

        #expect(files(under: env.root).isEmpty)
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("marking the folder private removes the files of its meetings")
    func folderPrivateRetracts() throws {
        let env = try makeEnv()
        let folder = try env.store.createFolder(name: "Legal")
        let id = try meeting(env.store)
        try env.store.moveMeeting(id: id, toFolder: folder)
        env.exporter.refresh(meetingID: id, config: env.config)

        try env.store.setFolderPrivate(id: folder, isPrivate: true)
        env.exporter.refreshAll(config: env.config)

        #expect(files(under: env.root).isEmpty)
    }

    @Test("clearing the private mark exports the meeting again")
    func unmarkingExportsAgain() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).isEmpty)

        try env.store.setMeetingPrivate(id: id, isPrivate: false)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(files(under: env.root).count == 1)
    }

    @Test("deleting a meeting removes its file")
    func deleteRetracts() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)

        try env.store.deleteMeeting(id: id)
        env.exporter.refresh(meetingID: id, config: env.config)

        #expect(files(under: env.root).isEmpty)
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("retraction never deletes a file whose frontmatter id differs")
    func retractionVerifiesOwnership() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        let url = env.root.appendingPathComponent(files(under: env.root)[0])
        try "# My own note, same path\nno frontmatter".write(to: url, atomically: true, encoding: .utf8)

        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("retraction of an already-missing file clears the record")
    func missingFileClearsRecord() throws {
        let env = try makeEnv()
        let id = try meeting(env.store)
        env.exporter.refresh(meetingID: id, config: env.config)
        try FileManager.default.removeItem(at: env.root.appendingPathComponent(files(under: env.root)[0]))

        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)

        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("a failed removal stays pending and a later retry completes it")
    func failedRemovalRetried() throws {
        let env = try makeEnv()
        let folder = try env.store.createFolder(name: "Rush")
        let id = try meeting(env.store)
        try env.store.moveMeeting(id: id, toFolder: folder)
        env.exporter.refresh(meetingID: id, config: env.config)
        let dir = env.root.appendingPathComponent("Rush")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        try env.store.setMeetingPrivate(id: id, isPrivate: true)
        env.exporter.refresh(meetingID: id, config: env.config)
        #expect(try env.store.meetingExport(for: id)?.state == "pending_removal")
        #expect(files(under: env.root).count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        env.exporter.retryPendingRemovals()
        #expect(files(under: env.root).isEmpty)
        #expect(try env.store.meetingExport(for: id) == nil)
    }

    @Test("refreshAll exports every eligible meeting and skips private ones")
    func refreshAllCoversLibrary() throws {
        let env = try makeEnv()
        let a = try meeting(env.store, title: "One")
        try meeting(env.store, title: "Two")
        let secret = try meeting(env.store, title: "Secret")
        try env.store.setMeetingPrivate(id: secret, isPrivate: true)

        env.exporter.refreshAll(config: env.config)

        let written = files(under: env.root)
        #expect(written.count == 2)
        #expect(written.allSatisfy { !$0.contains("Secret") })
        _ = a
    }

    @Test("legacy databases gain the export manifest table and migrate twice")
    func manifestMigration() throws {
        let env = try makeEnv()
        try env.store.migrateIfNeeded()
        #expect(try env.store.meetingExport(for: 1) == nil)
        try env.store.saveMeetingExport(meetingID: 1, path: "/tmp/x.md", state: "exported")
        #expect(try env.store.meetingExport(for: 1)?.path == "/tmp/x.md")
        try env.store.clearMeetingExport(meetingID: 1)
        #expect(try env.store.meetingExport(for: 1) == nil)
    }

    @Test("config without the new keys decodes to safe defaults")
    func configDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.autoExportKeepInSync == false)
        #expect(decoded.autoExportByFolder == true)
    }
}
