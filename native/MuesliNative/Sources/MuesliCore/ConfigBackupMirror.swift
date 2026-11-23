import Foundation

/// A copy of `config.json` kept outside `~/Library`, so a sweep by an app
/// uninstaller does not take the custom dictionary with it.
///
/// The mirror holds the same sanitized bytes as `config.json` (credentials live
/// in the Keychain, never in either file). Everything here fails soft: a mirror
/// problem is reported to the caller, never thrown into the save path.
public struct ConfigBackupMirror: Sendable {
    public enum WriteOutcome: Equatable, Sendable {
        case written
        /// The new config has no user words and the mirror does. The mirror was left alone.
        case keptExistingWords
        /// The existing mirror file could not be read, so it was left alone to avoid clobbering unknown contents.
        case unreadableExistingMirror
        case failed(String)
    }

    public enum ReadStatus: Equatable, Sendable {
        case missing
        case readable(userWords: [CustomWord])
        case corrupt
        case unreadable(String)
    }

    public let directoryURL: URL
    private let trash: @Sendable (URL) throws -> Void

    public var fileURL: URL { directoryURL.appendingPathComponent("config.json") }

    public init(
        directoryURL: URL,
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.directoryURL = directoryURL
        self.trash = trash
    }

    public static func standard(
        appName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConfigBackupMirror {
        ConfigBackupMirror(directoryURL: MuesliPaths.backupDirectoryURL(appName: appName, home: home))
    }

    /// Reads the current state of the mirror on disk, distinguishing a missing file
    /// or corrupt JSON from an existing file that cannot be read.
    public func readMirrorStatus() -> ReadStatus {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if Self.isMissingFileError(error) {
                return .missing
            }
            return .unreadable(error.localizedDescription)
        }
        guard let words = try? CustomWordDictionaryCodec.decode(data) else {
            return .corrupt
        }
        return .readable(userWords: CustomWordDictionaryCodec.userWords(in: words))
    }

    /// User-created words in the mirror. A missing, unreadable or corrupt mirror reads as empty.
    public func storedUserWords() -> [CustomWord] {
        guard case .readable(let words) = readMirrorStatus() else { return [] }
        return words
    }

    /// Replaces the mirror with `configData`, atomically, unless that would drop the dictionary
    /// or overwrite an unreadable existing mirror.
    public func write(_ configData: Data) -> WriteOutcome {
        let incoming = (try? CustomWordDictionaryCodec.decode(configData))
            .map(CustomWordDictionaryCodec.userWords(in:)) ?? []
        let clearedByUser = (try? JSONDecoder().decode(MirrorFlagsShape.self, from: configData))?
            .customWordsClearedByUser ?? false
        switch readMirrorStatus() {
        case .unreadable:
            return .unreadableExistingMirror
        case .readable(let existingWords) where incoming.isEmpty && !clearedByUser && !existingWords.isEmpty:
            return .keptExistingWords
        case .missing, .corrupt, .readable:
            break
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try configData.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private struct MirrorFlagsShape: Decodable {
        let customWordsClearedByUser: Bool?

        enum CodingKeys: String, CodingKey {
            case customWordsClearedByUser = "custom_words_cleared_by_user"
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == ENOENT || nsError.code == ENOTDIR) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFileError(underlying)
        }
        return false
    }

    /// Moves the mirrored config to the Trash. A missing mirror is not an error.
    public func trashBackup() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try trash(fileURL)
    }
}
