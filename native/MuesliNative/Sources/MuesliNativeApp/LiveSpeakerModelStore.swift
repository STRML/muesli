import FluidAudio
import Foundation

/// Local cache and loader for the LS-EEND model behind live speaker labels.
///
/// Loading never reaches the network, so a meeting (private or not) stays on the
/// Mac. Only `download()` does, and only the Settings toggle calls it.
///
/// dihard3 is FluidAudio's general-purpose variant (10 speaker slots); calls with
/// remote participants are close to its training mix. Frames are 100 ms.
enum LiveSpeakerModelStore {
    enum StoreError: Error, Equatable {
        case notDownloaded
    }

    private static let variant = LSEENDVariant.dihard3
    private static let stepSize = LSEENDStepSize.step100ms

    static var defaultCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    /// Where FluidAudio's own downloader puts the compiled model.
    static func modelURL(in cacheRoot: URL) -> URL {
        let repo = variant.repo
        let relativePath = variant.fileName(forStep: stepSize)
        let fullPath = repo.subPath.map { "\($0)/\(relativePath)" } ?? relativePath
        return cacheRoot
            .appendingPathComponent(repo.folderName, isDirectory: true)
            .appendingPathComponent(fullPath, isDirectory: true)
    }

    static func isDownloaded(in cacheRoot: URL = defaultCacheRoot) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(in: cacheRoot).path)
    }

    /// Builds an engine from the local cache, or throws `.notDownloaded` without
    /// calling `load`.
    static func makeEngine(
        isDownloaded: Bool,
        load: () throws -> LiveSpeakerEngine
    ) throws -> LiveSpeakerEngine {
        guard isDownloaded else { throw StoreError.notDownloaded }
        return try load()
    }

    /// The factory a meeting hands to `LiveSpeakerLabelSession`. CoreML loading
    /// blocks, so it runs on a detached task rather than the cooperative pool.
    @Sendable
    static func loadEngine() async throws -> LiveSpeakerEngine {
        try await Task.detached(priority: .userInitiated) {
            try makeEngine(isDownloaded: isDownloaded()) {
                let model = try LSEENDModel(modelURL: modelURL(in: defaultCacheRoot), computeUnits: .cpuOnly)
                return try LSEENDLiveSpeakerEngine(model: model)
            }
        }.value
    }

    /// Fetches the model into FluidAudio's shared cache. Network; call it only
    /// from the Settings toggle, never from a meeting.
    static func download() async throws {
        _ = try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: stepSize)
    }
}

/// LS-EEND behind `LiveSpeakerEngine`. The timeline keeps no segments and no
/// prediction history (`storeSegments = false`, `maxStoredFrames = 0`): the
/// session reads per-frame probabilities off each update and owns the history.
final class LSEENDLiveSpeakerEngine: LiveSpeakerEngine, @unchecked Sendable {
    let slotCount: Int
    let frameDuration: TimeInterval
    private let diarizer: LSEENDDiarizer

    init(model: LSEENDModel) throws {
        var timeline = DiarizerTimelineConfig.default(numSpeakers: 1, frameDurationSeconds: 0.1)
        timeline.storeSegments = false
        timeline.maxStoredFrames = 0
        diarizer = try LSEENDDiarizer(model: model, timelineConfig: timeline)
        slotCount = model.metadata.maxSpeakers
        frameDuration = TimeInterval(model.metadata.frameDurationSeconds)
    }

    func process(samples: [Float]) throws -> LiveSpeakerFrames? {
        frames(from: try diarizer.process(samples: samples, sourceSampleRate: Double(LiveSpeakerLabelSession.sampleRate)))
    }

    func finish() throws -> LiveSpeakerFrames? {
        frames(from: try diarizer.finalizeSession())
    }

    private func frames(from update: DiarizerTimelineUpdate?) -> LiveSpeakerFrames? {
        guard let chunk = update?.chunkResult, chunk.finalizedFrameCount > 0 else { return nil }
        return LiveSpeakerFrames(
            startFrame: chunk.startFrame,
            slotCount: slotCount,
            probabilities: chunk.finalizedPredictions
        )
    }
}
