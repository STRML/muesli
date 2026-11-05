import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

// These tests extend ConfigStoreTests rather than adding a suite, so they run in the
// shard that already owns config persistence. Every path lives under a temp home;
// nothing here touches the real ~/.muesli or any real Application Support folder.
extension ConfigStoreTests {
    private struct Harness {
        let home: URL
        let supportDirectory: URL
        let mirror: ConfigBackupMirror
        let store: ConfigStore
        let trashDirectory: URL

        var mirrorFile: URL { mirror.fileURL }
        var configFile: URL { store.configPath() }

        init(trash: (@Sendable (URL) throws -> Void)? = nil) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("muesli-backup-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            supportDirectory = home.appendingPathComponent("Library/Application Support/MuesliTest", isDirectory: true)
            let fakeTrash = root.appendingPathComponent("trash", isDirectory: true)
            trashDirectory = fakeTrash
            mirror = ConfigBackupMirror(
                directoryURL: MuesliPaths.backupDirectoryURL(appName: "MuesliTest", home: home),
                trash: trash ?? { url in
                    try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
                }
            )
            store = ConfigStore(
                supportDirectory: supportDirectory,
                vault: TestCredentialVault.forDirectory(supportDirectory),
                backupMirror: mirror
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        }

        func userConfig(words: [String] = ["Kubernetes", "Tailscale"]) -> AppConfig {
            var config = AppConfig()
            config.customWords = words.map { CustomWord(word: $0, replacement: nil) }
            return config
        }

        func coordinator() -> ConfigBackupRestoreCoordinator {
            ConfigBackupRestoreCoordinator(mirror: mirror)
        }
    }

    // MARK: - Matrix: normal save

    @Test("backup: a save mirrors the sanitized config under <home>/.muesli/backup/<AppName>")
    func backupNormalSave() throws {
        let h = Harness()
        defer { h.cleanUp() }
        var config = h.userConfig()
        config.openAIAPIKey = "sk-backup-secret"

        #expect(h.store.save(config))

        #expect(h.mirror.directoryURL == h.home.appendingPathComponent(".muesli/backup/MuesliTest"))
        let mirrored = try Data(contentsOf: h.mirrorFile)
        #expect(mirrored == (try Data(contentsOf: h.configFile)))
        #expect(!String(decoding: mirrored, as: UTF8.self).contains("sk-backup-secret"))
        #expect(h.mirror.storedUserWords().map(\.word) == ["Kubernetes", "Tailscale"])
        let attributes = try FileManager.default.attributesOfItem(atPath: h.mirrorFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(h.store.lastBackupOutcome == .written)
    }

    @Test("backup: prod, dev and lane identities get separate folders")
    func backupFoldersPerIdentity() {
        let home = URL(fileURLWithPath: "/tmp/muesli-backup-paths", isDirectory: true)
        let folders = ["Muesli", "MuesliDev", "MuesliDevA"].map {
            MuesliPaths.backupDirectoryURL(appName: $0, home: home).path
        }
        #expect(Set(folders).count == 3)
        #expect(folders.allSatisfy { $0.hasPrefix(home.path + "/.muesli/backup/") })
    }

    @Test("backup: a failed mirror write is reported and the save still succeeds")
    func backupWriteFailureDoesNotFailSave() throws {
        let h = Harness()
        defer { h.cleanUp() }
        // A regular file where the .muesli folder should be makes every mirror write fail.
        try FileManager.default.createDirectory(at: h.home, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: h.home.appendingPathComponent(".muesli"))

        #expect(h.store.save(h.userConfig()))

        guard case .failed = h.store.lastBackupOutcome else {
            Issue.record("expected a failed backup outcome, got \(String(describing: h.store.lastBackupOutcome))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: h.configFile.path))
    }

    // MARK: - Matrix: empty config over a populated mirror

    @Test("backup: a seed-only config never replaces a mirror that has custom words")
    func backupKeepsMirrorAgainstSeedOnlyConfig() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        let before = try Data(contentsOf: h.mirrorFile)

        #expect(h.store.save(AppConfig()))

        #expect(try Data(contentsOf: h.mirrorFile) == before)
        #expect(h.store.lastBackupOutcome == .keptExistingWords)
        #expect(h.mirror.storedUserWords().count == 2)
    }

    @Test("backup: a config with an empty dictionary never replaces a mirror that has custom words")
    func backupKeepsMirrorAgainstEmptyDictionary() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        let before = try Data(contentsOf: h.mirrorFile)

        #expect(h.store.save(h.userConfig(words: [])))

        #expect(try Data(contentsOf: h.mirrorFile) == before)
        #expect(h.store.lastBackupOutcome == .keptExistingWords)
    }

    @Test("backup: a config that still has words replaces the mirror")
    func backupFollowsEditsThatKeepWords() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))

        #expect(h.store.save(h.userConfig(words: ["Anthropic"])))

