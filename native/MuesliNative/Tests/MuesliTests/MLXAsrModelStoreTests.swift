import CryptoKit
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

/// A fake Hugging Face host. Paths look like `/<repo>/resolve/<revision>/<file>`.
private final class StubHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var files: [String: Data] = [:]
    private nonisolated(unsafe) static var requested: [String] = []
    private nonisolated(unsafe) static var statusOverride: Int?

    static func reset(files: [String: Data] = [:], statusOverride: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.files = files; requested = []; self.statusOverride = statusOverride
    }
    static func serve(_ path: String, _ data: Data) { lock.lock(); files[path] = data; lock.unlock() }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return requested }
    static func clearRequests() { lock.lock(); requested = []; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (data, status): (Data, Int) = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.requested.append(url.path)
            if let forced = Self.statusOverride { return (Data(), forced) }
            if let data = Self.files[url.path] { return (data, 200) }
            return (Data(), 404)
        }()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct Fixture {
    let root: URL
    let coordinator: ModelDownloadCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-asr-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHub.self]
        coordinator = ModelDownloadCoordinator(configuration: configuration)
        StubHub.reset()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    static func revision(_ character: Character) -> String { String(repeating: character, count: 40) }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a store for `revision` whose manifest lists `files`, and serves those bytes from the hub.
    func store(revision: String, files: [String: Data], serve: Bool = true) -> MLXAsrModelStore {
        let artifacts = files.sorted { $0.key < $1.key }.map {
            MLXAsrArtifact(path: $0.key, bytes: Int64($0.value.count), sha256: Self.sha256($0.value))
        }
        let spec = MLXAsrModelSpec(id: "unit-model", displayName: "Unit Model", repository: "example/unit-model",
                                   revision: revision, files: artifacts, cacheRoot: root)
        if serve {
            for (path, data) in files { StubHub.serve("/example/unit-model/resolve/\(revision)/\(path)", data) }
        }
        return MLXAsrModelStore(spec: spec, coordinator: coordinator)
    }

    /// Requested file paths with the repository and revision prefix removed.
    func requestedFiles(revision: String) -> [String] {
        let prefix = "/example/unit-model/resolve/\(revision)/"
        return StubHub.requests.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }.sorted()
    }
}

private let payload: [String: Data] = [
    "config.json": Data("{\"model_type\":\"unit\"}".utf8),
    "vocab.json": Data(String(repeating: "v", count: 700).utf8),
    "weights.safetensors": Data((0..<4096).map { UInt8($0 % 251) }),
]

/// Failure matrix rows 1, 2, 11 and 18 (docs/mlx-asr-backends.md).
@Suite("MLX ASR model store", .serialized, .timeLimit(.minutes(1)))
struct MLXAsrModelStoreTests {
    @Test("A model that was never downloaded is not ready and leaves nothing on disk")
    func modelNotDownloaded() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.store(revision: Fixture.revision("a"), files: payload)
        #expect(store.status == .notDownloaded)
        #expect(!store.isDownloaded)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("Missing files and leftover .part files are partial, never ready")
    func partialDownloadIsNotReady() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.store(revision: Fixture.revision("a"), files: payload)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try payload["config.json"]!.write(to: store.directory.appendingPathComponent("config.json"))
        try Data("half".utf8).write(to: store.directory.appendingPathComponent("weights.safetensors.part"))
        #expect(store.status == .partial)
        #expect(!store.isDownloaded)

