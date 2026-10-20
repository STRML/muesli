import FluidAudio
import Foundation
import MuesliCore

/// System capture for in-person meetings. Nothing is captured, so macOS never
/// asks for Screen Recording or system-audio access, and every call is inert.
final class NoOpSystemAudioCapture: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    let isRecording = false
    let isPaused = false
    func start() async throws {}
    func pause() {}
    func resume() {}
    func stop() -> URL? { nil }
}

/// In-person meetings record the microphone only. The mic transcript is run
/// through the same diarization path as system audio, so one mic in a room
/// yields "Speaker N" labels.
enum InPersonMeeting {
    /// Label used when diarization produced nothing usable (model missing, no speech found).
    static let undiarizedSpeaker = "Speaker 1"

    /// Diarization needs a full-length mic file even when the user never keeps recordings.
    static func shouldRetainWriter(policy: MeetingRecordingSavePolicy, inPerson: Bool) -> Bool {
        inPerson || policy != .never
    }

    /// The controller moves or deletes the retained recording as soon as it is
    /// handed over, so diarization works on a private copy.
    static func diarizationCopy(of url: URL?) -> URL? {
        guard let url else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-in-person-\(UUID().uuidString).wav")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            fputs("[meeting] could not copy mic recording for diarization: \(error)\n", stderr)
            return nil
        }
    }

    /// Diarizes and deletes the copy. Any failure means "no diarization", never a failed meeting.
    static func diarize(copy: URL?, using coordinator: TranscriptionCoordinator) async -> [TimedSpeakerSegment]? {
        guard let copy else { return nil }
        defer { try? FileManager.default.removeItem(at: copy) }
        return try? await coordinator.diarizeSystemAudio(at: copy)?.segments
    }
}