        #expect(h.mirror.storedUserWords().map(\.word) == ["Anthropic"])
    }

    // MARK: - Matrix: corrupt mirror

    @Test("backup: a corrupt mirror raises no offer, no crash, and the next save rewrites it")
    func backupCorruptMirror() throws {
        let h = Harness()
        defer { h.cleanUp() }
        try FileManager.default.createDirectory(at: h.mirror.directoryURL, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: h.mirrorFile)

        #expect(h.mirror.storedUserWords().isEmpty)
        #expect(h.coordinator().pendingOffer(configWords: CustomWord.defaultWords, hasCompletedOnboarding: true) == nil)

        #expect(h.store.save(h.userConfig()))

        #expect(h.mirror.storedUserWords().map(\.word) == ["Kubernetes", "Tailscale"])
    }

    // MARK: - Matrix: fresh install

    @Test("backup: a fresh install with no mirror raises no offer")
    func backupFreshInstall() {
        let h = Harness()
        defer { h.cleanUp() }

        let config = h.store.load()

        #expect(!FileManager.default.fileExists(atPath: h.mirrorFile.path))
        #expect(h.coordinator().pendingOffer(configWords: config.customWords, hasCompletedOnboarding: true) == nil)
    }

    @Test("backup: a mirror holding only the built-in word raises no offer")
    func backupSeedOnlyMirrorRaisesNoOffer() {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(AppConfig()))

        #expect(h.coordinator().pendingOffer(configWords: [], hasCompletedOnboarding: true) == nil)
    }

    // MARK: - Matrix: config wiped, mirror populated

    @Test("backup: a wiped config with a populated mirror offers the words once, and Restore clears the offer")
    func backupRestoreOffer() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        // The uninstaller removes Application Support but leaves ~/.muesli.
        try FileManager.default.removeItem(at: h.supportDirectory)

        var config = h.store.load()
        let coordinator = h.coordinator()
        let offer = try #require(coordinator.pendingOffer(
            configWords: config.customWords,
            hasCompletedOnboarding: true
        ))
        #expect(offer.words.map(\.word) == ["Kubernetes", "Tailscale"])

        // Once shown, the same launch does not ask again.
        coordinator.markOffered()
        #expect(coordinator.pendingOffer(configWords: config.customWords, hasCompletedOnboarding: true) == nil)

        // Restore, then save: the next launch has nothing to offer.
        config.customWords = coordinator.restoredWords(for: offer, into: config.customWords)
        #expect(h.store.save(config))
        #expect(config.customWords.contains { $0.word == "Kubernetes" })
        #expect(h.coordinator().pendingOffer(
            configWords: h.store.load().customWords,
            hasCompletedOnboarding: true
        ) == nil)
    }

    @Test("backup: onboarding saves over a wiped config do not clobber the mirror")
    func backupSurvivesOnboardingSave() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        try FileManager.default.removeItem(at: h.supportDirectory)

        var config = h.store.load()
        config.hasCompletedOnboarding = true
        #expect(h.store.save(config))

        #expect(h.mirror.storedUserWords().map(\.word) == ["Kubernetes", "Tailscale"])
    }

    // MARK: - Matrix: Delete backup

    @Test("backup: Delete backup moves the mirror to the Trash and ends the offer")
    func backupDeleteSucceeds() throws {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        let coordinator = h.coordinator()

        #expect(coordinator.deleteBackup())

        #expect(!FileManager.default.fileExists(atPath: h.mirrorFile.path))
        #expect(FileManager.default.fileExists(atPath: h.trashDirectory.appendingPathComponent("config.json").path))
        #expect(h.coordinator().pendingOffer(configWords: [], hasCompletedOnboarding: true) == nil)
    }

    @Test("backup: a failed Trash move is reported and the offer stays quiet for the rest of the launch")
    func backupDeleteFailure() throws {
        struct TrashError: Error {}
        let h = Harness(trash: { _ in throw TrashError() })
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        let coordinator = h.coordinator()
        #expect(coordinator.pendingOffer(configWords: [], hasCompletedOnboarding: true) != nil)

        #expect(!coordinator.deleteBackup())

        #expect(FileManager.default.fileExists(atPath: h.mirrorFile.path))
        #expect(coordinator.pendingOffer(configWords: [], hasCompletedOnboarding: true) == nil)
        // The next launch is a fresh coordinator and asks again.
        #expect(h.coordinator().pendingOffer(configWords: [], hasCompletedOnboarding: true) != nil)
    }

    // MARK: - Matrix: onboarding not finished

    @Test("backup: no offer until onboarding completes")
    func backupWaitsForOnboarding() {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(h.store.save(h.userConfig()))
        let coordinator = h.coordinator()

        #expect(coordinator.pendingOffer(configWords: [], hasCompletedOnboarding: false) == nil)
        #expect(coordinator.pendingOffer(configWords: [], hasCompletedOnboarding: true) != nil)
    }

    // MARK: - Launch seeding

    @Test("backup: writeBackup seeds the mirror for an existing install without rewriting config.json")
    func backupSeedsExistingInstall() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let plain = ConfigStore(
            supportDirectory: h.supportDirectory,
            vault: TestCredentialVault.forDirectory(h.supportDirectory)
        )
        #expect(plain.save(h.userConfig()))
        let configBytes = try Data(contentsOf: h.configFile)
        #expect(!FileManager.default.fileExists(atPath: h.mirrorFile.path))

        h.store.writeBackup(of: h.store.load())

        #expect(try Data(contentsOf: h.mirrorFile) == configBytes)
        #expect(try Data(contentsOf: h.configFile) == configBytes)
    }

    @Test("backup: a store built without a mirror writes nothing outside its support directory")
    func backupOffByDefault() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backup-off-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = makeTestConfigStore(supportDirectory: supportDirectory)

        #expect(store.save(AppConfig()))

        #expect(store.backupMirror == nil)
        #expect(store.lastBackupOutcome == nil)
    }
}
