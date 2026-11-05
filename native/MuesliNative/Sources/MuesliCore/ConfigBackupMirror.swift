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
        case failed(String)
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

    /// User-created words in the mirror. A missing, unreadable or corrupt mirror reads as empty.
    public func storedUserWords() -> [CustomWord] {
        guard let data = try? Data(contentsOf: fileURL),
              let words = try? CustomWordDictionaryCodec.decode(data) else { return [] }
        return CustomWordDictionaryCodec.userWords(in: words)
    }

    /// Replaces the mirror with `configData`, atomically, unless that would drop the dictionary.
    public func write(_ configData: Data) -> WriteOutcome {
        let incoming = (try? CustomWordDictionaryCodec.decode(configData))
            .map(CustomWordDictionaryCodec.userWords(in:)) ?? []
        if incoming.isEmpty, !storedUserWords().isEmpty {
            return .keptExistingWords
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

    /// Moves the mirrored config to the Trash. A missing mirror is not an error.
    public func trashBackup() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try trash(fileURL)
    }
}
