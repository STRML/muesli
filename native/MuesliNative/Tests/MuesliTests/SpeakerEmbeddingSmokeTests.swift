import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Opt-in real-audio check that FluidAudio's diarizer yields speaker embeddings of one
/// consistent dimension, and that they become usable centroids. Local only: set
/// MUESLI_SPEAKER_SMOKE_AUDIO to an audio file path. Prints counts and dimensions only.
@Suite("Speaker embedding smoke")
struct SpeakerEmbeddingSmokeTests {
    static let audioPath = ProcessInfo.processInfo.environment["MUESLI_SPEAKER_SMOKE_AUDIO"]

    @Test(
        "diarizer embeddings share one dimension and form centroids",
        .enabled(if: audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    )
    func realAudioEmbeddings() async throws {
        let url = URL(fileURLWithPath: try #require(Self.audioPath))
        let models = try await DiarizerModels.download()
        let manager = DiarizerManager()
        manager.initialize(models: models)

        let allSamples = try AudioConverter().resampleAudioFile(url)
        let samples = Array(allSamples.prefix(16_000 * 120))
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)

        let dimensions = Set(result.segments.map(\.embedding.count))
        let observations = SpeakerCentroidBuilder.observations(from: result.segments, minimumSeconds: 5)
        let centroidDimensions = Set(observations.compactMap(\.centroid?.count))
        print("[smoke] seconds=\(samples.count / 16_000) segments=\(result.segments.count) speakers=\(observations.count) segmentDims=\(dimensions.sorted()) centroids=\(observations.filter { $0.centroid != nil }.count) centroidDims=\(centroidDimensions.sorted())")

        #expect(!result.segments.isEmpty)
        #expect(dimensions == [SpeakerManager.embeddingSize])
        #expect(centroidDimensions == [SpeakerManager.embeddingSize])
        for centroid in observations.compactMap(\.centroid) {
            #expect(SpeakerVoiceprintMatcher.isUsable(centroid))
            #expect(abs(SpeakerVoiceprintMatcher.cosineSimilarity(centroid, centroid)! - 1) < 0.001)
        }
    }

    /// Real-voice check of the matching thresholds: diarize three separate 8-minute windows of one
    /// recording as if they were three meetings, treat window A's speakers as named people, and see
    /// whether windows B and C match them. Prints numbers only; no text and no names.
    @Test(
        "the same voices in different windows of one recording match the earlier window's speakers",
        .enabled(if: audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    )
    func realVoicesMatchAcrossWindows() async throws {
        let url = URL(fileURLWithPath: try #require(Self.audioPath))
        let models = try await DiarizerModels.download()
        let all = try AudioConverter().resampleAudioFile(url)
        let window = 16_000 * 60 * 8

        func observations(startMinute: Int) throws -> [MeetingSpeakerObservation] {
            let start = 16_000 * 60 * startMinute
            guard all.count >= start + window else { return [] }
            let manager = DiarizerManager()
            manager.initialize(models: models)
            let result = try manager.performCompleteDiarization(Array(all[start..<(start + window)]), sampleRate: 16_000)
            return SpeakerCentroidBuilder.observations(from: result.segments)
        }

        let a = try observations(startMinute: 0)
        let b = try observations(startMinute: 15)
        let c = try observations(startMinute: 30)
        let people = a.compactMap(\.centroid).enumerated().map { SpeakerVoiceprintMatcher.Profile(id: Int64($0.offset + 1), voiceprints: [$0.element]) }
        print("[match] window speakers with a voiceprint: A=\(people.count) B=\(b.compactMap(\.centroid).count) C=\(c.compactMap(\.centroid).count)")

        for (name, window) in [("B", b), ("C", c)] {
            let candidates = window.map { SpeakerVoiceprintMatcher.Candidate(label: $0.label, centroid: $0.centroid) }
            let assigned = SpeakerVoiceprintMatcher.match(candidates: candidates, profiles: people)
            for candidate in candidates {
                guard let centroid = candidate.centroid else { continue }
                let scores = people.compactMap { SpeakerVoiceprintMatcher.profileScore(centroid: centroid, voiceprints: $0.voiceprints) }.sorted(by: >)
                let best = scores.first ?? 0, second = scores.dropFirst().first ?? 0
                print("[match] window \(name) \(candidate.label): best=\(String(format: "%.2f", best)) runnerUp=\(String(format: "%.2f", second)) margin=\(String(format: "%.2f", best - second)) -> \(assigned[candidate.label].map { "person \($0)" } ?? "Speaker N (no match)")")
            }
            #expect(Set(assigned.values).count == assigned.count, "two speakers must never share a person")
        }
    }
}
