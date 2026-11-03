import FluidAudio
import Foundation
import MuesliCore

/// Turns FluidAudio diarization output into one centroid per meeting speaker.
///
/// FluidAudio's `DiarizerManager.performCompleteDiarization` attaches the 256-dim
/// WeSpeaker embedding of each chunk's speaker slot to every `TimedSpeakerSegment`.
/// Its `speakerManager` also keeps running embeddings, but that state is shared across
/// meetings on one `DiarizerManager`, so centroids are rebuilt here from this meeting's
/// segments only.
enum SpeakerCentroidBuilder {
    /// Speakers with less diarized speech than this keep a row but no centroid: a short
    /// clip gives a noisy embedding that would make a poor voiceprint.
    static let minimumVoiceprintSeconds: Double = 10

    static func observations(
        from segments: [TimedSpeakerSegment],
        minimumSeconds: Double = minimumVoiceprintSeconds
    ) -> [MeetingSpeakerObservation] {
        let labels = TranscriptFormatter.speakerLabels(for: segments)
        let bySpeaker = Dictionary(grouping: segments, by: \.speakerId)
        return labels
            .sorted { speakerNumber($0.value) < speakerNumber($1.value) }
            .map { speakerID, label in
                let speakerSegments = bySpeaker[speakerID] ?? []
                let seconds = speakerSegments.reduce(0) { $0 + Double(max(0, $1.durationSeconds)) }
                let centroid = seconds >= minimumSeconds ? weightedCentroid(of: speakerSegments) : nil
                return MeetingSpeakerObservation(label: label, centroid: centroid, speechSeconds: seconds)
            }
    }

    /// Duration-weighted mean of the L2-normalized usable embeddings, renormalized.
    /// Only the dimension carrying the most speech is used, so a stray vector of another
    /// size cannot crash or skew the mean.
    private static func weightedCentroid(of segments: [TimedSpeakerSegment]) -> [Float]? {
        let usable = segments.compactMap { segment -> (vector: [Float], weight: Float)? in
            guard SpeakerVoiceprintMatcher.isUsable(segment.embedding), segment.durationSeconds > 0 else { return nil }
            return (normalized(segment.embedding), segment.durationSeconds)
        }
        let byDimension = Dictionary(grouping: usable, by: \.vector.count)
        guard let dominant = byDimension.max(by: { totalWeight($0.value) < totalWeight($1.value) })?.value,
              let dimension = dominant.first?.vector.count else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for item in dominant {
            for index in 0..<dimension { sum[index] += item.vector[index] * item.weight }
        }
        guard SpeakerVoiceprintMatcher.isUsable(sum) else { return nil }
        let centroid = normalized(sum)
        return SpeakerVoiceprintMatcher.isUsable(centroid) ? centroid : nil
    }

    private static func totalWeight(_ items: [(vector: [Float], weight: Float)]) -> Float {
        items.reduce(0) { $0 + $1.weight }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    private static func speakerNumber(_ label: String) -> Int {
        Int(label.dropFirst("Speaker ".count)) ?? .max
    }
}
