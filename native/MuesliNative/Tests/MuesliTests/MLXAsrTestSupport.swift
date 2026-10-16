import Foundation
@testable import MuesliNativeApp

/// Thread-safe ordered event log shared by the stubs below.
final class MLXAsrTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ event: String) {
        lock.lock(); storage.append(event); lock.unlock()
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func count(of event: String) -> Int { events.filter { $0 == event }.count }
}

/// Intentionally ignores cancellation, like an in-flight model load can.
actor MLXAsrTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

final class MLXAsrTestMemory: MLXAsrMemoryControl, @unchecked Sendable {
    private let lock = NSLock()
    private var limits: [Int] = []
    private var clears = 0

    func setCacheLimit(bytes: Int) { lock.lock(); limits.append(bytes); lock.unlock() }
    func clearCache() { lock.lock(); clears += 1; lock.unlock() }
    var cacheLimits: [Int] { lock.lock(); defer { lock.unlock() }; return limits }
    var clearCount: Int { lock.lock(); defer { lock.unlock() }; return clears }
}

final class MLXAsrTestPressureSource: MLXAsrMemoryPressureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var cancelled = false

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    func cancel() { lock.lock(); cancelled = true; handler = nil; lock.unlock() }
    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }
    func fire() {
        lock.lock(); let current = handler; lock.unlock()
        current?()
    }
}

/// A scriptable runtime. `body` receives the samples and the zero-based call index.
final class StubMLXAsrRuntime: MLXAsrRuntime, @unchecked Sendable {
    typealias Body = @Sendable ([Float], Int) throws -> MLXAsrDecodeResult

    let name: String
    let log: MLXAsrTestLog
    private let body: Body
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var maxActive = 0
    private var sampleCounts: [Int] = []
    private var tokenCaps: [Int] = []
    private var languages: [String?] = []

    init(name: String = "rt", log: MLXAsrTestLog = MLXAsrTestLog(),
         body: @escaping Body = { _, _ in StubMLXAsrRuntime.text("ok") }) {
        self.name = name; self.log = log; self.body = body
    }

    static func text(_ text: String, stop: MLXAsrStopReason = .endOfSequence) -> MLXAsrDecodeResult {
        MLXAsrDecodeResult(text: text, tokenCount: text.split(separator: " ").count, stopReason: stop)
    }

    func load() async throws { log.add("load:\(name)") }
    func warmup() async throws { log.add("warmup:\(name)") }

    func transcribe(samples: [Float], language: String?, maxTokens: Int) throws -> MLXAsrDecodeResult {
        let index: Int = lock.withLock {
            let value = calls
            calls += 1; active += 1; maxActive = max(maxActive, active)
            sampleCounts.append(samples.count)
            tokenCaps.append(maxTokens)
            languages.append(language)
            return value
        }
        log.add("transcribe-start:\(name):\(index)")
        defer {
            lock.withLock { active -= 1 }
            log.add("transcribe-end:\(name):\(index)")
        }
        return try body(samples, index)
    }

    func unload() { log.add("unload:\(name)") }

    var callCount: Int { lock.withLock { calls } }
    var maximumConcurrentCalls: Int { lock.withLock { maxActive } }
    var windowSampleCounts: [Int] { lock.withLock { sampleCounts } }
    var requestedMaxTokens: [Int] { lock.withLock { tokenCaps } }
    var requestedLanguages: [String?] { lock.withLock { languages } }
}

enum MLXAsrTestSupport {
    static let sampleRate = 16_000

    static func model(id: String = "test-model", runtime: @escaping @Sendable () -> any MLXAsrRuntime = { StubMLXAsrRuntime() }) -> MLXAsrModel {
        let spec = MLXAsrModelSpec(
            id: id, displayName: id, repository: "example/\(id)",
            revision: String(repeating: "a", count: 40),
            files: [MLXAsrArtifact(path: "weights.safetensors", bytes: 1, sha256: String(repeating: "0", count: 64))],
            cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mlx-asr-tests-unused")
        )
        return MLXAsrModel(store: MLXAsrModelStore(spec: spec), makeRuntime: { _ in runtime() })
    }

    static func transcriber(
        memory: MLXAsrTestMemory = MLXAsrTestMemory(),
        pressure: MLXAsrTestPressureSource? = nil,
        onPressureUnload: (@Sendable (String) -> Void)? = nil,
        loader: @escaping MLXAsrTranscriber.RuntimeLoader
    ) -> MLXAsrTranscriber {
        MLXAsrTranscriber(memory: memory, pressureSource: pressure, cacheLimitBytes: 123_456,
                          onMemoryPressureUnload: onPressureUnload, runtimeLoader: loader)
    }

    static func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}
