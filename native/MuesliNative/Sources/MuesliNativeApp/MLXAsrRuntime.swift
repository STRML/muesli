import Foundation
import MLX

/// What a runtime returns for one audio window.
struct MLXAsrDecodeResult: Sendable, Equatable {
    /// Detokenized transcript of the (possibly truncated) tokens.
    let text: String
    let tokenCount: Int
    let stopReason: MLXAsrStopReason
    /// True when the decode guard, not the model, ended the loop.
    var guardTripped: Bool { stopReason != .endOfSequence }
}

/// The contract a model port (Qwen3-ASR, Granite Speech) implements. Everything else a
/// backend needs (download, lifecycle, cancellation, memory pressure, chunking) is in the
/// shared layer; see docs/mlx-asr-backends.md.
///
/// Conformers are marked `@unchecked Sendable`: `MLXAsrTranscriber` guarantees that at most
/// one `transcribe` call runs at a time and that `unload` never overlaps a running decode.
/// Weights must also be released when the object is deallocated, because `unload` is not
/// called for a runtime that is dropped without ever being installed.
protocol MLXAsrRuntime: AnyObject, Sendable {
    /// Reads the validated weights from disk. Called once per runtime, before `warmup`.
    func load() async throws

    /// Runs a tiny decode so kernels compile before the first real window.
    func warmup() async throws

    /// Transcribes one window of 16 kHz mono samples (at most 28 s). Synchronous.
    ///
    /// Drive the token loop with `MLXAsrDecodeGuard.decode(maxTokens:nextToken:)` so the cap,
    /// the repetition guard and the per-token cancellation check apply. The call runs on a dedicated
    /// thread, so `Task.isCancelled` is not visible; only the guard loop sees the cancel token. Throw
    /// `CancellationError` (the guard loop does) when cancelled; never return partial text.
    /// - Parameters:
    ///   - language: model-specific language hint, `nil` for automatic.
    ///   - maxTokens: cap computed from the window length. Pass it to the decode loop.
    func transcribe(samples: [Float], language: String?, maxTokens: Int) throws -> MLXAsrDecodeResult

    /// Releases weights and device buffers. Idempotent.
    func unload()
}

/// Process-wide MLX cache controls, injectable so tests never touch Metal.
protocol MLXAsrMemoryControl: Sendable {
    func setCacheLimit(bytes: Int)
    func clearCache()
}

/// Production implementation. The MLX cache limit is global, so it also applies to any
/// other MLX user in the process (Bodhan's decoder) once an MLX ASR model has loaded.
struct MLXMemoryControl: MLXAsrMemoryControl {
    func setCacheLimit(bytes: Int) { Memory.cacheLimit = bytes }
    func clearCache() { Memory.clearCache() }
}

/// Delivers system memory-pressure events. A dispatch source, not a timer, so App Nap
/// cannot suspend it.
protocol MLXAsrMemoryPressureSource: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable () -> Void)
    func cancel()
}

final class DispatchMemoryPressureSource: MLXAsrMemoryPressureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        let created = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                              queue: .global(qos: .utility))
        created.setEventHandler(handler: handler)
        created.resume()
        source = created
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
