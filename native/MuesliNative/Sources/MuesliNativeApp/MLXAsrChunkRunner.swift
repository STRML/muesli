import FluidAudio
import Foundation
import os

/// Counters the runner keeps itself. The meeting session already counts successful, empty
/// and failed chunks for the transcript health monitor; `guardTripped` and `silent` are the
/// numbers it cannot see.
struct MLXAsrChunkHealth: Sendable, Equatable {
    /// Calls to `transcribeChunk`.
    var chunks = 0
    /// Chunks the speech gate rejected.
    var silent = 0
    /// Chunks that decoded to nothing, or only to engine artifacts.
    var empty = 0
    /// Windows (chunk or dictation) whose model call threw something other than cancellation.
    var failed = 0
    /// Windows (chunk or dictation) the decode guard ended.
    var guardTripped = 0
}

struct MLXAsrDictationResult: Sendable, Equatable {
    let text: String
    let windowCount: Int
    /// Windows the decode guard cut short. Callers can show a notice when this is most of them.
    let guardTrippedWindowCount: Int
}

/// Turns audio into transcripts for an MLX ASR model through the shared transcriber.
///
/// - Meeting chunks (live 3 to 5 s, or 5 s replay windows) become one `SpeechSegment` whose
///   bounds are the chunk bounds: `0` to the chunk length, in seconds. Replay windows are
///   stitched by `MeetingRecordingTranscriber`.
/// - Dictation files go through 28 s windows on a 27 s hop and are merged with
///   `BodhanTranscriptMerger`, the same as Bodhan.
/// - Silence is decided by an injected gate, so the app's existing VAD can be reused. A gate
///   that throws lets the audio through, like the coordinator's VAD path.
final class MLXAsrChunkRunner: Sendable {
    typealias SpeechGate = @Sendable ([Float]) async throws -> Bool
    typealias SampleLoader = @Sendable (URL) throws -> [Float]

    static let dictationWindowSeconds = 28
    static let dictationHopSeconds = 27

    private let transcriber: MLXAsrTranscriber
    private let model: MLXAsrModel
    private let speechGate: SpeechGate?
    private let loadSamples: SampleLoader
    private let counters = OSAllocatedUnfairLock(initialState: MLXAsrChunkHealth())

    /// - Parameters:
    ///   - speechGate: returns whether the samples contain speech. `nil` skips gating, for
    ///     callers whose path already ran VAD (the coordinator's meeting-chunk path does).
    ///   - loadSamples: file to 16 kHz mono samples. Defaults to FluidAudio's converter.
    init(transcriber: MLXAsrTranscriber, model: MLXAsrModel,
         speechGate: SpeechGate? = nil, loadSamples: SampleLoader? = nil) {
        self.transcriber = transcriber
        self.model = model
        self.speechGate = speechGate
        self.loadSamples = loadSamples ?? { try AudioConverter().resampleAudioFile($0) }
    }

    var health: MLXAsrChunkHealth { counters.withLock { $0 } }

    /// One meeting chunk. Silent and empty chunks return an empty result, not an error.
    func transcribeChunk(samples: [Float], language: String? = nil) async throws -> SpeechTranscriptionResult {
        record { $0.chunks += 1 }
        let empty = SpeechTranscriptionResult(text: "", segments: [])
        guard !samples.isEmpty else { record { $0.empty += 1 }; return empty }
        if await isSilent(samples) { record { $0.silent += 1 }; return empty }
        let text = Self.cleaned(try await decode(samples, language: language).text)
        guard !text.isEmpty else { record { $0.empty += 1 }; return empty }
        let seconds = Double(samples.count) / Double(MLXAsrTranscriber.sampleRate)
        return SpeechTranscriptionResult(text: text, segments: [SpeechSegment(start: 0, end: seconds, text: text)])
    }

    func transcribeChunk(at url: URL, language: String? = nil) async throws -> SpeechTranscriptionResult {
        try await transcribeChunk(samples: try loadSamples(url), language: language)
    }

    /// A whole dictation recording. Long audio is cut into overlapping windows and merged.
    func transcribeDictation(samples: [Float], language: String? = nil) async throws -> MLXAsrDictationResult {
        let none = MLXAsrDictationResult(text: "", windowCount: 0, guardTrippedWindowCount: 0)
        guard !samples.isEmpty else { return none }
        if await isSilent(samples) { record { $0.silent += 1 }; return none }
        let rate = MLXAsrTranscriber.sampleRate
        var texts: [String] = []
        var tripped = 0
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + Self.dictationWindowSeconds * rate, samples.count)
            let result = try await decode(Array(samples[offset..<end]), language: language)
            if result.guardTripped { tripped += 1 }
            texts.append(Self.cleaned(result.text))
            if end == samples.count { break }
            offset += Self.dictationHopSeconds * rate
        }
        return MLXAsrDictationResult(text: BodhanTranscriptMerger.mergeOverlappingTranscripts(texts),
                                     windowCount: texts.count, guardTrippedWindowCount: tripped)
    }

    // MARK: - Private

    private func record(_ change: (inout MLXAsrChunkHealth) -> Void) {
        counters.withLock { change(&$0) }
    }

    private func isSilent(_ samples: [Float]) async -> Bool {
        guard let speechGate else { return false }
        return (try? await speechGate(samples)).map { !$0 } ?? false
    }

    /// One model call. Counts failures and guard trips; cancellation is neither.
    private func decode(_ window: [Float], language: String?) async throws -> MLXAsrDecodeResult {
        do {
            let result = try await transcriber.transcribeWindow(window, model: model, language: language)
            if result.guardTripped { record { $0.guardTripped += 1 } }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            record { $0.failed += 1 }
            throw error
        }
    }

    private static func cleaned(_ text: String) -> String {
        TranscriptionEngineArtifactsFilter.apply(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
