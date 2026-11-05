import Foundation
import MuesliCore

/// Decides when to offer the dictionary stored in the settings backup, and carries out the answer.
///
/// The offer appears at most once per launch, only after onboarding has finished, and only
/// when the live dictionary holds nothing the user wrote while the backup does. Both answers
/// end it: Restore fills the dictionary, so the condition stops holding; Delete backup removes
/// the file. A failed delete is logged and suppresses the offer for the rest of the launch.
final class ConfigBackupRestoreCoordinator {
    struct Offer: Equatable {
        let words: [CustomWord]
    }

    private let mirror: ConfigBackupMirror?
    private var handledThisLaunch = false

    init(mirror: ConfigBackupMirror?) {
        self.mirror = mirror
    }

    func pendingOffer(configWords: [CustomWord], hasCompletedOnboarding: Bool) -> Offer? {
        guard let mirror, hasCompletedOnboarding, !handledThisLaunch,
              CustomWordDictionaryCodec.userWords(in: configWords).isEmpty else { return nil }
        let stored = mirror.storedUserWords()
        return stored.isEmpty ? nil : Offer(words: stored)
    }

    /// Call when the offer is put in front of the user, so a second trigger cannot stack another.
    func markOffered() {
        handledThisLaunch = true
    }

    /// The dictionary after Restore: the backup's words merged into the current ones.
    func restoredWords(for offer: Offer, into current: [CustomWord]) -> [CustomWord] {
        CustomWordDictionaryCodec.merge(offer.words, into: current).words
    }

    /// Returns false when the Trash move failed; the failure is logged and the offer stays
    /// suppressed for this launch.
    @discardableResult
    func deleteBackup() -> Bool {
        handledThisLaunch = true
        guard let mirror else { return true }
        do {
            try mirror.trashBackup()
            return true
        } catch {
            fputs("[config-backup] could not move the backup to the Trash: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
