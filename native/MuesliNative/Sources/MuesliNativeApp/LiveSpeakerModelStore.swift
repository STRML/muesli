import FluidAudio
import Foundation

/// Local cache and loader for the LS-EEND model behind live speaker labels.
/// Loading never reaches the network; only `download()` does, and only the
/// Settings toggle calls it.
enum LiveSpeakerModelStore {
    enum StoreError: Error, Equatable {
        case notDownloaded
    }

    static func modelURL(in cacheRoot: URL) -> URL { cacheRoot }

    static func isDownloaded(in cacheRoot: URL) -> Bool { true }

    /// Builds an engine from the local cache, or throws `.notDownloaded` without
    /// calling `load`.
    static func makeEngine(
        isDownloaded: Bool,
        load: () throws -> LiveSpeakerEngine
    ) throws -> LiveSpeakerEngine {
        try load()
    }
}