        // A finished install that later loses a file goes back to partial.
        try await store.download()
        #expect(store.status == .ready)
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("vocab.json"))
        #expect(store.status == .partial)
        #expect(!store.isDownloaded)
    }

    @Test("A truncated or same-size corrupt file fails validation and only that file is fetched again")
    func truncatedFileFailsValidation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let revision = Fixture.revision("a")
        let store = fixture.store(revision: revision, files: payload)
        try await store.download()
        #expect(store.isDownloaded)
        #expect(try await store.invalidFiles().isEmpty)

        let weights = store.directory.appendingPathComponent("weights.safetensors")
        try Data(payload["weights.safetensors"]!.prefix(100)).write(to: weights)
        #expect(store.status == .partial, "A short file must be visible without hashing")

        let vocab = store.directory.appendingPathComponent("vocab.json")
        try Data(String(repeating: "x", count: 700).utf8).write(to: vocab)
        #expect(try await store.invalidFiles() == ["vocab.json", "weights.safetensors"])

        StubHub.clearRequests()
        try await store.download()
        #expect(fixture.requestedFiles(revision: revision) == ["vocab.json", "weights.safetensors"])
        #expect(try Data(contentsOf: weights) == payload["weights.safetensors"])
        #expect(store.isDownloaded)
        #expect(try await store.invalidFiles().isEmpty)
    }

    @Test("A new pinned revision re-fetches only the files whose content changed")
    func staleRevisionRefetchesChangedFilesOnly() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let old = fixture.store(revision: Fixture.revision("a"), files: payload)
        try await old.download()
        #expect(old.isDownloaded)

        var updated = payload
        updated["vocab.json"] = Data(String(repeating: "w", count: 710).utf8)
        updated["merges.txt"] = Data("a b\nc d\n".utf8)
        let new = fixture.store(revision: Fixture.revision("b"), files: updated)
        #expect(new.status == .updateRequired)
        #expect(!new.isDownloaded)

        StubHub.clearRequests()
        try await new.download()
        #expect(fixture.requestedFiles(revision: Fixture.revision("b")) == ["merges.txt", "vocab.json"])
        #expect(new.isDownloaded)
        #expect(try Data(contentsOf: new.directory.appendingPathComponent("vocab.json")) == updated["vocab.json"])
        #expect(!old.isDownloaded, "The previous revision no longer matches the marker")
    }

    @Test("Files that left the manifest are removed only after the new revision installs")
    func staleFilesRemoved() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        var oldFiles = payload
        oldFiles["tokenizer.model"] = Data("retired".utf8)
        let old = fixture.store(revision: Fixture.revision("a"), files: oldFiles)
        try await old.download()
        let retired = old.directory.appendingPathComponent("tokenizer.model")
        #expect(FileManager.default.fileExists(atPath: retired.path))

        // The update fails: the hub has no copy of the changed file.
        var changed = payload
        changed["vocab.json"] = Data(String(repeating: "q", count: 710).utf8)
        let failing = fixture.store(revision: Fixture.revision("b"), files: changed, serve: false)
        for (path, data) in changed where path != "vocab.json" {
            StubHub.serve("/example/unit-model/resolve/\(Fixture.revision("b"))/\(path)", data)
        }
        await #expect(throws: (any Error).self) { try await failing.download() }
        #expect(FileManager.default.fileExists(atPath: retired.path), "A failed update must keep the old files")
        #expect(!failing.isDownloaded)

        let working = fixture.store(revision: Fixture.revision("b"), files: changed)
        try await working.download()
        #expect(working.isDownloaded)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: working.directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(leftovers) == Set(changed.keys))
    }

    @Test("Wrong bytes under the pinned revision are reported as unavailable and nothing is marked ready")
    func hostingMismatchFails() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let revision = Fixture.revision("a")
        let store = fixture.store(revision: revision, files: payload)
        // Same size, different content: the hash is the only thing that can catch it.
        StubHub.serve("/example/unit-model/resolve/\(revision)/vocab.json", Data(String(repeating: "x", count: 700).utf8))
        await #expect(throws: MLXAsrModelStoreError.modelUnavailable("Unit Model")) { try await store.download() }
        #expect(!store.isDownloaded)
        #expect(store.status != .ready)
        let tamperedRequests = StubHub.requests

        // The repository is gone entirely.
        StubHub.reset(statusOverride: 404)
        await #expect(throws: MLXAsrModelStoreError.modelUnavailable("Unit Model")) { try await store.download() }
        #expect(!store.isDownloaded)

        // Every request named the pinned revision; there was no fallback to main.
        let allRequests = tamperedRequests + StubHub.requests
        #expect(!tamperedRequests.isEmpty && !StubHub.requests.isEmpty)
        #expect(allRequests.allSatisfy { $0.contains("/resolve/\(revision)/") })
        #expect(allRequests.allSatisfy { !$0.contains("/resolve/main/") })
    }

    @Test("A rate limit or timeout status is a retryable download error, not an unavailable model", arguments: [429, 408])
    func transientHTTPStatusIsNotUnavailable(status: Int) async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.store(revision: Fixture.revision("a"), files: payload)
        StubHub.reset(statusOverride: status)
        do {
            try await store.download()
            Issue.record("Download unexpectedly succeeded")
        } catch let error as ModelDownloadError {
            guard case .invalidHTTPStatus(status, _) = error else { Issue.record("Unexpected \(error)"); return }
        } catch {
            Issue.record("Expected the coordinator's error to pass through, got \(error)")
        }
        #expect(!store.isDownloaded)
    }

    @Test("A manifest without a pinned 40-character revision is rejected before any request",
          arguments: ["main", "", "v1.0", "abc123", String(repeating: "g", count: 40)])
    func unpinnedRevisionRejected(revision: String) async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.store(revision: revision, files: payload)
        #expect(throws: MLXAsrModelStoreError.self) { try store.spec.validate() }
        await #expect(throws: MLXAsrModelStoreError.self) { try await store.download() }
        #expect(StubHub.requests.isEmpty)
    }

    @Test("A manifest with a bad digest, empty file, duplicate path or escaping path is rejected")
    func malformedManifestRejected() throws {
        let good = MLXAsrArtifact(path: "a.bin", bytes: 4, sha256: String(repeating: "a", count: 64))
        let variants: [[MLXAsrArtifact]] = [
            [],
            [MLXAsrArtifact(path: "a.bin", bytes: 4, sha256: "short")],
            [MLXAsrArtifact(path: "a.bin", bytes: 0, sha256: String(repeating: "a", count: 64))],
            [good, good],
            [MLXAsrArtifact(path: "../escape.bin", bytes: 4, sha256: String(repeating: "a", count: 64))],
            [MLXAsrArtifact(path: "/abs.bin", bytes: 4, sha256: String(repeating: "a", count: 64))],
        ]
        for files in variants {
            let spec = MLXAsrModelSpec(id: "m", displayName: "M", repository: "o/m",
                                       revision: Fixture.revision("a"), files: files)
            #expect(throws: MLXAsrModelStoreError.self) { try spec.validate() }
        }
    }

    @Test("Deleting a model removes its files, marker and progress state")
    func deleteRemovesEverything() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = fixture.store(revision: Fixture.revision("a"), files: payload)
        try await store.download()
        try await store.delete()
        #expect(store.status == .notDownloaded)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        #expect(remaining.isEmpty)
        try await store.delete()  // idempotent
    }
}
