import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// In-person mode records only the microphone and diarizes it. Each test maps to
/// a row of the failure matrix in the PR description.
@Suite("In-person meeting", .serialized)
struct InPersonMeetingTests {
    private let start = Date(timeIntervalSince1970: 0)

    private func diar(_ id: String, _ from: Float, _ to: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: [], startTimeSeconds: from, endTimeSeconds: to, qualityScore: 1)
    }

    private func transcript(_ segments: [SpeechSegment], _ diarization: [TimedSpeakerSegment]?) -> [String] {
        // Same shape as MeetingSession.stop() in in-person mode: the mic transcript
        // travels as the diarized channel and there is no "You" channel.
        TranscriptFormatter.merge(
            micSegments: [], systemSegments: segments, diarizationSegments: diarization,
            meetingStart: start, undiarizedSystemSpeaker: InPersonMeeting.undiarizedSpeaker
        ).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func tempWav(samples: Int = 16_000) throws -> URL {
        let writer = try MeetingRecordingWriter(micOnly: true)
        writer.appendMic([Int16](repeating: 1000, count: samples))
        return try #require(writer.stop())
    }

    // Row: several voices in the room.
    @Test("two voices on one mic become Speaker 1 and Speaker 2, never You")
    func twoSpeakers() {
        let lines = transcript(
            [SpeechSegment(start: 0, end: 2, text: "hello"), SpeechSegment(start: 5, end: 7, text: "hi back")],
            [diar("A", 0, 3), diar("B", 4, 8)]
        )
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Speaker 1: hello"))
        #expect(lines[1].hasSuffix("Speaker 2: hi back"))
        #expect(!lines.contains { $0.contains("You:") || $0.contains("Others:") })
    }

    // Row: one-speaker room.
    @Test("a one-speaker room is a single Speaker 1")
    func oneSpeaker() {
        let lines = transcript(
            [SpeechSegment(start: 0, end: 2, text: "alone"), SpeechSegment(start: 30, end: 32, text: "still alone")],
            [diar("A", 0, 40)]
        )
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("Speaker 1:") })
    }

    // Rows: diarizer returns zero segments / diarizer model unavailable (nil).
    @Test("without diarization the transcript still reads as Speaker 1, not Others or You",
          arguments: [Optional<[TimedSpeakerSegment]>.none, .some([])])
    func undiarizedFallback(diarization: [TimedSpeakerSegment]?) {
        let lines = transcript([SpeechSegment(start: 0, end: 2, text: "words")], diarization)
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("Speaker 1: words"))
    }

    @Test("normal meetings keep labelling undiarized system audio Others")
    func defaultFallbackUnchanged() {
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: [SpeechSegment(start: 0, end: 1, text: "x")], meetingStart: start
        )
        #expect(result.contains("Others: x"))
    }

    // Row: diarizer model unavailable.
    @Test("diarization is skipped, not fatal, when the model is unavailable; the copy is cleaned up")
    func diarizerUnavailable() async throws {
        let copy = try tempWav()
        let segments = await InPersonMeeting.diarize(copy: copy, using: TranscriptionCoordinator())
        #expect(segments == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("a missing recording yields no diarization instead of failing")
    func noRecording() async {
        #expect(await InPersonMeeting.diarize(copy: nil, using: TranscriptionCoordinator()) == nil)
        #expect(InPersonMeeting.diarizationCopy(of: nil) == nil)
    }

    // Row: retention policy never.
    @Test("a full-length mic file is written even when the policy is never; normal meetings still honour it")
    func retentionPolicy() {
        for policy in MeetingRecordingSavePolicy.allCases {
            #expect(InPersonMeeting.shouldRetainWriter(policy: policy, inPerson: true))
            #expect(InPersonMeeting.shouldRetainWriter(policy: policy, inPerson: false) == (policy != .never))
        }
    }

    // Row: retention policy never, controller consumes (moves or deletes) the original.
    @Test("the diarization copy survives the controller consuming the original recording")
    func copySurvivesOriginalConsumption() throws {
        let original = try tempWav()
        let copy = try #require(InPersonMeeting.diarizationCopy(of: original))
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.removeItem(at: original)
        #expect(copy != original)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try Data(contentsOf: copy).count == 44 + 32_000)
    }

    // Row: pause/resume mid-meeting.
    @Test("mic-only writer streams straight to disk and keeps every sample across pause and resume")
    func micOnlyWriterAcrossPause() throws {
        let writer = try MeetingRecordingWriter(micOnly: true)
        let first = [Int16](repeating: 100, count: 800)
        let second = [Int16](repeating: -200, count: 480)
        writer.appendMic(first)
        writer.markPauseBoundary()
        writer.appendMic(second)
        let url = try #require(writer.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(pcm == first + second) // Not averaged against silence, no gap inserted.
    }

    // Row: no-op system capture start/stop/pause.
    @Test("no-op system capture never records, never yields a file, and survives any call order")
    func noOpCapture() async throws {
        let capture = NoOpSystemAudioCapture()
        var delivered = 0
        capture.onPCMSamples = { _ in delivered += 1 }
        try await capture.start()
        #expect(!capture.isRecording)
        capture.pause(); capture.resume(); capture.pause()
        #expect(capture.stop() == nil)
        #expect(capture.stop() == nil)
        capture.resume()
        #expect(delivered == 0)
        #expect(!capture.captureIsDead && !capture.isRebuilding)
    }

    // Row: crash-recovery checkpoint.
    @Test("live checkpoints stay source-labelled, so crash recovery needs no diarization")
    func checkpointLabel() {
        let lines = LiveMeetingTranscriptLines.make(
            segments: [SpeechSegment(start: 1, end: 2, text: "spoken")], speaker: "You",
            displaySpeakers: nil, meetingStart: start
        )
        #expect(lines.checkpointEntries.count == 1)
        #expect(lines.checkpointEntries[0].speaker == "You")
    }
}
