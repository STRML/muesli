import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import os

/// Saved speaker profile metadata and voiceprints used for live call recognition.
struct LiveVoiceprintProfile: Sendable, Equatable {
    let id: Int64
    let name: String
    let voiceprints: [[Float]]
}

/// Confident voiceprint match for a provisional live diarizer cluster.
struct LiveVoiceprintMatch: Sendable, Equatable {
    let clusterID: String
    let profileID: Int64
    let name: String
}

/// Outcome of running embedding extraction on a cluster's speech slice.
enum LiveVoiceprintExtractionOutcome: Sendable, Equatable {
    case centroid([Float])
    case noUsableSpeech
    case unavailable
}

/// Extracts a speaker centroid embedding from 16 kHz mono Float32 samples.
protocol LiveVoiceprintEmbeddingExtractor: Sendable {
    func extractCentroid(from samples: [Float]) async -> LiveVoiceprintExtractionOutcome
}

/// Bounded, lock-guarded 16 kHz mono Float32 ring buffer aligned with a monotonic sample clock.
///
/// Samples are appended synchronously on the meeting audio queue without allocation churn once
/// warmed up, and committed `(start, end)` intervals are sliced on demand for live voiceprint
/// extraction in bounded memory (~11.5 MB at 180s).
final class LiveVoiceprintAudioBuffer: @unchecked Sendable {
    static let defaultSampleRate = 16_000
    static let defaultMaxRetentionSeconds: TimeInterval = 180
    static let defaultMaxClipSeconds: TimeInterval = 20

    let sampleRate: Int
    let capacitySamples: Int

    private struct State {
        var ring: [Float] = []
        var writeIndex = 0
        var totalAppendedSamples: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        sampleRate: Int = LiveVoiceprintAudioBuffer.defaultSampleRate,
        maxRetentionSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxRetentionSeconds
    ) {
        let safeRate = max(sampleRate, 1)
        self.sampleRate = safeRate
        let clampedRetention = max(maxRetentionSeconds, 1)
        self.capacitySamples = max(1, Int((clampedRetention * Double(safeRate)).rounded()))
    }

    var retainedSampleCount: Int {
        state.withLock { $0.ring.count }
    }

    var totalSamplesAppended: Int64 {
        state.withLock { $0.totalAppendedSamples }
    }

    var earliestRetainedSeconds: TimeInterval {
        state.withLock { s in
            let earliest = s.totalAppendedSamples - Int64(s.ring.count)
            return Double(earliest) / Double(sampleRate)
        }
    }

    var coveredThroughSeconds: TimeInterval {
        state.withLock { Double($0.totalAppendedSamples) / Double(sampleRate) }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        state.withLock { s in
            s.totalAppendedSamples += Int64(samples.count)
            if samples.count >= capacitySamples {
                s.ring = Array(samples.suffix(capacitySamples))
                s.writeIndex = 0
                return
            }

            if s.ring.count < capacitySamples {
                let room = capacitySamples - s.ring.count
                let directCount = min(room, samples.count)
                s.ring.append(contentsOf: samples.prefix(directCount))
                if s.ring.count == capacitySamples {
                    s.writeIndex = 0
                }
                let overflow = samples.count - directCount
                if overflow > 0 {
                    s.ring.replaceSubrange(0..<overflow, with: samples.suffix(overflow))
                    s.writeIndex = overflow
                }
                return
            }

            let firstPart = min(samples.count, capacitySamples - s.writeIndex)
            s.ring.replaceSubrange(s.writeIndex..<(s.writeIndex + firstPart), with: samples.prefix(firstPart))
            let secondPart = samples.count - firstPart
            if secondPart > 0 {
                s.ring.replaceSubrange(0..<secondPart, with: samples.suffix(secondPart))
                s.writeIndex = secondPart
            } else {
                s.writeIndex = (s.writeIndex + firstPart) % capacitySamples
            }
        }
    }

