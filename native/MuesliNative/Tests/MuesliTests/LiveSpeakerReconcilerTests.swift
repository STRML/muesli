import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Live speaker reconciler")
struct LiveSpeakerReconcilerTests {
    private var meetingStart: Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    private func diarSeg(_ id: String, _ start: Float, _ end: Float, embedding: [Float] = [1, 0]) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: embedding, startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1)
    }

    @Test("maps live cluster names onto reordered post-call diarizer clusters by time overlap")
    func reorderedPostCallClusters() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 10, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Alice speaks")
        _ = store.appendTurn(source: "Others", startSeconds: 11, endSeconds: 20, timestampLabel: "10:00:11", liveClusterID: "Speaker 2", text: "Bob speaks")
        _ = try store.assignCluster("Speaker 1", to: .savedProfile(id: 10, name: "Alice"))

        // Post-call diarizer saw Bob at t=0.1? No, post-call numbered raw IDs in reverse order (rawB first -> Speaker 1).
        let postCall = [
            diarSeg("rawB", 11, 20, embedding: [0, 1]),
            diarSeg("rawA", 0, 10, embedding: [1, 0]),
        ]
        // In TranscriptFormatter.speakerLabels(for:), earliest startTimeSeconds (rawA at 0..10) is Speaker 1, rawB at 11..20 is Speaker 2.
        // Suppose post-call also found a tiny intro from rawB at 0..0.3, making rawB "Speaker 1" and rawA "Speaker 2"!
        let postCallSwapped = [
            diarSeg("rawB", 0, 0.2, embedding: [0, 1]),
            diarSeg("rawA", 0.3, 10, embedding: [1, 0]),
            diarSeg("rawB", 11, 20, embedding: [0, 1]),
        ]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCallSwapped,
            liveInput: store.reconciliationSnapshot(),
            minimumVoiceprintSeconds: 1
        )
        #expect(postCall.count == 2)
        // Speaker 1 is rawB (not Alice!), Speaker 2 is rawA (Alice!).
        #expect(reconciled.liveClusterNames == ["Speaker 2": "Alice"])
        #expect(reconciled.observations[0].assignedName == nil)
        #expect(reconciled.observations[1].assignedName == "Alice")
        #expect(reconciled.observations[1].assignedProfileID == 10)
    }

    @Test("merged live clusters and post-call over-segmentation both fold onto the target person")
    func mergedLiveClustersAndOverSegmentation() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 8, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Part one")
        _ = store.appendTurn(source: "Others", startSeconds: 10, endSeconds: 18, timestampLabel: "10:00:10", liveClusterID: "Speaker 3", text: "Part two")
        let alice = try store.assignCluster("Speaker 1", to: .newName("Alice"))
        _ = try store.assignCluster("Speaker 3", to: .existingEntry(id: alice.id))

        let postCall = [
            diarSeg("p1", 0, 8, embedding: [1, 0]),
            diarSeg("p2", 10, 18, embedding: [0.9, 0.1]),
        ]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCall,
            liveInput: store.reconciliationSnapshot(),
            minimumVoiceprintSeconds: 1
        )
        #expect(reconciled.observations.map(\.assignedName) == ["Alice", "Alice"])
        let names = reconciled.formattingSpeakerNames(resolvedFromStore: ["Speaker 1": "Alice", "Speaker 2": "Alice"])
        let merged = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: [
                SpeechSegment(start: 0, end: 8, text: "Part one"),
                SpeechSegment(start: 10, end: 18, text: "Part two"),
            ],
            diarizationSegments: reconciled.formattingDiarizationSegments,
            meetingStart: meetingStart,
            speakerNames: names
        )
        #expect(reconciled.liveClusterNames == ["Speaker 1": "Alice", "Speaker 2": "Alice"])
        #expect(merged == "[10:00:00] Alice: Part one Part two")
    }

    @Test("single-turn overrides carve out post-call diarization segments without losing cluster labels")
    func singleTurnOverridePreservedPostCall() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 4, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Hello")
        let rawSecond = store.appendTurn(source: "Others", startSeconds: 8, endSeconds: 12, timestampLabel: "10:00:08", liveClusterID: "Speaker 1", text: "Actually Charlie")
        let second = try #require(rawSecond)
        _ = store.appendTurn(source: "Others", startSeconds: 16, endSeconds: 20, timestampLabel: "10:00:16", liveClusterID: "Speaker 1", text: "Back to Alice")
        _ = try store.assignCluster("Speaker 1", to: .newName("Alice"))
        _ = try store.reassignTurn(second.id, to: .newName("Charlie"))

        // Single speaker in post-call diarization covering 0..20.
        let postCall = [diarSeg("raw1", 0, 20, embedding: [1, 0])]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCall,
            liveInput: store.reconciliationSnapshot(),
            minimumVoiceprintSeconds: 1
        )
        #expect(reconciled.observations.count == 1)
        #expect(reconciled.observations[0].assignedName == "Alice")

        let names = reconciled.formattingSpeakerNames(resolvedFromStore: ["Speaker 1": "Alice"])
        let transcript = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: [
                SpeechSegment(start: 0, end: 4, text: "Hello"),
                SpeechSegment(start: 8, end: 12, text: "Actually Charlie"),
                SpeechSegment(start: 16, end: 20, text: "Back to Alice"),
            ],
            diarizationSegments: reconciled.formattingDiarizationSegments,
            meetingStart: meetingStart,
            speakerNames: names
        )
        #expect(transcript == """
        [10:00:00] Alice: Hello
        [10:00:08] Charlie: Actually Charlie
        [10:00:16] Alice: Back to Alice
        """)

        // Private meetings must withhold rendered names even for single-turn overrides.
        #expect(reconciled.formattingSpeakerNames(resolvedFromStore: [:], renderNames: false).isEmpty)
    }

    @Test("fallback preserves live speaker names and unattributed Others when post-call diarization fails")
    func fallbackWithoutPostCallDiarization() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 4, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Alice line")
        let rawSecond = store.appendTurn(source: "Others", startSeconds: 8, endSeconds: 12, timestampLabel: "10:00:08", liveClusterID: "Others", text: "Charlie line")
        let second = try #require(rawSecond)
        _ = store.appendTurn(source: "Others", startSeconds: 16, endSeconds: 20, timestampLabel: "10:00:16", liveClusterID: "Others", text: "Still unknown")
        _ = try store.assignCluster("Speaker 1", to: .newName("Alice"))
        _ = try store.reassignTurn(second.id, to: .newName("Charlie"))

        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: nil,
            liveInput: store.reconciliationSnapshot()
        )
        #expect(reconciled.observations.map(\.assignedName) == ["Alice", "Charlie"])
        let names = reconciled.formattingSpeakerNames(resolvedFromStore: ["Speaker 1": "Alice", "Speaker 2": "Charlie"])
        let transcript = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: [
                SpeechSegment(start: 0, end: 4, text: "Alice line"),
                SpeechSegment(start: 8, end: 12, text: "Charlie line"),
                SpeechSegment(start: 16, end: 20, text: "Still unknown"),
            ],
            diarizationSegments: reconciled.formattingDiarizationSegments,
            meetingStart: meetingStart,
            speakerNames: names
        )
        #expect(transcript == """
        [10:00:00] Alice: Alice line
        [10:00:08] Charlie: Charlie line
        [10:00:16] Others: Still unknown
        """)
    }

    @Test("accidental brief boundary overlap does not steal an unnamed cluster")
    func boundaryJitterDoesNotStealUnnamedCluster() throws {
        var store = LiveMeetingSpeakerStore()
        _ = store.appendTurn(source: "Others", startSeconds: 0, endSeconds: 10, timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Alice")
        _ = try store.assignCluster("Speaker 1", to: .newName("Alice"))

        let postCall = [
            diarSeg("a", 0, 10, embedding: [1, 0]),
            // 0.1s jitter overlap at 9.9..10.0 on a 10s unnamed speaker "b"
            diarSeg("b", 9.9, 20, embedding: [0, 1]),
        ]
        let reconciled = LiveSpeakerReconciler.reconcile(
            diarizationSegments: postCall,
            liveInput: store.reconciliationSnapshot(),
            minimumVoiceprintSeconds: 1
        )
        #expect(reconciled.liveClusterNames == ["Speaker 1": "Alice"])
        #expect(reconciled.observations[0].assignedName == "Alice")
        #expect(reconciled.observations[1].assignedName == nil)
    }
}
