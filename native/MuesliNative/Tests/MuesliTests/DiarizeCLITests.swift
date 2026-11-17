import AVFoundation
import Foundation
import Testing
@testable import MuesliCLI
@testable import MuesliNativeApp

@Suite("Diarize CLI", .serialized)
struct DiarizeCLITests {
    @Test("spec advertises diarize")
    func specListsDiarize() {
        let spec = MuesliCLI.specPayload().commands.first { $0.name == "diarize" }
        #expect(spec?.usage.contains("--output") == true)
    }

    @Test("diarize parses a wav path and rejects unsupported extensions")
    func parsing() throws {
        let parsed = try DiarizeCommand.parse(["meeting.wav", "--output", "out.json"])
        #expect(parsed.file == "meeting.wav")
        #expect(parsed.output == "out.json")
        #expect(throws: Error.self) { _ = try DiarizeCommand.parse(["meeting.aiff"]) }
    }

    @Test("JSON payload lists start, end and speaker for each segment and counts distinct speakers")
    func payloadShape() throws {
        let payload = DiarizeJSONPayload(segments: [
            .init(speaker: "1", start: 0, end: 2.5),
            .init(speaker: "2", start: 2.5, end: 4),
            .init(speaker: "1", start: 4, end: 5),
        ])
        let envelope = SuccessEnvelope(
            command: "muesli-cli diarize",
            data: payload,
            meta: MetaBody(schemaVersion: 1, generatedAt: timestampString(), dbPath: "", warnings: [])
        )
        let json = try #require(JSONSerialization.jsonObject(with: encodedJSON(envelope)) as? [String: Any])
        #expect(json["command"] as? String == "muesli-cli diarize")
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["speakerCount"] as? Int == 2)
        let segments = try #require(data["segments"] as? [[String: Any]])
        #expect(segments.count == 3)
        #expect(segments[1]["speaker"] as? String == "2")
        #expect(segments[1]["start"] as? Double == 2.5)
        #expect(segments[1]["end"] as? Double == 4)
        #expect(Set(segments[0].keys) == ["start", "end", "speaker"])
    }

    @Test("the app's diarizer runs headlessly from the local model cache",
          .enabled(if: DiarizerModelCacheState.resolve() == .complete))
    func headlessDiarizationOfSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diarize-silence-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(16_000 * 12)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let segments = try await NativeFileDiarizer.diarize(wavURL: url, progress: { _ in })
        #expect(segments.isEmpty)
    }

    @Test("a speaker's turn cut at the 10 s window boundaries comes back as one segment")
    func windowCutsMerge() {
        let merged = NativeFileDiarizer.mergingWindowCuts([
            .init(speaker: "1", start: 2, end: 10),
            .init(speaker: "1", start: 10, end: 20),
            .init(speaker: "1", start: 20, end: 23.5),
            .init(speaker: "2", start: 23.5, end: 26),
            .init(speaker: "1", start: 27, end: 29),
            .init(speaker: "1", start: 31, end: 33),
        ])
        #expect(merged == [
            .init(speaker: "1", start: 2, end: 23.5),
            .init(speaker: "2", start: 23.5, end: 26),
            .init(speaker: "1", start: 27, end: 29),
            .init(speaker: "1", start: 31, end: 33),
        ])
    }

    @Test("overlapping speakers each keep one segment across a window cut")
    func overlappingWindowCutsMerge() {
        let merged = NativeFileDiarizer.mergingWindowCuts([
            .init(speaker: "A", start: 2, end: 10),
            .init(speaker: "B", start: 8, end: 10),
            .init(speaker: "A", start: 10, end: 13),
            .init(speaker: "B", start: 10, end: 12),
        ])
        #expect(merged == [
            .init(speaker: "A", start: 2, end: 13),
            .init(speaker: "B", start: 8, end: 12),
        ])
    }
}