    /// Concatenates audio samples covering `intervals` that are still retained in the ring buffer,
    /// deduplicating overlapping ranges and capping output to `maxDurationSeconds`.
    func slice(
        intervals: [LiveSpeakerInterval],
        maxDurationSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxClipSeconds
    ) -> [Float]? {
        let maxSamples = Int((max(0, maxDurationSeconds) * Double(sampleRate)).rounded())
        guard maxSamples > 0, !intervals.isEmpty else { return nil }

        return state.withLock { s -> [Float]? in
            let retainedCount = Int64(s.ring.count)
            guard retainedCount > 0 else { return nil }
            let earliestSample = s.totalAppendedSamples - retainedCount
            let latestSample = s.totalAppendedSamples
            let ringStart = s.ring.count == capacitySamples ? s.writeIndex : 0

            let mergedRanges = Self.mergedSampleRanges(
                intervals: intervals,
                sampleRate: sampleRate,
                earliestSample: earliestSample,
                latestSample: latestSample
            )
            guard !mergedRanges.isEmpty else { return nil }

            let totalAvailable = mergedRanges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) }
            var output: [Float] = []
            output.reserveCapacity(min(maxSamples, totalAvailable))

            for range in mergedRanges {
                let remaining = maxSamples - output.count
                guard remaining > 0 else { break }
                let count = min(remaining, Int(range.upperBound - range.lowerBound))
                guard count > 0 else { continue }
                let offsetFromEarliest = Int(range.lowerBound - earliestSample)
                let physicalStart = (ringStart + offsetFromEarliest) % s.ring.count
                let firstChunk = min(count, s.ring.count - physicalStart)
                output.append(contentsOf: s.ring[physicalStart..<(physicalStart + firstChunk)])
                let secondChunk = count - firstChunk
                if secondChunk > 0 {
                    output.append(contentsOf: s.ring[0..<secondChunk])
                }
            }

            return output.isEmpty ? nil : output
        }
    }

    func reset() {
        state.withLock { s in
            s.ring.removeAll(keepingCapacity: false)
            s.writeIndex = 0
            s.totalAppendedSamples = 0
        }
    }

    fileprivate static func mergedSampleRanges(
        intervals: [LiveSpeakerInterval],
        sampleRate: Int,
        earliestSample: Int64,
        latestSample: Int64
    ) -> [Range<Int64>] {
        let clamped: [Range<Int64>] = intervals.compactMap { interval in
            guard interval.start.isFinite, interval.end.isFinite, interval.end > interval.start else { return nil }
            let startSample = max(earliestSample, Int64((interval.start * Double(sampleRate)).rounded(.down)))
            let endSample = min(latestSample, Int64((interval.end * Double(sampleRate)).rounded(.up)))
            guard endSample > startSample else { return nil }
            return startSample..<endSample
        }.sorted { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound { return lhs.upperBound < rhs.upperBound }
            return lhs.lowerBound < rhs.lowerBound
        }

        var merged: [Range<Int64>] = []
        for range in clamped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Disk-backed alternative slice reader that reads only requested `(start, end)` intervals from
/// a recording WAV file, resampled to 16 kHz mono Float32 and capped at `maxDurationSeconds`.
enum LiveVoiceprintWAVSliceReader {
    static func slice(
        url: URL,
        intervals: [LiveSpeakerInterval],
        maxDurationSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxClipSeconds
    ) throws -> [Float]? {
        let targetRate = LiveVoiceprintAudioBuffer.defaultSampleRate
        let maxTargetSamples = Int((max(0, maxDurationSeconds) * Double(targetRate)).rounded())
        guard maxTargetSamples > 0, !intervals.isEmpty else { return nil }

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        guard sourceRate.isFinite, sourceRate > 0, file.length > 0 else { return nil }

        let mergedSourceRanges = LiveVoiceprintAudioBuffer.mergedSampleRanges(
            intervals: intervals,
            sampleRate: Int(sourceRate.rounded()),
            earliestSample: 0,
            latestSample: file.length
        )
        guard !mergedSourceRanges.isEmpty else { return nil }

        let converter = AudioConverter()
        let scratchCapacity: AVAudioFrameCount = 8192
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: scratchCapacity) else {
            throw CocoaError(.fileReadTooLarge)
        }

        var output: [Float] = []
        for range in mergedSourceRanges {
            try Task.checkCancellation()
            let remainingTarget = maxTargetSamples - output.count
            guard remainingTarget > 0 else { break }

            let maxSourceFramesForRemaining = Int64(((Double(remainingTarget) / Double(targetRate)) * sourceRate).rounded(.up))
            let framesToRead = min(range.upperBound - range.lowerBound, max(1, maxSourceFramesForRemaining))
            guard framesToRead > 0 else { continue }

            file.framePosition = range.lowerBound
            var remainingSource = framesToRead
            while remainingSource > 0 && output.count < maxTargetSamples {
                try Task.checkCancellation()
                let chunkCount = AVAudioFrameCount(min(Int64(scratchCapacity), remainingSource))
                scratch.frameLength = 0
                try file.read(into: scratch, frameCount: chunkCount)
                guard scratch.frameLength > 0 else { break }
                let resampled = try converter.resampleBuffer(scratch)
                let needed = maxTargetSamples - output.count
                if resampled.count <= needed {
                    output.append(contentsOf: resampled)
                } else {
                    output.append(contentsOf: resampled.prefix(needed))
                }
                remainingSource -= Int64(scratch.frameLength)
            }
        }

        return output.isEmpty ? nil : output
    }
}

