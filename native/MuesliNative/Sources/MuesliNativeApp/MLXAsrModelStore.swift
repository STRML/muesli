import Foundation
import MuesliCore

/// One file of a pinned model: relative path, exact size and SHA-256.
struct MLXAsrArtifact: Codable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
}

/// A model checkpoint pinned to one repository commit, with every file's size and digest
/// written in code. A model port supplies one of these; the store has no model knowledge.
struct MLXAsrModelSpec: Sendable, Equatable {
    /// Stable identifier, used as the cache folder name and the download job id.
    let id: String
    let displayName: String
    /// Hugging Face repository, `owner/name`.
    let repository: String
    /// Full 40-character commit hash. Branch names such as `main` are rejected.
    let revision: String
    let files: [MLXAsrArtifact]
    let cacheRoot: URL

    init(id: String, displayName: String, repository: String, revision: String,
         files: [MLXAsrArtifact], cacheRoot: URL = MLXAsrModelSpec.defaultCacheRoot) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.files = files
        self.cacheRoot = cacheRoot
    }

    static var defaultCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models")
    }

    var directory: URL { cacheRoot.appendingPathComponent(id) }

    func remoteURL(for path: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
    }

    /// Rejects a manifest that is not fully pinned: no commit hash, no files, a missing or
    /// malformed digest, an empty file, a duplicate path, or a path leaving the model folder.
    func validate() throws {
        func fail(_ reason: String) -> MLXAsrModelStoreError {
            .invalidSpec("\(displayName): \(reason)")
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard revision.count == 40, revision.unicodeScalars.allSatisfy(hex.contains) else {
            throw fail("revision must be a full commit hash, not \"\(revision)\"")
        }
        guard !files.isEmpty else { throw fail("the file list is empty") }
        var seen = Set<String>()
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw fail("unsafe path \"\(file.path)\"")
            }
            guard file.bytes > 0, BodhanModel.isSHA256(file.sha256) else {
                throw fail("\"\(file.path)\" needs a size and a SHA-256 digest")
            }
            guard seen.insert(file.path).inserted else { throw fail("duplicate path \"\(file.path)\"") }
        }
    }
}

enum MLXAsrModelStatus: Equatable, Sendable {
    /// Nothing on disk.
    case notDownloaded
    /// Some files, leftover `.part` files, or an install that lost a file.
    case partial
    /// A complete install of an older (or different) manifest; `download()` will update it.
    case updateRequired
    /// A complete install of exactly this manifest.
    case ready
}

enum MLXAsrModelStoreError: Error, LocalizedError, Equatable {
    case invalidSpec(String)
    /// The pinned revision cannot be fetched as specified: the repository or file is gone,
    /// or the bytes do not match the pinned size or digest. There is no fallback revision.
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidSpec(let reason): return "Invalid model manifest. " + reason
        case .modelUnavailable(let name): return "\(name) is unavailable. The download did not match the pinned model files."
        }
    }
}

/// Download, integrity and cleanup for one pinned MLX ASR model, on top of
/// `ModelDownloadCoordinator` (resumable, ETag, size and SHA-256 checks).
///
/// Readiness is a completion marker that is written only after the coordinator succeeds and
/// that records the installed revision and file list. `status` is cheap (sizes only) so it
/// is safe for UI getters; `invalidFiles()` re-hashes and should run on demand.
struct MLXAsrModelStore: Sendable {
    let spec: MLXAsrModelSpec
    let coordinator: ModelDownloadCoordinator

    init(spec: MLXAsrModelSpec, coordinator: ModelDownloadCoordinator = .shared) {
        self.spec = spec
        self.coordinator = coordinator
    }

    var directory: URL { spec.directory }
    var isDownloaded: Bool { status == .ready }

    private struct InstallMarker: Codable {
        let id: String
        let revision: String
        let files: [MLXAsrArtifact]
    }

