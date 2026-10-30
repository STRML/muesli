import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// The Settings picker's model list: loaded once per connection, never shown for a connection it was not listed for.
@Suite("Custom LLM model list in Settings")
@MainActor
struct CustomLLMModelListControllerTests {
    private struct Offline: LocalizedError {
        var errorDescription: String? { "offline" }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if opened { return true }
                    self.continuation = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeController() throws -> (MuesliController, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = ConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.customLLMURL = "http://one.example.test/v1"
        configStore.save(config)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore)
        return (controller, directory)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for the model list")
    }

    @Test("a successful listing fills the picker")
    func loads() async throws {
        let (controller, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.customLLMModelsFetch = { _ in ["qwen3-8b", "llama-3"] }
        controller.loadCustomLLMModels()
        #expect(controller.appState.customLLMModelsState == .loading)
        try await waitUntil { controller.appState.customLLMModelsState == .loaded }
        #expect(controller.appState.customLLMModels == ["qwen3-8b", "llama-3"])
    }

    @Test("a failure leaves the list empty and says why")
    func fails() async throws {
        let (controller, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.customLLMModelsFetch = { _ in throw Offline() }
        controller.loadCustomLLMModels()
        try await waitUntil { controller.appState.customLLMModelsState != .loading }
        #expect(controller.appState.customLLMModelsState == .failed("offline"))
        #expect(controller.appState.customLLMModels.isEmpty)
    }

    @Test("the same connection is listed once unless a refresh is forced")
    func listsOncePerConnection() async throws {
        let (controller, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Counter()
        controller.customLLMModelsFetch = { _ in calls.increment(); return ["m"] }
        controller.loadCustomLLMModels()
        try await waitUntil { controller.appState.customLLMModelsState == .loaded }
        controller.loadCustomLLMModels()
        controller.loadCustomLLMModels()
        #expect(calls.count == 1)
        controller.loadCustomLLMModels(force: true)
        try await waitUntil { calls.count == 2 }
    }

    @Test("a new endpoint clears the old list at once, and a late answer for the old one is dropped")
    func staleAnswerIsDropped() async throws {
        let (controller, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = Gate()
        controller.customLLMModelsFetch = { config in
            if config.customLLMURL.contains("one.example") {
                await gate.wait()
                return ["from-one"]
            }
            return ["from-two"]
        }
        controller.loadCustomLLMModels()
        #expect(controller.appState.customLLMModelsState == .loading)

        controller.updateConfig { $0.customLLMURL = "http://two.example.test/v1" }
        controller.loadCustomLLMModels()
        #expect(controller.appState.customLLMModels.isEmpty)
        try await waitUntil { controller.appState.customLLMModelsState == .loaded }
        #expect(controller.appState.customLLMModels == ["from-two"])

        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.appState.customLLMModels == ["from-two"], "the late answer for the first endpoint must not replace it")
    }

    @Test("picking a model does not relist")
    func pickingAModelDoesNotRelist() async throws {
        let (controller, directory) = try makeController()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Counter()
        controller.customLLMModelsFetch = { _ in calls.increment(); return ["a", "b"] }
        controller.loadCustomLLMModels()
        try await waitUntil { controller.appState.customLLMModelsState == .loaded }
        controller.updateConfig { $0.customLLMModel = "b" }
        controller.loadCustomLLMModels()
        #expect(calls.count == 1)
    }
}
