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
        minimumSeconds: Double = minimumVoiceprintSeconds,
        startingNumber: Int = 1
    ) -> [MeetingSpeakerObservation] {
        observations(
            from: segments,
            speakerEmbeddings: [:],
            minimumSeconds: minimumSeconds,
            labelPrefix: "Speaker",
            startingNumber: startingNumber
        )
    }

    static func observations(
        from segments: [TimedSpeakerSegment],
        speakerEmbeddings: [String: [Float]],
        minimumSeconds: Double = minimumVoiceprintSeconds,
        labelPrefix: String = "Speaker",
        startingNumber: Int = 1
    ) -> [MeetingSpeakerObservation] {
        let labels = speakerLabels(for: segments, prefix: labelPrefix, startingNumber: startingNumber)
        let bySpeaker = Dictionary(grouping: segments, by: \.speakerId)
        return labels
            .sorted { speakerNumber($0.value, prefix: labelPrefix) < speakerNumber($1.value, prefix: labelPrefix) }
            .map { speakerID, label in
                let speakerSegments = bySpeaker[speakerID] ?? []
                let seconds = speakerSegments.reduce(0) { $0 + Double(max(0, $1.durationSeconds)) }
                let centroid: [Float]?
                if seconds >= minimumSeconds {
                    centroid = weightedCentroid(of: speakerSegments) ?? validNormalized(speakerEmbeddings[speakerID])
                } else {
                    centroid = nil
                }
                return MeetingSpeakerObservation(label: label, centroid: centroid, speechSeconds: seconds)
            }
    }

    /// Observations for in-room microphone diarization when multiple significant
    /// local voices are present; returns empty when the room has one voice ("You").
    static func micObservations(
        from micDiarizationSegments: [TimedSpeakerSegment]?,
        speakerEmbeddings: [String: [Float]] = [:],
        minimumSeconds: Double = minimumVoiceprintSeconds
    ) -> [MeetingSpeakerObservation] {
        guard let localDiarization = SpeakerAttribution.localDiarization(from: micDiarizationSegments) else {
            return []
        }
        return observations(
            from: localDiarization,
            speakerEmbeddings: speakerEmbeddings,
            minimumSeconds: minimumSeconds,
            labelPrefix: "Local speaker"
        )
    }

    private static func speakerLabels(
        for diarizationSegments: [TimedSpeakerSegment],
        prefix: String,
        startingNumber: Int = 1
    ) -> [String: String] {
        if prefix == "Speaker" {
            return TranscriptFormatter.speakerLabels(for: diarizationSegments, startingNumber: startingNumber)
        }
        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = max(1, startingNumber)
        for segment in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if labelMap[segment.speakerId] == nil {
                labelMap[segment.speakerId] = "\(prefix) \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
            }
        }
        return labelMap
    }

    private static func validNormalized(_ vector: [Float]?) -> [Float]? {
        guard let vector, SpeakerVoiceprintMatcher.isUsable(vector) else { return nil }
        let unit = normalized(vector)
        return SpeakerVoiceprintMatcher.isUsable(unit) ? unit : nil
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

    private static func speakerNumber(_ label: String, prefix: String) -> Int {
        let marker = "\(prefix) "
        guard label.hasPrefix(marker) else { return .max }
        return Int(label.dropFirst(marker.count)) ?? .max
    }
}
