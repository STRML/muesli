import Foundation
import Testing
@testable import MuesliNativeApp

private typealias Support = MLXAsrTestSupport

private func samples(seconds: Double) -> [Float] {
    [Float](repeating: 0.1, count: Int(seconds * 16_000))
}

/// A runtime body that decodes through the shared loop until it is cancelled or released.
private func cancellableSpin(entered: @escaping @Sendable () -> Void) -> StubMLXAsrRuntime.Body {
    { _, _ in
        entered()
        var next = 0
        let outcome = try MLXAsrDecodeGuard.decode(maxTokens: 1_000_000) {
            Thread.sleep(forTimeInterval: 0.002)
            next += 1
            return next  // distinct ids, so the repetition guard never ends the loop
        }
        return StubMLXAsrRuntime.text("unreachable \(outcome.tokens.count)")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Failure matrix rows 3, 4, 8, 9, 10 and 17 (docs/mlx-asr-backends.md).
@Suite("MLX ASR transcriber lifecycle", .timeLimit(.minutes(1)))
struct MLXAsrLifecycleTests {
    @Test("Shutdown prevents an in-flight load from restoring runtime state")
    func shutdownDuringLoad() async {
        let log = MLXAsrTestLog()
        let loadGate = MLXAsrTestGate()
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in
            await loadGate.suspend()
            return StubMLXAsrRuntime(name: "stale", log: log)
        }
        let preparing = Task { try await transcriber.prepare(model) }
        await loadGate.waitUntilEntered()
        await transcriber.shutdown()
        await loadGate.release()
        do {
            try await preparing.value
            Issue.record("Stale preparation unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        let state = await transcriber.lifecycleState
        #expect(state.loadedModelID == nil && state.loadingModelID == nil)
        #expect(!state.hasRuntime && !state.hasCompletedWarmup)
        #expect(log.events.contains("unload:stale"), "A runtime that finished loading after shutdown must be released")
    }

    @Test("A failed load leaves clean state and the next prepare loads again")
    func loadFailureClearsState() async throws {
        struct LoadFailure: Error {}
        let calls = MLXAsrTestLog()
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in
            calls.add("loader")
            if calls.count(of: "loader") == 1 { throw LoadFailure() }
            return StubMLXAsrRuntime(name: "second", log: calls)
        }
        await #expect(throws: LoadFailure.self) { try await transcriber.prepare(model) }
        let failed = await transcriber.lifecycleState
        #expect(failed.loadedModelID == nil && failed.loadingModelID == nil)
        #expect(!failed.hasRuntime && !failed.hasCompletedWarmup)

        try await transcriber.prepare(model)
        let loaded = await transcriber.lifecycleState
        #expect(calls.count(of: "loader") == 2)
        #expect(loaded.loadedModelID == model.id)
        #expect(loaded.hasRuntime && loaded.hasCompletedWarmup)
    }

    @Test("Cancelling a window mid-decode commits nothing and the next window still works")
    func cancelMidWindowCommitsNothing() async throws {
        let log = MLXAsrTestLog()
        let entered = Flag()
        let runtime = StubMLXAsrRuntime(name: "rt", log: log) { audio, index in
            if index == 0 { return try cancellableSpin(entered: { entered.set() })(audio, index) }
            return StubMLXAsrRuntime.text("after cancel")
        }
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in runtime }
        let window = Task { try await transcriber.transcribeWindow(samples(seconds: 3), model: model, language: nil) }
        #expect(await Support.waitUntil { entered.isSet })
        window.cancel()
        do {
            _ = try await window.value
            Issue.record("A cancelled window must not return a result")
        } catch {
            #expect(error is CancellationError)
        }
        let afterCancel = await transcriber.lifecycleState
        #expect(afterCancel.completedWindowCount == 0)
        #expect(afterCancel.hasRuntime, "Cancelling a window keeps the model loaded")

        let next = try await transcriber.transcribeWindow(samples(seconds: 3), model: model, language: nil)
        #expect(next.text == "after cancel")
        #expect(await transcriber.lifecycleState.completedWindowCount == 1)
    }

    @Test("A second caller waits behind the running window, in order, one runtime call at a time")
    func concurrentDictationWaitsBehindChunk() async throws {
        let log = MLXAsrTestLog()
        let release = DispatchSemaphore(value: 0)
        let entered = Flag()
        let runtime = StubMLXAsrRuntime(name: "rt", log: log) { _, index in
            if index == 0 {
                entered.set()
                release.wait()
            }
            return StubMLXAsrRuntime.text("window \(index)")
        }
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in runtime }

        let meeting = Task { try await transcriber.transcribeWindow(samples(seconds: 5), model: model, language: nil) }
        #expect(await Support.waitUntil { entered.isSet })
        let dictation = Task { try await transcriber.transcribeWindow(samples(seconds: 2), model: model, language: nil) }
        #expect(await Support.waitUntil { transcriber.inFlightWindowCount == 2 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(runtime.callCount == 1, "The queued window must not start while another is running")

        release.signal()
        let first = try await meeting.value
        let second = try await dictation.value
        #expect(first.text == "window 0" && second.text == "window 1")
        #expect(runtime.maximumConcurrentCalls == 1)
        #expect(transcriber.inFlightWindowCount == 0)
        let order = log.events.filter { $0.hasPrefix("transcribe-") }
        #expect(order == ["transcribe-start:rt:0", "transcribe-end:rt:0", "transcribe-start:rt:1", "transcribe-end:rt:1"])
    }

    @Test("Deleting the loaded model cancels its running window; another model's delete does nothing")
    func deleteWhileLoaded() async throws {
        let log = MLXAsrTestLog()
        let entered = Flag()
        let finished = Flag()
        let runtime = StubMLXAsrRuntime(name: "rt", log: log) { audio, index in
            defer { finished.set() }
            return try cancellableSpin(entered: { entered.set() })(audio, index)
        }
        let model = Support.model(id: "loaded-model")
        let transcriber = Support.transcriber { _, _, _ in runtime }
        let window = Task { try await transcriber.transcribeWindow(samples(seconds: 3), model: model, language: nil) }
        #expect(await Support.waitUntil { entered.isSet })

        await transcriber.shutdown(ifLoadedModelID: "some-other-model")
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(!finished.isSet, "Deleting a different model must not touch the running window")
        #expect(await transcriber.lifecycleState.loadedModelID == "loaded-model")

        await transcriber.shutdown(ifLoadedModelID: "loaded-model")
        do {
            _ = try await window.value
            Issue.record("The window of a deleted model must be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
        let events = log.events
        let end = try #require(events.firstIndex(of: "transcribe-end:rt:0"))
        let unload = try #require(events.firstIndex(of: "unload:rt"))
        #expect(unload > end, "Weights may only be released after the running decode has exited")
        let state = await transcriber.lifecycleState
        #expect(state.loadedModelID == nil && !state.hasRuntime)
    }

    @Test("Memory pressure while idle unloads at once and the next window reloads")
    func memoryPressureUnloadsWhenIdle() async throws {
        let log = MLXAsrTestLog()
        let notified = MLXAsrTestLog()
        let model = Support.model(id: "pressured")
        let transcriber = Support.transcriber(onPressureUnload: { notified.add($0) }) { _, _, _ in
            log.add("loader")
            return StubMLXAsrRuntime(name: "rt\(log.count(of: "loader"))", log: log)
        }
        _ = try await transcriber.transcribeWindow(samples(seconds: 3), model: model, language: nil)
        await transcriber.noteMemoryPressure()
        let unloaded = await transcriber.lifecycleState
        #expect(!unloaded.hasRuntime && unloaded.loadedModelID == nil)
        #expect(unloaded.pressureUnloadCount == 1)
        #expect(log.events.contains("unload:rt1"))
        #expect(notified.events == ["pressured"])

        let again = try await transcriber.transcribeWindow(samples(seconds: 3), model: model, language: nil)
        #expect(again.text == "ok")
        #expect(log.count(of: "loader") == 2)
    }

    @Test("Memory pressure during a chunk lets that chunk finish, then unloads")
    func memoryPressureUnloadsBetweenChunks() async throws {
        let log = MLXAsrTestLog()
        let release = DispatchSemaphore(value: 0)
        let entered = Flag()
        let runtime = StubMLXAsrRuntime(name: "rt", log: log) { _, _ in
            entered.set()
            release.wait()
            return StubMLXAsrRuntime.text("finished chunk")
        }
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in runtime }
        let window = Task { try await transcriber.transcribeWindow(samples(seconds: 5), model: model, language: nil) }
        #expect(await Support.waitUntil { entered.isSet })

        await transcriber.noteMemoryPressure()
        let during = await transcriber.lifecycleState
        #expect(during.hasRuntime, "The runtime must stay loaded while a decode is running")
        #expect(!log.events.contains("unload:rt"))

        release.signal()
        let result = try await window.value
        #expect(result.text == "finished chunk")
        let after = await transcriber.lifecycleState
        #expect(!after.hasRuntime && after.pressureUnloadCount == 1)
        let events = log.events
        let end = try #require(events.firstIndex(of: "transcribe-end:rt:0"))
        let unload = try #require(events.firstIndex(of: "unload:rt"))
        #expect(unload > end)
    }

    @Test("The dispatch-source handler reaches the actor and unloads; no timer is involved")
    func pressureSourceDrivesUnload() async throws {
        let source = MLXAsrTestPressureSource()
        let model = Support.model()
        let transcriber = Support.transcriber(pressure: source) { _, _, _ in StubMLXAsrRuntime() }
        #expect(!source.isStarted)
        try await transcriber.prepare(model)
        #expect(source.isStarted, "Monitoring starts when a model loads")
        source.fire()
        var unloaded = false
        for _ in 0..<500 where !unloaded {
            unloaded = await transcriber.lifecycleState.pressureUnloadCount == 1
            if !unloaded { try await Task.sleep(nanoseconds: 4_000_000) }
        }
        #expect(unloaded)
        #expect(!(await transcriber.lifecycleState.hasRuntime))
    }

    @Test("The MLX cache limit is set on load and the cache is cleared after every finished window")
    func cacheLimitAndClear() async throws {
        let memory = MLXAsrTestMemory()
        let model = Support.model()
        let transcriber = Support.transcriber(memory: memory) { _, _, _ in StubMLXAsrRuntime() }
        for _ in 0..<4 { _ = try await transcriber.transcribeWindow(samples(seconds: 1), model: model, language: nil) }
        #expect(memory.cacheLimits == [123_456])
        #expect(memory.clearCount == 4)
    }

    @Test("The token cap passed to the runtime follows the window length")
    func capFollowsWindowLength() async throws {
        let runtime = StubMLXAsrRuntime { _, _ in StubMLXAsrRuntime.text("x") }
        let model = Support.model()
        let transcriber = Support.transcriber { _, _, _ in runtime }
        _ = try await transcriber.transcribeWindow(samples(seconds: 28), model: model, language: "en")
        _ = try await transcriber.transcribeWindow(samples(seconds: 2), model: model, language: nil)
        #expect(runtime.requestedMaxTokens == [280, 48])
        #expect(runtime.requestedLanguages == ["en", nil])
    }
}
