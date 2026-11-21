import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import os
import Testing
@testable import MuesliNativeApp

@Suite("Live voiceprint matcher")
struct LiveVoiceprintMatcherTests {
    private func unitVector(primaryIndex: Int, secondaryIndex: Int? = nil, secondaryMix: Float = 0, dimension: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[primaryIndex] = 1
        if let secondaryIndex {
            vector[secondaryIndex] = secondaryMix
        }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    private func makeMeetingStart() -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    // MARK: - LiveMeetingSpeakerStore autoAssignCluster & reconciliation

    @Test("autoAssignCluster labels unnamed Speaker 1 and hides auto-match from manual reconciliation")
    func autoAssignLabelsClusterWithoutLockingReconciliation() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 6,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "First part"
        )
        _ = store.appendTurn(
            source: "Others", startSeconds: 7, endSeconds: 12,
            timestampLabel: "10:00:07", liveClusterID: "Speaker 1", text: "Second part"
        )

        #expect(store.unnamedLiveClustersEligibleForVoiceprint(minimumSeconds: 10).map(\.clusterID) == ["Speaker 1"])

        let applied = store.autoAssignCluster("Speaker 1", profileID: 42, name: "Alice")
        #expect(applied == true)
        #expect(store.resolvedSpeakerName(for: store.turns[0]) == "Alice")
        #expect(store.resolvedSpeakerName(for: store.turns[1]) == "Alice")

        let entry = try #require(store.entries.first(where: { $0.profileID == 42 }))
        #expect(entry.isAutoMatched == true)
        #expect(entry.source == .savedProfile)
        #expect(!entry.isGenericCluster)

        // Already auto-matched clusters are no longer eligible.
        #expect(store.unnamedLiveClustersEligibleForVoiceprint(minimumSeconds: 10).isEmpty)

        // Auto-matched assignments do not become manual overrides in reconciliationSnapshot().
        let snapshot = store.reconciliationSnapshot()
        #expect(snapshot.clusterAssignments.isEmpty)
        #expect(!snapshot.hasExplicitEdits)

