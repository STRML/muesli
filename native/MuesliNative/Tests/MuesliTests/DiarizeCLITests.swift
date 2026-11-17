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
}
