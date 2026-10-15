import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

/// Opt-in: teaches the classifier from the folders already in a real Muesli database (as if you had
/// filed those meetings in the app), then classifies the unfiled ones with the configured summary
/// backend. The app must be quit. A backup of the database is written first.
///
///   MUESLI_LIVE_DB=".../muesli.db" MUESLI_LIVE_CONFIG=".../config.json" swift test --filter LiveClassificationRunTests
///
/// Output: meeting title, outcome, folder name. Private meetings only reach the backend if it is trusted.
@Suite("Live classification run (opt-in)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MUESLI_LIVE_DB"] != nil
                && ProcessInfo.processInfo.environment["MUESLI_LIVE_CONFIG"] != nil))
struct LiveClassificationRunTests {
    @Test("seed learning from filed meetings, then classify the unfiled ones")
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let dbURL = URL(fileURLWithPath: try #require(env["MUESLI_LIVE_DB"]))
        let configURL = URL(fileURLWithPath: try #require(env["MUESLI_LIVE_CONFIG"]))
        var config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        config.meetingSummaryRetryCount = 0

        let backup = dbURL.deletingLastPathComponent().appendingPathComponent("muesli.db.bak-before-live-classify-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.copyItem(at: dbURL, to: backup)

        let dictation = DictationStore(databaseURL: dbURL)
        let classification = FolderClassificationStore(databaseURL: dbURL)
        let folders = try dictation.listFolders()
        let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })

        let meetings = try dictation.recentMeetings(limit: 100_000)
        let filed = meetings.filter { $0.folderID != nil }
        for meeting in filed { try classification.recordMove(meetingID: meeting.id, toFolder: meeting.folderID) }
        print("[live-classify] seeded learning from \(filed.count) filed meetings")

        let classifier = FolderClassifier(databaseURL: dbURL)
        var counts: [String: Int] = [:]
        for meeting in meetings where meeting.folderID == nil {
            let outcome = await classifier.classify(meetingID: meeting.id, config: config)
            counts["\(outcome)", default: 0] += 1
            print("[live-classify] \(meeting.title) -> \(outcome)")
        }
        print("[live-classify] outcomes: \(counts)")
        for row in try classification.pendingSuggestions() {
            print("[live-classify] pending: \(row.meetingTitle) => \(names[row.suggestion.folderID] ?? "?") (\(row.suggestion.source.rawValue), \(String(format: "%.2f", row.suggestion.confidence)))")
        }
    }
}