        // Post-call diarization remains free to refine/keep the name via voiceprint matching.
        let postCall = [
            TimedSpeakerSegment(speakerId: "raw1", embedding: unitVector(primaryIndex: 0), startTimeSeconds: 0, endTimeSeconds: 12, qualityScore: 1),
        ]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCall,
            liveInput: snapshot,
            minimumVoiceprintSeconds: 1
        )
        #expect(reconciled.observations.first?.assignedName == nil)
        #expect(reconciled.observations.first?.assignedProfileID == nil)
    }

    @Test("autoAssignCluster refuses to overwrite manual assignment or reuse an active profileID")
    func autoAssignRespectsManualAssignmentsAndActiveProfiles() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 12,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Hello"
        )
        _ = store.appendTurn(
            source: "Others", startSeconds: 13, endSeconds: 25,
            timestampLabel: "10:00:13", liveClusterID: "Speaker 2", text: "World"
        )

        _ = try store.assignCluster("Speaker 1", to: .savedProfile(id: 42, name: "Alice"))
        #expect(store.autoAssignCluster("Speaker 1", profileID: 99, name: "Bob") == false)
        #expect(store.resolvedSpeakerName(for: store.turns[0]) == "Alice")

        // Never auto-merge Speaker 2 onto Alice (profileID 42) while Alice is already active.
        #expect(store.autoAssignCluster("Speaker 2", profileID: 42, name: "Alice") == false)
        #expect(store.resolvedSpeakerName(for: store.turns[1]) == "Speaker 2")
    }

    @Test("manual assignCluster, renameEntry, and reassignTurn flip isAutoMatched to false and survive reconciliation")
    func manualOverridesLockOutAutoMatch() throws {
        var store = LiveMeetingSpeakerStore()
        let appendedT1 = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 6,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "One"
        )
        let t1 = try #require(appendedT1)
        _ = store.appendTurn(
            source: "Others", startSeconds: 7, endSeconds: 13,
            timestampLabel: "10:00:07", liveClusterID: "Speaker 1", text: "Two"
        )
        _ = store.appendTurn(
            source: "Others", startSeconds: 14, endSeconds: 26,
            timestampLabel: "10:00:14", liveClusterID: "Speaker 2", text: "Three"
        )

        #expect(store.autoAssignCluster("Speaker 1", profileID: 42, name: "Alice") == true)
        #expect(store.autoAssignCluster("Speaker 2", profileID: 55, name: "Dana") == true)

        // 1. assignCluster confirms/changes Speaker 1 -> flips isAutoMatched to false.
        let confirmed = try store.assignCluster("Speaker 1", to: .savedProfile(id: 42, name: "Alice"))
        #expect(confirmed.isAutoMatched == false)
        #expect(store.autoAssignCluster("Speaker 1", profileID: 99, name: "Other") == false)

        // 2. renameEntry on auto-matched Speaker 2 -> flips isAutoMatched to false and drops stale profileID.
        let danaEntry = try #require(store.entries.first(where: { $0.clusterIDs.contains("Speaker 2") }))
        let renamed = try store.renameEntry(danaEntry.id, to: "Bob")
        #expect(renamed.isAutoMatched == false)
        #expect(renamed.displayName == "Bob")
        #expect(renamed.profileID == nil)
        #expect(store.autoAssignCluster("Speaker 2", profileID: 55, name: "Dana") == false)

        // 3. reassignTurn overrides t1 to Charlie cleanly.
        let charlie = try store.reassignTurn(t1.id, to: .newName("Charlie"))
        #expect(charlie.isAutoMatched == false)

        let snapshot = store.reconciliationSnapshot()
        #expect(snapshot.clusterAssignments.count == 2)
        #expect(snapshot.clusterAssignments.map(\.displayName).sorted() == ["Alice", "Bob"])
        #expect(snapshot.turnOverrides.count == 1)
        #expect(snapshot.turnOverrides.first?.displayName == "Charlie")

        let postCall = [
            TimedSpeakerSegment(speakerId: "s1", embedding: unitVector(primaryIndex: 0), startTimeSeconds: 0, endTimeSeconds: 13, qualityScore: 1),
            TimedSpeakerSegment(speakerId: "s2", embedding: unitVector(primaryIndex: 1), startTimeSeconds: 14, endTimeSeconds: 26, qualityScore: 1),
        ]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCall,
            liveInput: snapshot,
            minimumVoiceprintSeconds: 1
        )
        #expect(reconciled.observations.map(\.assignedName) == ["Alice", "Bob"])
        let names = reconciled.formattingSpeakerNames(resolvedFromStore: ["Speaker 1": "Alice", "Speaker 2": "Bob"])
        let merged = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: [
                SpeechSegment(start: 0, end: 6, text: "One"),
                SpeechSegment(start: 7, end: 13, text: "Two"),
                SpeechSegment(start: 14, end: 26, text: "Three"),
            ],
            diarizationSegments: reconciled.formattingDiarizationSegments,
            meetingStart: makeMeetingStart(),
            speakerNames: names
        )
        #expect(merged == """
        [10:00:00] Charlie: One
        [10:00:07] Alice: Two
        [10:00:14] Bob: Three
        """)
    }

    @Test("unnamedLiveClustersEligibleForVoiceprint ignores Others, You, short clusters, and overridden turns")
    func eligibleClustersFiltering() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "You", startSeconds: 0, endSeconds: 20, timestampLabel: "10:00:00", liveClusterID: nil, text: "Self")
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 15, timestampLabel: "10:00:00", liveClusterID: nil, text: "Undiarized")
        let appendedTurn1 = store.appendTurn(
            source: "Others", startSeconds: 20, endSeconds: 26,
            timestampLabel: "10:00:20", liveClusterID: "Speaker 1", text: "Six seconds"
        )
        let s1Turn1 = try #require(appendedTurn1)
        _ = store.appendTurn(
            source: "Others", startSeconds: 27, endSeconds: 33,
            timestampLabel: "10:00:27", liveClusterID: "Speaker 1", text: "Six more"
        )
        _ = store.appendTurn(
            source: "Others", startSeconds: 34, endSeconds: 40,
            timestampLabel: "10:00:34", liveClusterID: "Speaker 2", text: "Too short"
        )

        #expect(store.unnamedLiveClustersEligibleForVoiceprint(minimumSeconds: 10).map(\.clusterID) == ["Speaker 1"])

        // Overriding s1Turn1 drops Speaker 1 below 10s of remaining un-overridden speech.
        _ = try store.reassignTurn(s1Turn1.id, to: .newName("Bob"))
        #expect(store.unnamedLiveClustersEligibleForVoiceprint(minimumSeconds: 10).isEmpty)
    }

    // MARK: - LiveVoiceprintCoordinator

    private final class MockExtractor: LiveVoiceprintEmbeddingExtractor, @unchecked Sendable {
        private let handler: @Sendable ([Float]) -> LiveVoiceprintExtractionOutcome
        private let callCountLock = OSAllocatedUnfairLock(initialState: 0)

        init(_ handler: @escaping @Sendable ([Float]) -> LiveVoiceprintExtractionOutcome) {
            self.handler = handler
        }

        var callCount: Int { callCountLock.withLock { $0 } }

        func extractCentroid(from samples: [Float]) async -> LiveVoiceprintExtractionOutcome {
            callCountLock.withLock { $0 += 1 }
            return handler(samples)
        }
    }

    @Test("coordinator skips clusters under 10s and matches cleanly at >= 10s")
    func coordinatorThresholdAndConfidentMatch() async {
        let aliceVector = unitVector(primaryIndex: 0)
        let bobVector = unitVector(primaryIndex: 1)
        let profiles = [
            LiveVoiceprintProfile(id: 1, name: "Alice", voiceprints: [aliceVector]),
            LiveVoiceprintProfile(id: 2, name: "Bob", voiceprints: [bobVector]),
        ]

        let extractor = MockExtractor { _ in .centroid(aliceVector) }
        let coordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            sliceAudio: { _ in [Float](repeating: 0.2, count: 16_000) }
        )

        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 9.5, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Short")
        let underThreshold = await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false)
        #expect(underThreshold.isEmpty)
        #expect(extractor.callCount == 0)

        _ = store.appendTurn(source: "Others", startSeconds: 9.5, endSeconds: 11.0, timestampLabel: "10:00:09", liveClusterID: "Speaker 1", text: "Enough")
        let matched = await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false)
        #expect(matched == [LiveVoiceprintMatch(clusterID: "Speaker 1", profileID: 1, name: "Alice")])
        #expect(extractor.callCount == 1)
    }

    @Test("coordinator skips ambiguous matches, retries once at >= 25s, and stops after max attempts")
    func coordinatorAmbiguousRetryAndMaxAttempts() async {
        let aliceVector = unitVector(primaryIndex: 0)
        let almostAlice = unitVector(primaryIndex: 0, secondaryIndex: 1, secondaryMix: 0.2)
        // Centroid sits halfway between aliceVector and almostAlice (margin < 0.10).
        let ambiguousCentroid = unitVector(primaryIndex: 0, secondaryIndex: 1, secondaryMix: 0.1)
        let profiles = [
            LiveVoiceprintProfile(id: 1, name: "Alice", voiceprints: [aliceVector]),
            LiveVoiceprintProfile(id: 2, name: "Alicia", voiceprints: [almostAlice]),
        ]

        let outcomeLock = OSAllocatedUnfairLock<LiveVoiceprintExtractionOutcome>(initialState: .centroid(ambiguousCentroid))
        let extractor = MockExtractor { _ in outcomeLock.withLock { $0 } }
        let coordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            sliceAudio: { _ in [Float](repeating: 0.1, count: 16_000) }
        )

        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 12, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "12s")

        // Attempt 1 at 12s -> ambiguous, no match.
        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false).isEmpty)
        #expect(extractor.callCount == 1)
        #expect(await coordinator.attemptCount(for: "Speaker 1") == 1)

        // At 20s (< 25s) -> throttled, does not re-run.
        _ = store.appendTurn(source: "Others", startSeconds: 12, endSeconds: 20, timestampLabel: "10:00:12", liveClusterID: "Speaker 1", text: "20s")
        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false).isEmpty)
        #expect(extractor.callCount == 1)

        // At 26s (>= 25s) -> retry attempt 2 runs (still unmatched -> stops permanently).
        _ = store.appendTurn(source: "Others", startSeconds: 20, endSeconds: 26, timestampLabel: "10:00:20", liveClusterID: "Speaker 1", text: "26s")
        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false).isEmpty)
        #expect(extractor.callCount == 2)
        #expect(await coordinator.attemptCount(for: "Speaker 1") == 2)

        // Even at 40s with a clear centroid, max 2 attempts prevents further CPU work.
        outcomeLock.withLock { $0 = .centroid(aliceVector) }
        _ = store.appendTurn(source: "Others", startSeconds: 26, endSeconds: 40, timestampLabel: "10:00:26", liveClusterID: "Speaker 1", text: "40s")
        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false).isEmpty)
        #expect(extractor.callCount == 2)
    }

    @Test("coordinator skips private meetings and excludes already-assigned profiles")
    func coordinatorSkipsPrivateAndAlreadyAssignedProfiles() async throws {
        let aliceVector = unitVector(primaryIndex: 0)
        let bobVector = unitVector(primaryIndex: 1)
        let profiles = [
            LiveVoiceprintProfile(id: 1, name: "Alice", voiceprints: [aliceVector]),
            LiveVoiceprintProfile(id: 2, name: "Bob", voiceprints: [bobVector]),
        ]

        let extractor = MockExtractor { _ in .centroid(aliceVector) }
        let coordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            sliceAudio: { _ in [Float](repeating: 0.1, count: 16_000) }
        )

        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 12, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "First")
        _ = store.appendTurn(source: "Others", startSeconds: 13, endSeconds: 25, timestampLabel: "10:00:13", liveClusterID: "Speaker 2", text: "Second")

        // Private meeting never extracts or matches.
        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: true).isEmpty)
        #expect(extractor.callCount == 0)

        // Assign Alice (profile 1) to Speaker 1; Speaker 2's centroid matches Alice but must be excluded.
        _ = try store.assignCluster("Speaker 1", to: .savedProfile(id: 1, name: "Alice"))
        let matches = await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false)
        #expect(matches.isEmpty)
        #expect(extractor.callCount == 1)
    }

    @Test("coordinator does not consume attempts when diarizer extractor is unavailable")
    func coordinatorPreservesAttemptsWhenUnavailable() async {
        let aliceVector = unitVector(primaryIndex: 0)
        let profiles = [LiveVoiceprintProfile(id: 1, name: "Alice", voiceprints: [aliceVector])]
        let outcomeLock = OSAllocatedUnfairLock<LiveVoiceprintExtractionOutcome>(initialState: .unavailable)
        let extractor = MockExtractor { _ in outcomeLock.withLock { $0 } }
        let coordinator = LiveVoiceprintCoordinator(
            extractor: extractor,
            sliceAudio: { _ in [Float](repeating: 0.1, count: 16_000) }
        )

        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 12, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Speech")

        #expect(await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false).isEmpty)
        #expect(await coordinator.attemptCount(for: "Speaker 1") == 0)

        outcomeLock.withLock { $0 = .centroid(aliceVector) }
        let matches = await coordinator.evaluate(store: store, profiles: profiles, isPrivate: false)
        #expect(matches == [LiveVoiceprintMatch(clusterID: "Speaker 1", profileID: 1, name: "Alice")])
        #expect(await coordinator.attemptCount(for: "Speaker 1") == 1)
    }

    // MARK: - LiveVoiceprintAudioBuffer & slicing

    @Test("LiveVoiceprintAudioBuffer slices intervals accurately, caps clip duration, and bounds retained memory")
    func audioBufferSlicingAndBoundedRetention() throws {
        // 100 Hz sample rate for fast exact assertions, 30s retention -> 3000 samples max.
        let buffer = LiveVoiceprintAudioBuffer(sampleRate: 100, maxRetentionSeconds: 30)
        #expect(buffer.capacitySamples == 3_000)

        // Append 50 seconds (5000 samples) in chunks; each sample equals its sample index.
        for chunkStart in stride(from: 0, to: 5_000, by: 400) {
            let chunkEnd = min(chunkStart + 400, 5_000)
            let chunk = (chunkStart..<chunkEnd).map { Float($0) }
            buffer.append(chunk)
        }
        #expect(buffer.totalSamplesAppended == 5_000)
        #expect(buffer.retainedSampleCount == 3_000)
        #expect(buffer.earliestRetainedSeconds == 20.0)
        #expect(buffer.coveredThroughSeconds == 50.0)

        // Interval [0, 10] aged out; [21, 23] and [30, 35] are retained; overlapping [32, 36] deduplicates.
        let slice = try #require(buffer.slice(intervals: [
            LiveSpeakerInterval(start: 0, end: 10),
            LiveSpeakerInterval(start: 21, end: 23),
            LiveSpeakerInterval(start: 30, end: 35),
            LiveSpeakerInterval(start: 32, end: 36),
        ], maxDurationSeconds: 20))
        // 2s (200) + 6s (600) = 800 samples.
        #expect(slice.count == 800)
        #expect(slice.prefix(3) == [2100, 2101, 2102])
        #expect(slice[199] == 2299)
        #expect(slice[200] == 3000)
        #expect(slice.last == 3599)

        // Capped at maxDurationSeconds = 5 -> 500 samples.
        let capped = try #require(buffer.slice(intervals: [
            LiveSpeakerInterval(start: 25, end: 45),
        ], maxDurationSeconds: 5))
        #expect(capped.count == 500)
        #expect(capped.first == 2500)
        #expect(capped.last == 2999)
    }

    @Test("LiveVoiceprintWAVSliceReader slices intervals from WAV file capped to max duration")
    func wavSliceReaderExtraction() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-voiceprint-slice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let totalFrames: AVAudioFrameCount = 16_000 * 6 // 6 seconds
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames))
        pcm.frameLength = totalFrames
        let channel = try #require(pcm.floatChannelData?[0])
        for index in 0..<Int(totalFrames) {
            channel[index] = sin(Float(index) * 0.01) * 0.5
        }
        do {
            let writer = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try writer.write(from: pcm)
        }

        let rawSliced = try LiveVoiceprintWAVSliceReader.slice(
            url: tempURL,
            intervals: [
                LiveSpeakerInterval(start: 1.0, end: 2.5),
                LiveSpeakerInterval(start: 4.0, end: 6.0),
            ],
            maxDurationSeconds: 2.0
        )
        let sliced = try #require(rawSliced)
        #expect(sliced.count == 32_000)
        #expect(abs(sliced[0] - channel[16_000]) < 0.001)
    }

    @Test("FluidAudioLiveVoiceprintExtractor.dominantCentroid picks dominant speaker via SpeakerCentroidBuilder")
    func dominantCentroidSelection() {
        let aliceEmb = unitVector(primaryIndex: 0, dimension: 256)
        let bleedEmb = unitVector(primaryIndex: 1, dimension: 256)
        let segments = [
            TimedSpeakerSegment(speakerId: "S1", embedding: aliceEmb, startTimeSeconds: 0, endTimeSeconds: 6, qualityScore: 1),
            TimedSpeakerSegment(speakerId: "S2", embedding: bleedEmb, startTimeSeconds: 6, endTimeSeconds: 7.5, qualityScore: 1),
            TimedSpeakerSegment(speakerId: "S1", embedding: aliceEmb, startTimeSeconds: 7.5, endTimeSeconds: 12, qualityScore: 1),
        ]
        let centroid = FluidAudioLiveVoiceprintExtractor.dominantCentroid(from: segments)
        #expect(centroid != nil)
        if let centroid {
            let similarity = SpeakerVoiceprintMatcher.cosineSimilarity(centroid, aliceEmb) ?? 0
            #expect(similarity > 0.999)
        }
    }
}
