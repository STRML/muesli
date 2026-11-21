import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Live meeting speaker state")
struct LiveMeetingSpeakerStateTests {
    @Test("pre-adding a speaker mid-call before they speak keeps them available and deduplicates")
    func preAddSpeaker() throws {
        var store = LiveMeetingSpeakerStore()
        let added = try store.addSpeaker(name: "  Alice Chen ", profileID: 7)
        let duplicate = try store.addSpeaker(name: "alice chen")
        #expect(added.id == duplicate.id)
        #expect(added.displayName == "Alice Chen")
        #expect(added.profileID == 7)
        #expect(store.entries.contains(where: { $0.displayName == "Alice Chen" && !$0.isGenericCluster }))

        do {
            _ = try store.addSpeaker(name: "Speaker 1")
            Issue.record("Expected SpeakerIdentityError for reserved Speaker 1")
        } catch let error as SpeakerIdentityError {
            #expect(error == .reservedName)
        }
        do {
            _ = try store.addSpeaker(name: "Bad: Name")
            Issue.record("Expected SpeakerIdentityError for colon")
        } catch let error as SpeakerIdentityError {
            #expect(error == .reservedName)
        }
    }

    @Test("assigning and merging live clusters updates all past and future turns immediately")
    func assignAndMergeClusters() throws {
        var store = LiveMeetingSpeakerStore()
        let rawT1 = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 4,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Hi there"
        )
        let t1 = try #require(rawT1)
        let rawT2 = store.appendTurn(
            source: "Others", startSeconds: 5, endSeconds: 9,
            timestampLabel: "10:00:05", liveClusterID: "Speaker 2", text: "Hello back"
        )
        let t2 = try #require(rawT2)
        let rawT3 = store.appendTurn(
            source: "Others", startSeconds: 10, endSeconds: 14,
            timestampLabel: "10:00:10", liveClusterID: "Speaker 3", text: "Me again"
        )
        let t3 = try #require(rawT3)

        let alice = try store.assignCluster("Speaker 1", to: .savedProfile(id: 42, name: "Alice"))
        #expect(store.resolvedSpeakerName(for: t1) == "Alice")
        #expect(store.resolvedSpeakerName(for: t2) == "Speaker 2")

        // Merge Speaker 3 into Alice via existingEntry target.
        let merged = try store.assignCluster("Speaker 3", to: .existingEntry(id: alice.id))
        #expect(merged.clusterIDs == Set(["Speaker 1", "Speaker 3"]))
        #expect(store.resolvedSpeakerName(for: t3) == "Alice")
        #expect(!store.entries.contains(where: { $0.id == "cluster:Speaker 3" }))

        // Future turns on either merged cluster resolve to Alice automatically.
        let rawT4 = store.appendTurn(
            source: "Others", startSeconds: 15, endSeconds: 18,
            timestampLabel: "10:00:15", liveClusterID: "Speaker 3", text: "Still Alice"
        )
        let t4 = try #require(rawT4)
        #expect(store.resolvedSpeakerName(for: t4) == "Alice")
        #expect(store.renderedTranscript() == """
        [10:00:00] Alice: Hi there
        [10:00:05] Speaker 2: Hello back
        [10:00:10] Alice: Me again
        [10:00:15] Alice: Still Alice

        """)
    }

    @Test("reassigning a single turn overrides only that turn without merging the cluster")
    func singleTurnOverride() throws {
        var store = LiveMeetingSpeakerStore()
        let rawFirst = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 3,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "First"
        )
        let first = try #require(rawFirst)
        let rawSecond = store.appendTurn(
            source: "Others", startSeconds: 4, endSeconds: 7,
            timestampLabel: "10:00:04", liveClusterID: "Speaker 1", text: "Actually Bob"
        )
        let second = try #require(rawSecond)
        _ = try store.assignCluster("Speaker 1", to: .newName("Alice"))
        _ = try store.reassignTurn(second.id, to: .newName("Bob"))

        #expect(store.resolvedSpeakerName(for: store.turns[0]) == "Alice")
        #expect(store.resolvedSpeakerName(for: store.turns[1]) == "Bob")
        #expect(store.renderedTranscript() == """
        [10:00:00] Alice: First
        [10:00:04] Bob: Actually Bob

