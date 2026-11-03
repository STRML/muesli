import Foundation
import Testing
import MuesliCore

/// Opt-in: runs the real retention service against real audio files in a scratch directory and a
/// scratch database. Set MUESLI_LIVE_AUDIO to any audio file. Nothing outside the scratch directory
/// is touched, and only counts and sizes are printed.
@Suite("Live retention run (opt-in)", .serialized,
       .enabled(if: (ProcessInfo.processInfo.environment["MUESLI_LIVE_AUDIO"]).map { FileManager.default.fileExists(atPath: $0) } ?? false))
struct LiveRetentionRunTests {
    @Test("oldest real recordings are pruned to the budget; pinned and recent ones, and all transcripts, stay")
    func run() throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MUESLI_LIVE_AUDIO"]))
        let sourceBytes = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("live-retention-\(UUID())", isDirectory: true)
        let recordings = scratch.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: scratch.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()

        // Six meetings, 40 down to 1 day old, each with its own copy of the real recording.
        var ids: [Int64] = []
        let now = Date()
        for (index, daysAgo) in [40, 30, 20, 10, 3, 1].enumerated() {
            let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let id = try store.createLiveMeeting(title: "Meeting \(index)", calendarEventID: nil, startTime: start)
            try store.completeLiveMeeting(id: id, title: "Meeting \(index)", calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(1800), rawTranscript: "transcript \(index)", formattedNotes: "notes \(index)",
                micAudioPath: nil, systemAudioPath: nil)
            let file = recordings.appendingPathComponent("rec-\(index).mp3")
            try FileManager.default.copyItem(at: source, to: file)
            try store.updateMeetingSavedRecordingPath(id: id, path: file.path)
            ids.append(id)
        }
        let service = RecordingRetentionService(databaseURL: scratch.appendingPathComponent("muesli.db"), recordingsDirectory: recordings)
        let before = try service.usageBytes()
        try service.setPinned(true, meetingID: ids[1])   // the 30-day-old meeting is kept

        // Budget of two and a half copies, minimum age 7 days.
        let budget = Int64(Double(sourceBytes) * 2.5)
        let result = try service.run(budgetBytes: budget, minimumAgeDays: 7, now: now)
        let after = try service.usageBytes()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted()
        print("[live-retention] file=\(sourceBytes) bytes, before=\(before), budget=\(budget), after=\(after), deleted=\(result.deletedFiles), freedBytes=\(result.freedBytes)")
        print("[live-retention] remaining files: \(remaining)")

        #expect(before == sourceBytes * 6)
        #expect(after <= budget || remaining.count <= 4, "pinned and recent audio may legitimately keep it over budget")
        #expect(!remaining.contains("rec-0.mp3"), "the oldest, unpinned recording is removed")
        #expect(remaining.contains("rec-1.mp3"), "the pinned recording stays")
        #expect(remaining.contains("rec-4.mp3") && remaining.contains("rec-5.mp3"), "recordings younger than 7 days stay")
        for (index, id) in ids.enumerated() {
            let meeting = try #require(try store.meeting(id: id))
            #expect(meeting.rawTranscript == "transcript \(index)" && meeting.formattedNotes == "notes \(index)", "text is never touched")
        }
        try? FileManager.default.removeItem(at: scratch)
    }
}
