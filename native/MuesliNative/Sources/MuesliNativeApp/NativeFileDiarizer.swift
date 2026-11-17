import FluidAudio
import Foundation

/// Headless access to the post-meeting speaker diarizer: the same coordinator,
/// models, runtime policy and windowed session the app runs after a meeting.
/// It leaves the app's diarization log, telemetry and preload crash marker alone.
public enum NativeFileDiarizer {
    public struct Segment: Sendable, Equatable, Encodable {
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
        let suiteName = "muesli-cli-diarize"
        guard let scratchDefaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.featureUnsupported) }
        let coordinator = TranscriptionCoordinator(
            diarizerDiagnostics: DiarizerPreloadDiagnostics(defaults: scratchDefaults, signalSink: { _, _ in })
        )
        progress("loading speaker diarization models")
        await coordinator.preloadDiarizer(
            trigger: .cli,
            waitTimeout: TranscriptionCoordinator.defaultDiarizerLoadOperationTimeout
        )
        progress("diarizing")
        let segments = try await coordinator.runRecordedAudioDiarization(at: wavURL) { _ in }
        return mergingWindowCuts(segments.map {
            Segment(speaker: $0.speakerId, start: milliseconds($0.startTimeSeconds), end: milliseconds($0.endTimeSeconds))
        })
    }

    /// The diarizer runs in 10 s windows and clips each segment to its window, so one
    /// speaker's turn arrives in pieces that touch at the cut. Joins those pieces.
    public static func mergingWindowCuts(_ segments: [Segment], tolerance: Double = 0.05) -> [Segment] {
        var merged: [Segment] = []
        var lastIndexBySpeaker: [String: Int] = [:]
        for segment in segments {
            guard let index = lastIndexBySpeaker[segment.speaker],
                  segment.start - merged[index].end <= tolerance else {
                lastIndexBySpeaker[segment.speaker] = merged.count
                merged.append(segment)
                continue
            }
            let last = merged[index]
            merged[index] = Segment(speaker: last.speaker, start: last.start, end: max(last.end, segment.end))
        }
        return merged
    }

    private static func milliseconds(_ seconds: Float) -> Double {
        (Double(seconds) * 1000).rounded() / 1000
    }
}