/// FluidAudio-backed centroid extractor reusing `DiarizerManager` on isolated short clips.
struct FluidAudioLiveVoiceprintExtractor: LiveVoiceprintEmbeddingExtractor {
    static let sampleRate = LiveVoiceprintAudioBuffer.defaultSampleRate
    static let minimumSpeechSeconds: Double = 4.0

    private let runDiarization: @Sendable ([Float]) async throws -> [TimedSpeakerSegment]?

    /// `runDiarization` must serialize access to the shared `DiarizerManager` (for example inside
    /// `TranscriptionCoordinator`) and isolate `speakerManager` per invocation.
    init(runDiarization: @escaping @Sendable ([Float]) async throws -> [TimedSpeakerSegment]?) {
        self.runDiarization = runDiarization
    }

    func extractCentroid(from samples: [Float]) async -> LiveVoiceprintExtractionOutcome {
        guard samples.count >= Self.sampleRate else { return .noUsableSpeech }
        do {
            guard let segments = try await runDiarization(samples) else {
                return .unavailable
            }
            guard let centroid = Self.dominantCentroid(from: segments) else {
                return .noUsableSpeech
            }
            return .centroid(centroid)
        } catch is CancellationError {
            return .unavailable
        } catch {
            return .noUsableSpeech
        }
    }

    /// Rebuilds the L2-normalized centroid for the dominant speaker in `segments` using
    /// `SpeakerCentroidBuilder`.
    static func dominantCentroid(from segments: [TimedSpeakerSegment]) -> [Float]? {
        guard !segments.isEmpty else { return nil }
        let observations = SpeakerCentroidBuilder.observations(
            from: segments,
            minimumSeconds: minimumSpeechSeconds
        )
        return observations
            .filter { $0.centroid != nil }
            .max(by: { $0.speechSeconds < $1.speechSeconds })?
            .centroid
    }

    /// Runs `DiarizerManager.performCompleteDiarization` on a single cluster's audio clip without
    /// mutating the shared `speakerManager` state used by other jobs.
    static func diarizeClip(_ samples: [Float], using manager: DiarizerManager) throws -> [TimedSpeakerSegment] {
        guard manager.isAvailable else { throw DiarizerError.notInitialized }
        try Task.checkCancellation()
        return try autoreleasepool {
            let previous = manager.speakerManager
            manager.speakerManager = SpeakerManager(
                speakerThreshold: previous.speakerThreshold,
                embeddingThreshold: previous.embeddingThreshold,
                minSpeechDuration: previous.minSpeechDuration,
                minEmbeddingUpdateDuration: previous.minEmbeddingUpdateDuration
            )
            defer { manager.speakerManager = previous }
            return try manager.performCompleteDiarization(samples, sampleRate: sampleRate).segments
        }
    }
}