        """)
        let snapshot = store.reconciliationSnapshot()
        #expect(snapshot.clusterAssignments.count == 1)
        #expect(snapshot.clusterAssignments.first?.displayName == "Alice")
        #expect(snapshot.turnOverrides.count == 1)
        #expect(snapshot.turnOverrides.first?.turnID == first.id ? false : snapshot.turnOverrides.first?.displayName == "Bob")
    }

    @Test("retroactive relabeling updates early loading turns without overwriting manual overrides")
    func retroactiveRelabeling() throws {
        var store = LiveMeetingSpeakerStore()
        let rawLoadingTurn = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 3,
            timestampLabel: "10:00:00", liveClusterID: nil, text: "Early speech"
        )
        let loadingTurn = try #require(rawLoadingTurn)
        let rawOverriddenTurn = store.appendTurn(
            source: "Others", startSeconds: 4, endSeconds: 7,
            timestampLabel: "10:00:04", liveClusterID: "Others", text: "Manually named"
        )
        let overriddenTurn = try #require(rawOverriddenTurn)
        _ = try store.reassignTurn(overriddenTurn.id, to: .newName("Charlie"))

        let didRelabelLoading = store.relabelRetroactiveCluster(turnID: loadingTurn.id, clusterID: "Speaker 1")
        let didRelabelOverridden = store.relabelRetroactiveCluster(turnID: overriddenTurn.id, clusterID: "Speaker 2")
        #expect(didRelabelLoading == true)
        #expect(didRelabelOverridden == false)
        #expect(store.resolvedSpeakerName(for: store.turns[0]) == "Speaker 1")
        #expect(store.resolvedSpeakerName(for: store.turns[1]) == "Charlie")
    }

    @Test("renaming an entry folds case-insensitive duplicates and syncParticipants skips You")
    func renameAndSyncParticipants() throws {
        var store = LiveMeetingSpeakerStore()
        store.syncParticipants([
            MeetingParticipant(meetingID: 1, participantIdentifier: "cal:you", displayName: "You", insertionOrder: 0),
            MeetingParticipant(meetingID: 1, participantIdentifier: "cal:dana", displayName: "Dana", insertionOrder: 1),
            MeetingParticipant(meetingID: 1, participantIdentifier: "cal:dana2", displayName: "dana", insertionOrder: 2),
        ])
        #expect(store.entries.filter { $0.displayName.caseInsensitiveCompare("Dana") == .orderedSame }.count == 1)
        #expect(store.entries.filter { $0.isSelf }.count == 1)

        _ = store.appendTurn(
            source: "Others", startSeconds: 0, endSeconds: 2,
            timestampLabel: "10:00:00", liveClusterID: "Speaker 1", text: "Hello"
        )
        let renamed = try store.renameEntry("cluster:Speaker 1", to: "dana")
        #expect(renamed.displayName == "Dana")
        #expect(renamed.clusterIDs == ["Speaker 1"])
        #expect(store.resolvedSpeakerName(for: store.turns[0]) == "Dana")
    }

    @Test("assigning Others when live diarization is off still captures reconciliation intervals")
    func assignOthersFallbackCluster() throws {
        var store = LiveMeetingSpeakerStore()
        let rawTurn = store.appendTurn(
            source: "Others", startSeconds: 2, endSeconds: 8,
            timestampLabel: "10:00:02", liveClusterID: nil, text: "Hello"
        )
        let turn = try #require(rawTurn)
        _ = try store.assignCluster("Others", to: .newName("Alice"))
        #expect(store.resolvedSpeakerName(for: turn) == "Alice")
        let snapshot = store.reconciliationSnapshot()
        #expect(snapshot.clusterAssignments.count == 1)
        #expect(snapshot.clusterAssignments.first?.clusterID == "Others")
        #expect(snapshot.clusterAssignments.first?.intervals == [LiveSpeakerInterval(start: 2, end: 8)])
    }
}
