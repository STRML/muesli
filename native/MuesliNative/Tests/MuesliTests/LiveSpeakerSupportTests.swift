import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Live speaker labels: setting, model store, transcript lines")
struct LiveSpeakerSupportTests {
    // MARK: Setting

    @Test("live speaker labels default to off")
    func defaultsOff() {
        #expect(AppConfig().enableLiveSpeakerLabels == false)
    }

    @Test("a config file without the key decodes to off")
    func missingKeyDecodesOff() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.enableLiveSpeakerLabels == false)
    }

    @Test("the setting round-trips through its snake_case key")
    func roundTrip() throws {
        var config = AppConfig()
        config.enableLiveSpeakerLabels = true
        let data = try JSONEncoder().encode(config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["enable_live_speaker_labels"] as? Bool == true)

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enableLiveSpeakerLabels == true)
    }

    @Test("a meeting only runs the labeler when its config snapshot has the setting on")
    func sessionGatedByConfigSnapshot() {
        let factory: LiveSpeakerLabelSession.EngineFactory = { throw LiveSpeakerModelStore.StoreError.notDownloaded }
        var config = AppConfig()
        #expect(MeetingSession.makeLiveSpeakerSession(config: config, factory: factory) == nil)

        config.enableLiveSpeakerLabels = true
        #expect(MeetingSession.makeLiveSpeakerSession(config: config, factory: factory) != nil)
    }

    // MARK: Model store

    @Test("a missing model throws before any loader or download runs")
    func missingModelNeverLoads() {
        var loaderCalls = 0
        #expect(throws: LiveSpeakerModelStore.StoreError.notDownloaded) {
            try LiveSpeakerModelStore.makeEngine(isDownloaded: false) {
                loaderCalls += 1
                return ScriptedLiveSpeakerEngine { _ in nil }
            }
        }
        #expect(loaderCalls == 0)
    }

    @Test("a cached model loads through the local loader")
    func cachedModelLoads() throws {
        let engine = try LiveSpeakerModelStore.makeEngine(isDownloaded: true) {
            ScriptedLiveSpeakerEngine(slotCount: 7) { _ in nil }
        }
        #expect(engine.slotCount == 7)
    }

    @Test("download state follows the compiled model directory in the cache")
    func downloadState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-speaker-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LiveSpeakerModelStore.isDownloaded(in: root) == false)

        try FileManager.default.createDirectory(
            at: LiveSpeakerModelStore.modelURL(in: root), withIntermediateDirectories: true
        )
        #expect(LiveSpeakerModelStore.isDownloaded(in: root) == true)
    }

    // MARK: Transcript lines

    private func segments() -> [SpeechSegment] {
        [
            SpeechSegment(start: 1, end: 2, text: "hello there"),
            SpeechSegment(start: 3, end: 4, text: "   "),
            SpeechSegment(start: 5, end: 6, text: "bye now"),
        ]
    }

    @Test("checkpoints keep Others while the Live tab shows the provisional label")
    func checkpointKeepsOthers() throws {
        let output = LiveMeetingTranscriptLines.make(
            segments: segments(),
            speaker: "Others",
            displaySpeakers: ["Speaker 2", "Speaker 1", "Speaker 1"],
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(output.checkpointEntries.map(\.speaker) == ["Others", "Others"])
        #expect(output.checkpointEntries.map(\.text) == ["hello there", "bye now"])
        try #require(output.displayLines.count == 2)
        #expect(output.displayLines[0].contains("] Speaker 2: hello there"))
        #expect(output.displayLines[1].contains("] Speaker 1: bye now"))
    }

    @Test("without display labels the Live tab uses the source label, as before")
    func sourceLabelWithoutDisplayLabels() throws {
        let output = LiveMeetingTranscriptLines.make(
            segments: segments(),
            speaker: "You",
            displaySpeakers: nil,
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(output.checkpointEntries.map(\.speaker) == ["You", "You"])
        try #require(output.displayLines.count == 2 && output.checkpointEntries.count == 2)
        #expect(output.displayLines[0].contains("] You: hello there"))
        #expect(output.checkpointEntries[0].startSeconds == 1)
        #expect(output.checkpointEntries[0].endSeconds == 2)
        #expect(output.checkpointEntries[0].timestampLabel.count == 8)
        #expect(output.displayLines[0].hasPrefix("[\(output.checkpointEntries[0].timestampLabel)]"))
    }

    // MARK: Display speakers for committed segments

    @Test("no live session means no display labels, so the Live tab is unchanged")
    func noSessionNoLabels() async {
        #expect(await MeetingSession.liveDisplaySpeakers(for: segments(), using: nil) == nil)
    }

    @Test("a failed session still answers every segment, so no text is dropped")
    func failedSessionAnswersOthers() async {
        let session = LiveSpeakerLabelSession(factory: { throw LiveSpeakerModelStore.StoreError.notDownloaded })
        session.start()
        #expect(await liveSpeakerWaitUntil { session.status == .failed(.loadFailed) })

        let labels = await MeetingSession.liveDisplaySpeakers(for: segments(), using: session)
        #expect(labels == ["Others", "Others", "Others"])
    }

    @Test("each segment gets its own label from its own time range")
    func perSegmentLabels() async {
        let engine = ScriptedLiveSpeakerEngine { frame in frame < 25 ? 0 : 2 }
        let session = LiveSpeakerLabelSession(factory: { engine })
        session.start()
        #expect(await liveSpeakerWaitUntil { session.status == .running })
        feedLiveSpeakerAudio(session, seconds: 10)

        let labels = await MeetingSession.liveDisplaySpeakers(for: segments(), using: session)
        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 2"])
    }
}
