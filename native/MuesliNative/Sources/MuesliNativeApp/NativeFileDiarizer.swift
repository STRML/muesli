import FluidAudio
import Foundation

/// Headless access to the post-meeting speaker diarizer: the same coordinator,
/// models, runtime policy and windowed session the app runs after a meeting.
/// It leaves the app's diarization log and telemetry alone.
public enum NativeFileDiarizer {
    public struct Segment: Sendable, Equatable {
        public let speaker: String
        public let start: Double
        public let end: Double

        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    public static func diarize(
        wavURL: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [Segment] {
        let coordinator = TranscriptionCoordinator(
            diarizerDiagnostics: DiarizerPreloadDiagnostics(signalSink: { _, _ in })
        )
        progress("loading speaker diarization models")
        await coordinator.preloadDiarizer(trigger: .audioImport)
        progress("diarizing")
        let segments = try await coordinator.runRecordedAudioDiarization(at: wavURL) { _ in }
        return segments.map {
            Segment(speaker: $0.speakerId, start: milliseconds($0.startTimeSeconds), end: milliseconds($0.endTimeSeconds))
        }
    }

    private static func milliseconds(_ seconds: Float) -> Double {
        (Double(seconds) * 1000).rounded() / 1000
    }
}
