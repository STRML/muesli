import Foundation
import MuesliCore
import os

/// Names and paths for vault notes. Every path component is sanitized, and the final
/// destination must stay inside the export root even through symlinks.
enum MeetingVaultNaming {
    static let maxComponentLength = 80
    private static let allowedPunctuation = Set(" -_()&',.!+#@")

    static func sanitize(_ text: String, fallback: String) -> String {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                cleaned.append(" ")
            } else if character.isLetter || character.isNumber || allowedPunctuation.contains(character) {
                cleaned.append(character)
            } else {
                cleaned.append("-")
            }
        }
        while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: ".") }
        cleaned = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("-") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(maxComponentLength)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? fallback : cleaned
    }

    static func filename(title: String, date: Date?, id: Int64) -> String {
        let name = sanitize(title, fallback: "Untitled meeting")
        if let date {
            return "\(dayFormatter.string(from: date)) - \(name) (\(id)).md"
        }
        return "\(name) (\(id)).md"
    }

    /// Folder names from the top of the tree down to `folderID`. A cycle ends the walk.
    static func folderComponents(for folderID: Int64?, folders: [MeetingFolder]) -> [String] {
        guard let folderID else { return [] }
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var components: [String] = []
        var seen = Set<Int64>()
        var current: Int64? = folderID
        while let id = current, let folder = byID[id], seen.insert(id).inserted {
            components.insert(sanitize(folder.name, fallback: "Folder"), at: 0)
            current = folder.parentID
        }
        return components
    }

    /// The file URL for a note, or nil if it would land outside `root` (for example through a symlink).
    static func destination(root: URL, components: [String], filename: String) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var target = resolvedRoot
        for component in components { target.appendPathComponent(component, isDirectory: true) }
        target.appendPathComponent(filename, isDirectory: false)

        // Resolve the deepest part that already exists, then append what does not exist yet.
        var existing = target.deletingLastPathComponent()
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > resolvedRoot.pathComponents.count {
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in remainder { resolved.appendPathComponent(part, isDirectory: true) }
        resolved.appendPathComponent(filename, isDirectory: false)

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Obsidian-friendly note text. Every value in the frontmatter is emitted through `yamlString`,
/// so a title or attendee name can never add a key or end the block.
enum MeetingVaultMarkdown {
    static func yamlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func note(meeting: MeetingRecord, folderPath: [String], attendees: [String], content: MeetingExportContent) -> String {
        var lines = ["---"]
        lines.append("muesli_id: \(meeting.id)")
        lines.append("title: \(yamlString(meeting.title))")
        lines.append("date: \(dateString(meeting.startTime))")
        lines.append("folder: \(yamlString(folderPath.joined(separator: " / ")))")
        lines.append("attendees: [\(attendees.map(yamlString).joined(separator: ", "))]")
        lines.append("tags: [meeting]")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + MeetingExporter.buildMarkdown(meeting: meeting, content: content)
    }

    /// The `muesli_id` of a note Muesli wrote, or nil for anything else.
    static func frontmatterMeetingID(in text: String) -> Int64? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { return nil }
            guard line.hasPrefix("muesli_id: ") else { continue }
            let value = line.dropFirst("muesli_id: ".count)
            return value.allSatisfy(\.isNumber) ? Int64(value) : nil
        }
        return nil
    }

    private static func dateString(_ startTime: String) -> String {
        guard let date = MeetingBrowserLogic.parseDate(startTime) else { return String(startTime.prefix(10)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Keeps one note per meeting in the user's vault: written under a stable name, updated in place,
/// moved when the title or folder changes, and removed when the meeting is deleted or becomes private.
/// What it wrote is recorded in `meeting_exports`, and a file is removed only if its frontmatter still
/// carries the meeting's id, so it can never delete a note the user wrote or replaced.
final class MeetingVaultExporter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "VaultExport")
    private let store: DictationStore
    private let fileManager: FileManager
    private let lock = NSLock()

    init(store: DictationStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func refresh(meetingID: Int64, config: AppConfig) {
        guard config.autoExportKeepInSync else { return }
        lock.lock(); defer { lock.unlock() }
        refreshLocked(meetingID: meetingID, config: config)
    }

    /// Re-evaluates every meeting and every recorded export. Used after a folder's privacy changes.
    func refreshAll(config: AppConfig) {
        guard config.autoExportKeepInSync else { return }
        lock.lock(); defer { lock.unlock() }
        guard let meetings = try? store.recentMeetings(limit: 100_000) else { return }
        let live = Set(meetings.map(\.id))
        for meeting in meetings { refreshLocked(meetingID: meeting.id, config: config) }
        for export in (try? store.allMeetingExports()) ?? [] where !live.contains(export.meetingID) {
            retractLocked(meetingID: export.meetingID)
        }
    }

    func retryPendingRemovals() {
        lock.lock(); defer { lock.unlock() }
        for export in (try? store.meetingExportsPendingRemoval()) ?? [] {
            retractLocked(meetingID: export.meetingID)
        }
    }

    func retract(meetingID: Int64) {
        lock.lock(); defer { lock.unlock() }
        retractLocked(meetingID: meetingID)
    }

    // MARK: - Internals

    private func refreshLocked(meetingID: Int64, config: AppConfig) {
        let record: MeetingRecord?
        do { record = try store.meeting(id: meetingID) } catch {
            Self.logger.error("vault export skipped id=\(meetingID): lookup failed")
            return
        }
        // A deleted meeting, or a private one (a failed lookup counts as private), must not stay in the vault.
        guard let record, !isPrivateFailingClosed(meetingID) else {
            retractLocked(meetingID: meetingID)
            return
        }
        guard record.status == .completed else { return }
        guard let root = validatedRoot(config) else {
            Self.logger.notice("vault export skipped id=\(meetingID): destination folder missing or not absolute")
            return
        }

        let folders = (try? store.listFolders()) ?? []
        let components = config.autoExportByFolder ? MeetingVaultNaming.folderComponents(for: record.folderID, folders: folders) : []
        let date = MeetingBrowserLogic.parseDate(record.startTime)
        let name = MeetingVaultNaming.filename(title: record.title, date: date, id: record.id)
        guard let destination = MeetingVaultNaming.destination(root: root, components: components, filename: name) else {
            Self.logger.error("vault export refused id=\(meetingID): destination escapes the export folder")
            return
        }

        let attendees = ((try? store.listMeetingParticipants(meetingID: meetingID)) ?? []).map(\.displayName)
        let text = MeetingVaultMarkdown.note(meeting: record, folderPath: components, attendees: attendees,
                                             content: config.resolvedAutoExportMarkdownContent)
        let data = Data(text.utf8)
        let previous = try? store.meetingExport(for: meetingID)

        do {
            let unchanged = (try? Data(contentsOf: destination)) == data
            if !unchanged {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            try store.saveMeetingExport(meetingID: meetingID, path: destination.path, state: "exported")
        } catch {
            Self.logger.error("vault export failed id=\(meetingID): \(error.localizedDescription)")
            return
        }

        if let old = previous, old.path != destination.path {
            _ = removeOwnedFile(atPath: old.path, meetingID: meetingID)
        }
    }

    private func retractLocked(meetingID: Int64) {
        guard let export = (try? store.meetingExport(for: meetingID)) ?? nil else { return }
        if removeOwnedFile(atPath: export.path, meetingID: meetingID) {
            try? store.clearMeetingExport(meetingID: meetingID)
        } else {
            try? store.saveMeetingExport(meetingID: meetingID, path: export.path, state: "pending_removal")
            Self.logger.notice("vault removal pending id=\(meetingID)")
        }
    }

    /// Removes the file if it is ours. Returns false only when removal was attempted and failed.
    private func removeOwnedFile(atPath path: String, meetingID: Int64) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return true }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              MeetingVaultMarkdown.frontmatterMeetingID(in: text) == meetingID else {
            Self.logger.notice("vault file left in place id=\(meetingID): it is no longer a Muesli note for this meeting")
            return true
        }
        do {
            // A hard delete: moving a private note to the Trash would keep its content on disk.
            try fileManager.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    private func isPrivateFailingClosed(_ id: Int64) -> Bool {
        (try? store.isMeetingPrivate(id: id)) ?? true
    }

    private func validatedRoot(_ config: AppConfig) -> URL? {
        let trimmed = config.autoExportMarkdownFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NSString(string: trimmed).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}
