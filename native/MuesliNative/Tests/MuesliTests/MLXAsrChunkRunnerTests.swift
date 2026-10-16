import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

private typealias Support = MLXAsrTestSupport

private func audio(seconds: Double) -> [Float] {
    [Float](repeating: 0.1, count: Int((seconds * 16_000).rounded()))
}

private struct Rig {
    let runtime: StubMLXAsrRuntime
    let memory: MLXAsrTestMemory
    let transcriber: MLXAsrTranscriber
    let model: MLXAsrModel

    init(body: @escaping StubMLXAsrRuntime.Body) {
        let runtime = StubMLXAsrRuntime(body: body)
        let memory = MLXAsrTestMemory()
        self.runtime = runtime
        self.memory = memory
        self.model = Support.model()
        self.transcriber = Support.transcriber(memory: memory) { _, _, _ in runtime }
    }

    func runner(gate: MLXAsrChunkRunner.SpeechGate? = nil) -> MLXAsrChunkRunner {
        MLXAsrChunkRunner(transcriber: transcriber, model: model, speechGate: gate)
    }
}

/// Failure matrix rows 6, 7 and 13 (docs/mlx-asr-backends.md).
@Suite("MLX ASR chunk runner", .timeLimit(.minutes(2)))
struct MLXAsrChunkRunnerTests {
    @Test("A chunk the speech gate calls silent never reaches the model")
    func silentChunkReturnsEmpty() async throws {
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("should not run") }
        let runner = rig.runner(gate: { _ in false })
        let result = try await runner.transcribeChunk(samples: audio(seconds: 4))
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
        #expect(rig.runtime.callCount == 0)
        #expect(runner.health == MLXAsrChunkHealth(chunks: 1, silent: 1, empty: 0, failed: 0, guardTripped: 0))
    }

    @Test("A speech gate that fails lets the chunk through, like the coordinator's VAD path")
    func gateFailureFailsOpen() async throws {
        struct GateFailure: Error {}
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("hello there") }
        let runner = rig.runner(gate: { _ in throw GateFailure() })
        let result = try await runner.transcribeChunk(samples: audio(seconds: 4))
        #expect(result.text == "hello there")
        #expect(runner.health.silent == 0)
    }

    @Test("Engine artifacts that the model emits on near-silence are removed and the chunk counts as empty")
    func hallucinatedNearSilenceFiltered() async throws {
        for artifact in ["[BLANK_AUDIO]", "  [ Silence ]  ", "<|endoftext|>", "(foreign language)"] {
            let rig = Rig { _, _ in StubMLXAsrRuntime.text(artifact) }
            let runner = rig.runner()
            let result = try await runner.transcribeChunk(samples: audio(seconds: 3))
            #expect(result.text.isEmpty, "\(artifact)")
            #expect(result.segments.isEmpty, "\(artifact)")
            #expect(runner.health.empty == 1, "\(artifact)")
        }
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("Real speech [BLANK_AUDIO] continues") }
        let result = try await rig.runner().transcribeChunk(samples: audio(seconds: 3))
        #expect(result.text == "Real speech continues")
    }

    @Test("Thousands of chunks keep one window of audio per call and clear the MLX cache every time")
    func longAudioBoundedMemory() async throws {
        // A proxy for a multi-hour meeting: 2,000 live-sized chunks (about 2.8 hours of audio).
        // It proves per-chunk cleanup and window bounds, not resident memory.
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("word") }
        let runner = rig.runner()
        let chunk = audio(seconds: 5)
        for _ in 0..<2_000 { _ = try await runner.transcribeChunk(samples: chunk) }
        #expect(rig.runtime.callCount == 2_000)
        #expect(rig.runtime.windowSampleCounts.allSatisfy { $0 <= 5 * 16_000 })
        #expect(rig.memory.clearCount == 2_000)
        #expect(rig.memory.cacheLimits.count == 1)
        #expect(runner.health.chunks == 2_000)
        #expect(await rig.transcriber.lifecycleState.completedWindowCount == 2_000)
    }

    @Test("Dictation of a long recording uses 28 s windows on a 27 s hop and merges the overlap")
    func dictationWindowsMergeWithSharedMerger() async throws {
        let scripted = [
            "one two three four five six seven eight",
            "six seven eight nine ten eleven twelve",
            "eleven twelve thirteen",
        ]
        let rig = Rig { _, index in StubMLXAsrRuntime.text(scripted[index]) }
        let result = try await rig.runner().transcribeDictation(samples: audio(seconds: 60))
        #expect(rig.runtime.windowSampleCounts == [28 * 16_000, 28 * 16_000, 6 * 16_000])
        #expect(result.windowCount == 3)
        #expect(result.text == "one two three four five six seven eight nine ten eleven twelve thirteen")
        #expect(result.guardTrippedWindowCount == 0)
    }

    @Test("A short dictation is one window, and an empty recording makes no model call")
    func dictationShortAndEmpty() async throws {
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("short note") }
        let single = try await rig.runner().transcribeDictation(samples: audio(seconds: 5))
        #expect(single.text == "short note" && single.windowCount == 1)
        let empty = try await rig.runner().transcribeDictation(samples: [])
        #expect(empty.text.isEmpty && empty.windowCount == 0)
        #expect(rig.runtime.callCount == 1)
    }

    @Test("A chunk becomes one segment whose bounds are the chunk bounds")
    func chunkResultCarriesChunkBounds() async throws {
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("a short remark") }
        let result = try await rig.runner().transcribeChunk(samples: audio(seconds: 3.2))
        #expect(result.text == "a short remark")
        let segment = try #require(result.segments.first)
        #expect(result.segments.count == 1)
        #expect(segment.start == 0)
        #expect(abs(segment.end - 3.2) < 1e-9)
        #expect(segment.text == "a short remark")
    }

    @Test("Replay windows with 0.4 s overlap are stitched by the existing overlap remover")
    func replayDedupesOverlap() async throws {
        let scripted = ["the quick brown fox", "brown fox jumps over", "over the lazy dog"]
        let rig = Rig { _, index in StubMLXAsrRuntime.text(scripted[index]) }
        let runner = rig.runner()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-asr-replay-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.05 }
            for _ in 0..<12 { try writer.write(from: buffer) }
        }
        let result = try await MeetingRecordingTranscriber().transcribe(
            url: url, infer: { try await runner.transcribeChunk(at: $0) }, progress: { _, _ in })
        #expect(rig.runtime.callCount == 3)
        #expect(result.text == "the quick brown fox jumps over the lazy dog")
        #expect(result.segments.count == 3)
    }

    @Test("Guard trips are counted and the truncated text is still returned")
    func guardTripCounted() async throws {
        let rig = Rig { _, _ in StubMLXAsrRuntime.text("it keeps going", stop: .repetition) }
        let runner = rig.runner()
        let chunk = try await runner.transcribeChunk(samples: audio(seconds: 4))
        #expect(chunk.text == "it keeps going")
        let dictation = try await runner.transcribeDictation(samples: audio(seconds: 4))
        #expect(dictation.text == "it keeps going")
        #expect(dictation.guardTrippedWindowCount == 1)
        #expect(runner.health.guardTripped == 2)
    }

    @Test("A model failure is counted and rethrown; cancellation is neither")
    func failureCountedCancellationNot() async throws {
        struct ModelFailure: Error {}
        let failing = Rig { _, _ in throw ModelFailure() }
        let failingRunner = failing.runner()
        await #expect(throws: ModelFailure.self) { _ = try await failingRunner.transcribeChunk(samples: audio(seconds: 2)) }
        #expect(failingRunner.health.failed == 1)

        let cancelling = Rig { _, _ in throw CancellationError() }
        let cancellingRunner = cancelling.runner()
        await #expect(throws: CancellationError.self) { _ = try await cancellingRunner.transcribeChunk(samples: audio(seconds: 2)) }
        #expect(cancellingRunner.health.failed == 0)
    }
}