    private static let markerName = ".muesli-mlx-asr-install.json"
    private var markerURL: URL { directory.appendingPathComponent(Self.markerName) }

    var status: MLXAsrModelStatus {
        if let marker = readMarker() {
            guard marker.revision == spec.revision, Set(marker.files) == Set(spec.files) else { return .updateRequired }
            return spec.files.allSatisfy(hasExpectedSize) ? .ready : .partial
        }
        let started = spec.files.contains { exists($0.path) || exists($0.path + ".part") }
        return started ? .partial : .notDownloaded
    }

    /// Paths whose content does not match the pinned size or digest, in manifest order.
    /// Hashes every file, so call it on demand rather than from a UI getter.
    func invalidFiles() async throws -> [String] {
        // Same streaming verifier Bodhan uses for its cached artifacts.
        try await BodhanModel.invalidCachedArtifacts(
            spec.files.map { BodhanModel.Artifact(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) },
            at: directory)
    }

    /// Installs or updates the pinned revision. Does nothing when `status` is `.ready`.
    /// The coordinator re-checks every file on disk and fetches only those that are missing,
    /// short or fail their digest. Files that left the manifest are removed last, so a failed
    /// update never strips the previous install.
    func download(progress: ((Double, String?) -> Void)? = nil,
                  progressSnapshot: ModelDownloadProgressHandler? = nil) async throws {
        try spec.validate()
        let current = status
        if current == .ready { return }
        // From here the on-disk files no longer match any recorded install.
        try? FileManager.default.removeItem(at: markerURL)

        let verb = current == .updateRequired ? "Updating" : "Downloading"
        let manifest = ModelDownloadManifest(
            id: spec.id, version: spec.revision,
            files: spec.files.map {
                ModelDownloadFile(relativePath: $0.path, remoteURL: spec.remoteURL(for: $0.path),
                                  expectedByteCount: $0.bytes, sha256: $0.sha256)
            },
            maximumConcurrency: 2)
        do {
            try await coordinator.download(manifest, to: directory) { snapshot in
                progress?(snapshot.fractionCompleted ?? 0, "\(verb) \(spec.displayName)...")
                progressSnapshot?(snapshot)
            }
        } catch let error as ModelDownloadError {
            throw Self.map(error, name: spec.displayName)
        }
        try writeMarker()
        removeFilesOutsideManifest()
    }

    /// Cancels an active download, then removes every file this model owns.
    func delete() async throws {
        await coordinator.cancelAndWait(modelID: spec.id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Private

    /// Errors that mean "the pinned bytes are not there" become `modelUnavailable`.
    /// Network, disk, rate-limit (429) and timeout (408) errors pass through so the UI can offer a retry.
    private static func map(_ error: ModelDownloadError, name: String) -> Error {
        switch error {
        case .invalidHTTPStatus(let status, _) where [401, 403, 404, 410, 451].contains(status):
            return MLXAsrModelStoreError.modelUnavailable(name)
        case .checksumMismatch, .sizeMismatch, .invalidContentLength:
            return MLXAsrModelStoreError.modelUnavailable(name)
        default:
            return error
        }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
    }

    private func hasExpectedSize(_ artifact: MLXAsrArtifact) -> Bool {
        let url = directory.appendingPathComponent(artifact.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size == artifact.bytes
    }

    private func readMarker() -> InstallMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(InstallMarker.self, from: data)
    }

    private func writeMarker() throws {
        let marker = InstallMarker(id: spec.id, revision: spec.revision, files: spec.files)
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    /// Removes regular files that are neither in the manifest nor hidden bookkeeping files.
    /// Symbolic links are left alone and never followed.
    private func removeFilesOutsideManifest() {
        let keep = Set(spec.files.map(\.path))
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: directory.path) else { return }
        for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            let url = directory.appendingPathComponent(relative)
            let type = (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
            if type == .typeRegular, !keep.contains(relative) { try? fm.removeItem(at: url) }
        }
    }
}
