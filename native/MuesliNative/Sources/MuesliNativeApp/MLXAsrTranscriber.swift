import Foundation
import MuesliCore
import os

/// What a model port registers: where its files live and how to build its runtime.
struct MLXAsrModel: Sendable {
    let store: MLXAsrModelStore
    /// Cheap, synchronous construction from the validated model folder. Loading happens in
    /// `MLXAsrRuntime.load()`.
    let makeRuntime: @Sendable (_ directory: URL) -> any MLXAsrRuntime
    var id: String { store.spec.id }
    var displayName: String { store.spec.displayName }
}

/// Owns one resident MLX ASR runtime and serializes inference on it.
///
/// - One window runs at a time; later callers wait in FIFO order (dictation behind a meeting
///   chunk). `inFlightWindowCount` is readable without entering the actor, for a UI notice.
/// - Each window runs in a Task this actor owns, so cancelling the caller, `shutdown()` or
///   deleting the model stops the decode within one token. Weights are released only after
///   that decode has exited.
/// - A generation counter, as in `BodhanTranscriber`, stops a load or window that finishes
///   after `shutdown()` from restoring stale state.
/// - The MLX cache is cleared after every window. System memory pressure unloads the model
///   between windows through a dispatch source. There is deliberately no idle timer:
///   LSUIElement apps have timers suspended by App Nap.
actor MLXAsrTranscriber {
    /// Returns a loaded runtime: download, construct, `load()`.
    typealias RuntimeLoader = @Sendable (MLXAsrModel, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> any MLXAsrRuntime

    struct LifecycleState: Equatable {
        let loadedModelID: String?
        let loadingModelID: String?
        let hasRuntime: Bool
        let hasCompletedWarmup: Bool
        let completedWindowCount: Int
        let pressureUnloadCount: Int
    }

    static let sampleRate = 16_000
    /// Starting value, not yet tuned against measured memory. The limit is process-wide.
    static let defaultCacheLimitBytes = 512 * 1024 * 1024

    /// Downloads and verifies the model, builds the runtime and loads it.
    static let downloadingLoader: RuntimeLoader = { model, progress, progressSnapshot in
        try await model.store.download(progress: progress, progressSnapshot: progressSnapshot)
        try Task.checkCancellation()
        progress?(0.9, "Preparing " + model.displayName + "...")
        let runtime = model.makeRuntime(model.store.directory)
        try await runtime.load()
        return runtime
    }

    private let memory: any MLXAsrMemoryControl
    private let pressureSource: (any MLXAsrMemoryPressureSource)?
    private let cacheLimitBytes: Int
    private let onMemoryPressureUnload: (@Sendable (String) -> Void)?
    private let runtimeLoader: RuntimeLoader
    private let pendingWindows = OSAllocatedUnfairLock(initialState: 0)

    private var runtime: (any MLXAsrRuntime)?
    private var model: MLXAsrModel?
    private var loadingModel: MLXAsrModel?
    private var loadTask: Task<any MLXAsrRuntime, Error>?
    private var warmupTask: Task<Void, Error>?
    private var inFlightTask: Task<MLXAsrDecodeResult, Error>?
    private var generation = 0
    private var hasCompletedWarmup = false
    private var completedWindows = 0
    private var pressureUnloads = 0
    private var cacheLimitApplied = false
    private var monitoringPressure = false
    private var unloadAfterWindow = false
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(memory: any MLXAsrMemoryControl = MLXMemoryControl(),
         pressureSource: (any MLXAsrMemoryPressureSource)? = DispatchMemoryPressureSource(),
         cacheLimitBytes: Int = MLXAsrTranscriber.defaultCacheLimitBytes,
         onMemoryPressureUnload: (@Sendable (String) -> Void)? = nil,
         runtimeLoader: @escaping RuntimeLoader = MLXAsrTranscriber.downloadingLoader) {
        self.memory = memory
        self.pressureSource = pressureSource
        self.cacheLimitBytes = cacheLimitBytes
        self.onMemoryPressureUnload = onMemoryPressureUnload
        self.runtimeLoader = runtimeLoader
    }

    deinit { pressureSource?.cancel() }

    var lifecycleState: LifecycleState {
        LifecycleState(loadedModelID: model?.id, loadingModelID: loadingModel?.id,
                       hasRuntime: runtime != nil, hasCompletedWarmup: hasCompletedWarmup,
                       completedWindowCount: completedWindows, pressureUnloadCount: pressureUnloads)
    }

    /// Windows requested and not yet finished, including the one running.
    nonisolated var inFlightWindowCount: Int { pendingWindows.withLock { $0 } }

    // MARK: - Public API

    /// Downloads (if needed), loads and warms up `selected`, replacing any other loaded model.
    /// Waits behind a running window so a switch never cancels a chunk.
    func prepare(_ selected: MLXAsrModel,
                 progress: ((Double, String?) -> Void)? = nil,
                 progressSnapshot: ModelDownloadProgressHandler? = nil) async throws {
        await acquireGate()
        defer { releaseGate() }
        try Task.checkCancellation()
        try await prepareLocked(selected, progress: progress, progressSnapshot: progressSnapshot)
    }

    /// Transcribes one window (at most 28 s) of 16 kHz mono samples.
    /// Throws `CancellationError` if cancelled, in which case nothing is committed.
    func transcribeWindow(_ samples: [Float], model selected: MLXAsrModel, language: String?) async throws -> MLXAsrDecodeResult {
        pendingWindows.withLock { $0 += 1 }
        defer { pendingWindows.withLock { $0 -= 1 } }
        await acquireGate()
        defer { releaseGate() }
        try Task.checkCancellation()
        try await prepareLocked(selected, progress: nil, progressSnapshot: nil)
        guard let active = runtime, model?.id == selected.id else { throw CancellationError() }

        let expectedGeneration = generation
        let seconds = Double(samples.count) / Double(Self.sampleRate)
        let maxTokens = MLXAsrDecodeGuard.maxTokens(forChunkSeconds: seconds)
        let task = Task.detached(priority: Task.currentPriority) {
            try active.transcribe(samples: samples, language: language, maxTokens: maxTokens)
        }
        inFlightTask = task
        let result: MLXAsrDecodeResult
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            finishWindow(runtime: active, expectedGeneration: expectedGeneration)
            throw error
        }
        finishWindow(runtime: active, expectedGeneration: expectedGeneration)
        guard expectedGeneration == generation else { throw CancellationError() }
        try Task.checkCancellation()
        completedWindows += 1
        return result
    }

    /// Entry point for the memory-pressure dispatch source (also callable directly).
    /// An idle model unloads at once. During a window the unload waits until it finishes.
    func noteMemoryPressure() {
        guard runtime != nil, warmupTask == nil else { return }
        if gateHeld { unloadAfterWindow = true } else { unloadForMemoryPressure() }
    }

    /// Deleting one model must not unload a different active selection.
    func shutdown(ifLoadedModelID modelID: String) {
        guard model?.id == modelID || loadingModel?.id == modelID else { return }
        shutdown()
    }

    /// Cancels loads, warmups and the running window, and drops the runtime.
    func shutdown() {
        generation += 1
        loadTask?.cancel(); loadTask = nil; loadingModel = nil
        warmupTask?.cancel(); warmupTask = nil
        inFlightTask?.cancel()
        let stale = runtime
        runtime = nil; model = nil; hasCompletedWarmup = false; unloadAfterWindow = false
        // A running window still holds the runtime; it unloads when it exits.
        if inFlightTask == nil { stale?.unload() }
    }

    // MARK: - Serialization gate

    private func acquireGate() async {
        if gateHeld {
            await withCheckedContinuation { gateWaiters.append($0) }
        } else {
            gateHeld = true
        }
    }

    private func releaseGate() {
        if unloadAfterWindow {
            unloadAfterWindow = false
            unloadForMemoryPressure()
        }
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().resume()  // ownership passes to the next caller
        }
    }

    // MARK: - Load and warmup

    private func prepareLocked(_ selected: MLXAsrModel,
                               progress: ((Double, String?) -> Void)?,
                               progressSnapshot: ModelDownloadProgressHandler?) async throws {
        try await load(selected, progress: progress, progressSnapshot: progressSnapshot)
        guard let runtime, model != nil else { throw CancellationError() }
        let expectedGeneration = generation
        let warming = ModelDownloadProgress.preparing(modelID: selected.id, message: "Warming up " + selected.displayName + "...")
        if !hasCompletedWarmup {
            progress?(0.95, warming.message)
            progressSnapshot?(warming)
            if warmupTask == nil {
                warmupTask = Task {
                    try await runtime.warmup()
                    try Task.checkCancellation()
                }
            }
            do {
                if let warmupTask { try await warmupTask.value }
                try Task.checkCancellation()
                guard expectedGeneration == generation else { throw CancellationError() }
                hasCompletedWarmup = true
                warmupTask = nil
            } catch {
                if expectedGeneration == generation { warmupTask = nil }
                throw error
            }
        }
        progress?(1.0, selected.displayName + " ready")
        progressSnapshot?(warming.replacing(phase: .ready, message: selected.displayName + " ready"))
    }

    private func load(_ selected: MLXAsrModel,
                      progress: ((Double, String?) -> Void)?,
                      progressSnapshot: ModelDownloadProgressHandler?) async throws {
        if model?.id == selected.id, runtime != nil { return }
        if loadingModel?.id != selected.id || loadTask == nil {
            shutdown()
            loadingModel = selected
            let loader = runtimeLoader
            loadTask = Task { try await loader(selected, progress, progressSnapshot) }
        }
        let expectedGeneration = generation
        guard let task = loadTask else { throw CancellationError() }
        do {
            let loaded = try await task.value
            guard expectedGeneration == generation else {
                loaded.unload()  // finished after shutdown(): release instead of restoring
                throw CancellationError()
            }
            try Task.checkCancellation()
            runtime = loaded
            model = selected
            loadTask = nil
            loadingModel = nil
            applyCacheLimitOnce()
            startPressureMonitoringOnce()
        } catch {
            if expectedGeneration == generation { loadTask = nil; loadingModel = nil }
            throw error
        }
    }

    private func applyCacheLimitOnce() {
        guard !cacheLimitApplied else { return }
        cacheLimitApplied = true
        memory.setCacheLimit(bytes: cacheLimitBytes)
    }

    private func startPressureMonitoringOnce() {
        guard !monitoringPressure, let pressureSource else { return }
        monitoringPressure = true
        pressureSource.start { [weak self] in
            guard let self else { return }
            Task { await self.noteMemoryPressure() }
        }
    }

    // MARK: - Window and pressure bookkeeping

    private func finishWindow(runtime finished: any MLXAsrRuntime, expectedGeneration: Int) {
        inFlightTask = nil
        memory.clearCache()
        // shutdown() ran while the decode was still going and left the unload to us.
        if expectedGeneration != generation { finished.unload() }
    }

    private func unloadForMemoryPressure() {
        guard let loaded = runtime, let current = model else { return }
        loaded.unload()
        runtime = nil; model = nil; hasCompletedWarmup = false
        pressureUnloads += 1
        onMemoryPressureUnload?(current.id)
    }
}
