import Foundation
import MuesliCore

/// Triggers for disk-budget audio retention. The pure rules and the executor live in
/// MuesliCore (`RecordingRetention.swift`); this only decides when to run them.
@MainActor
extension MuesliController {
    private static let recordingRetentionQueue = DispatchQueue(label: "com.muesli.recording-retention", qos: .utility)

    var recordingRetentionService: RecordingRetentionService {
        RecordingRetentionService(
            databaseURL: dictationStore.resolvedDatabaseURL,
            recordingsDirectory: configStore.supportDirectory().appendingPathComponent("meeting-recordings", isDirectory: true)
        )
    }

    /// Runs retention off the main actor. Does nothing while the budget is 0 (unlimited).
    /// Runs are serialized, and logs carry counts and bytes only, never transcript text.
    func scheduleRecordingRetention(activeMeetingID: Int64? = nil) {
        let budgetGB = config.recordingsBudgetGB
        guard budgetGB > 0 else { return }
        let service = recordingRetentionService
        let minimumAgeDays = config.recordingsMinimumAgeDays
        let active = Set([activeMeetingID].compactMap { $0 })
        Self.recordingRetentionQueue.async {
            do {
                let result = try service.run(
                    budgetBytes: Int64(budgetGB) * 1_000_000_000,
                    minimumAgeDays: minimumAgeDays,
                    activeMeetingIDs: active
                )
                if result.deletedFiles + result.failures + result.repairedPaths > 0 {
                    fputs("[muesli-native] recording retention: deleted=\(result.deletedFiles) freedBytes=\(result.freedBytes) failures=\(result.failures) repaired=\(result.repairedPaths)\n", stderr)
                }
            } catch {
                fputs("[muesli-native] recording retention failed: \(error)\n", stderr)
            }
        }
    }
}