/// Evaluates eligible unnamed live speaker clusters against saved voiceprints with bounded retries.
actor LiveVoiceprintCoordinator {
    static let defaultMinimumFirstAttemptSeconds: Double = 10
    static let defaultMinimumRetrySeconds: Double = 25
    static let defaultMaxAttemptsPerCluster = 2

    private struct ClusterAttemptState {
        var attemptCount = 0
        var matched = false
    }

    private let extractor: any LiveVoiceprintEmbeddingExtractor
    private let sliceAudio: @Sendable ([LiveSpeakerInterval]) async -> [Float]?
    private let minimumFirstAttemptSeconds: Double
    private let minimumRetrySeconds: Double
    private let maxAttemptsPerCluster: Int

    private var attemptsByCluster: [String: ClusterAttemptState] = [:]
    private var inFlightClusters: Set<String> = []

    init(
        extractor: any LiveVoiceprintEmbeddingExtractor,
        sliceAudio: @escaping @Sendable ([LiveSpeakerInterval]) async -> [Float]?,
        minimumFirstAttemptSeconds: Double = LiveVoiceprintCoordinator.defaultMinimumFirstAttemptSeconds,
        minimumRetrySeconds: Double = LiveVoiceprintCoordinator.defaultMinimumRetrySeconds,
        maxAttemptsPerCluster: Int = LiveVoiceprintCoordinator.defaultMaxAttemptsPerCluster
    ) {
        self.extractor = extractor
        self.sliceAudio = sliceAudio
        self.minimumFirstAttemptSeconds = max(0, minimumFirstAttemptSeconds)
        self.minimumRetrySeconds = max(minimumFirstAttemptSeconds, minimumRetrySeconds)
        self.maxAttemptsPerCluster = max(1, maxAttemptsPerCluster)
    }

    init(
        extractor: any LiveVoiceprintEmbeddingExtractor,
        audioBuffer: LiveVoiceprintAudioBuffer,
        maxClipSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxClipSeconds,
        minimumFirstAttemptSeconds: Double = LiveVoiceprintCoordinator.defaultMinimumFirstAttemptSeconds,
        minimumRetrySeconds: Double = LiveVoiceprintCoordinator.defaultMinimumRetrySeconds,
        maxAttemptsPerCluster: Int = LiveVoiceprintCoordinator.defaultMaxAttemptsPerCluster
    ) {
        self.init(
            extractor: extractor,
            sliceAudio: { intervals in
                audioBuffer.slice(intervals: intervals, maxDurationSeconds: maxClipSeconds)
            },
            minimumFirstAttemptSeconds: minimumFirstAttemptSeconds,
            minimumRetrySeconds: minimumRetrySeconds,
            maxAttemptsPerCluster: maxAttemptsPerCluster
        )
    }

    func attemptCount(for clusterID: String) -> Int {
        attemptsByCluster[clusterID]?.attemptCount ?? 0
    }

    func reset() {
        attemptsByCluster.removeAll()
        inFlightClusters.removeAll()
    }

    /// Inspects `store` for unnamed live clusters that crossed the speech threshold, extracts their
    /// centroids off the main actor, and returns confident matches against `profiles`.
    func evaluate(
        store: LiveMeetingSpeakerStore,
        profiles: [LiveVoiceprintProfile],
        isPrivate: Bool,
        excludedProfileIDs: Set<Int64> = []
    ) async -> [LiveVoiceprintMatch] {
        guard !isPrivate, !profiles.isEmpty else { return [] }

        let candidates = store.unnamedLiveClustersEligibleForVoiceprint(
            minimumSeconds: minimumFirstAttemptSeconds
        )
        guard !candidates.isEmpty else { return [] }

        var unavailableProfileIDs = excludedProfileIDs.union(Self.activeAssignedProfileIDs(in: store))
        var matches: [LiveVoiceprintMatch] = []

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let clusterID = candidate.clusterID
            guard !inFlightClusters.contains(clusterID) else { continue }

            let currentState = attemptsByCluster[clusterID] ?? ClusterAttemptState()
            guard !currentState.matched, currentState.attemptCount < maxAttemptsPerCluster else {
                continue
            }

            let requiredSeconds = currentState.attemptCount == 0
                ? minimumFirstAttemptSeconds
                : minimumRetrySeconds
            guard candidate.totalSeconds >= requiredSeconds else { continue }

            inFlightClusters.insert(clusterID)
            defer { inFlightClusters.remove(clusterID) }

            guard let samples = await sliceAudio(candidate.intervals), !samples.isEmpty else {
                continue
            }
            guard !Task.isCancelled else { break }

            let outcome = await extractor.extractCentroid(from: samples)
            guard !Task.isCancelled else { break }

            var updatedState = attemptsByCluster[clusterID] ?? currentState
            switch outcome {
            case .unavailable:
                continue
            case .noUsableSpeech:
                updatedState.attemptCount += 1
                attemptsByCluster[clusterID] = updatedState
            case .centroid(let centroid):
                updatedState.attemptCount += 1
                let availableProfiles = profiles.filter { !unavailableProfileIDs.contains($0.id) }
                guard !availableProfiles.isEmpty else {
                    attemptsByCluster[clusterID] = updatedState
                    continue
                }
                let matcherProfiles = availableProfiles.map {
                    SpeakerVoiceprintMatcher.Profile(id: $0.id, voiceprints: $0.voiceprints)
                }
                let matchedByLabel = SpeakerVoiceprintMatcher.match(
                    candidates: [SpeakerVoiceprintMatcher.Candidate(label: clusterID, centroid: centroid)],
                    profiles: matcherProfiles
                )
                if let matchedProfileID = matchedByLabel[clusterID],
                   let profile = availableProfiles.first(where: { $0.id == matchedProfileID }) {
                    updatedState.matched = true
                    attemptsByCluster[clusterID] = updatedState
                    unavailableProfileIDs.insert(matchedProfileID)
                    matches.append(LiveVoiceprintMatch(
                        clusterID: clusterID,
                        profileID: profile.id,
                        name: profile.name
                    ))
                } else {
                    attemptsByCluster[clusterID] = updatedState
                }
            }
        }

        return matches
    }

    private static func activeAssignedProfileIDs(in store: LiveMeetingSpeakerStore) -> Set<Int64> {
        let explicitEntryIDs = Set(store.turns.compactMap(\.explicitSpeakerID))
        var assigned = Set<Int64>()
        for entry in store.entries where !entry.isSelf && !entry.isGenericCluster {
            guard let profileID = entry.profileID else { continue }
            if !entry.clusterIDs.isEmpty || explicitEntryIDs.contains(entry.id) {
                assigned.insert(profileID)
            }
        }
        return assigned
    }
}

/// Convenience session pairing a bounded live PCM ring buffer with a `LiveVoiceprintCoordinator`.
final class LiveVoiceprintSession: @unchecked Sendable {
    let audioBuffer: LiveVoiceprintAudioBuffer
    let coordinator: LiveVoiceprintCoordinator

    init(
        extractor: any LiveVoiceprintEmbeddingExtractor,
        sampleRate: Int = LiveVoiceprintAudioBuffer.defaultSampleRate,
        maxRetentionSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxRetentionSeconds,
        maxClipSeconds: TimeInterval = LiveVoiceprintAudioBuffer.defaultMaxClipSeconds,
        minimumFirstAttemptSeconds: Double = LiveVoiceprintCoordinator.defaultMinimumFirstAttemptSeconds,
        minimumRetrySeconds: Double = LiveVoiceprintCoordinator.defaultMinimumRetrySeconds,
        maxAttemptsPerCluster: Int = LiveVoiceprintCoordinator.defaultMaxAttemptsPerCluster
    ) {
        let buffer = LiveVoiceprintAudioBuffer(
            sampleRate: sampleRate,
            maxRetentionSeconds: maxRetentionSeconds
        )
        self.audioBuffer = buffer
        self.coordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            audioBuffer: buffer,
            maxClipSeconds: maxClipSeconds,
            minimumFirstAttemptSeconds: minimumFirstAttemptSeconds,
            minimumRetrySeconds: minimumRetrySeconds,
            maxAttemptsPerCluster: maxAttemptsPerCluster
        )
    }

    func appendAudio(_ samples: [Float]) {
        audioBuffer.append(samples)
    }

    func evaluate(
        store: LiveMeetingSpeakerStore,
        profiles: [LiveVoiceprintProfile],
        isPrivate: Bool
    ) async -> [LiveVoiceprintMatch] {
        await coordinator.evaluate(store: store, profiles: profiles, isPrivate: isPrivate)
    }

    func reset() async {
        audioBuffer.reset()
        await coordinator.reset()
    }
}
