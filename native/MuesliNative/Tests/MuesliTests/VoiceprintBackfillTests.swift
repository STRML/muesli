import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Voiceprint backfiller", .serialized)
struct VoiceprintBackfillTests {
    private func unit(_ axis: Int, toward other: Int? = nil, mix: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: 256)
        values[axis] = 1 - mix
        if let other { values[other] += mix }
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return values.map { $0 / norm }
    }

    private func segment(
        _ id: String,
        _ start: Float,
        _ end: Float,
        embedding: [Float] = []
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: id,
            embedding: embedding,
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1
        )
    }

    private func candidate(
        meetingID: Int64 = 1,
        startTime: String = "",
        durationSeconds: Double = 0,
        rawTranscript: String,
        existingSpeakers: [MeetingSpeaker] = []
    ) -> VoiceprintBackfillCandidate {
        VoiceprintBackfillCandidate(
            meetingID: meetingID,
            title: "Test Meeting",
            recordingPath: "/tmp/test.wav",
            startTime: startTime,
            durationSeconds: durationSeconds,
            rawTranscript: rawTranscript,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            existingSpeakers: existingSpeakers
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - Timestamp parsing

    @Test("parses relative [MM:SS] timestamps and caps long gaps and final turns at 30s")
    func parsesRelativeMinutesSecondsTimestamps() {
        let transcript = """
        [00:00] You: Opening hello
        [00:05] Alice: First point
        [01:20] Bob: Long pause before speaking
        """
        let intervals = VoiceprintBackfiller.parseTranscriptIntervals(
            rawTranscript: transcript,
            recordingDuration: 130,
            calendar: utcCalendar
        )

        #expect(intervals.count == 3)
        #expect(intervals[0] == TranscriptSpeakerInterval(speakerName: "You", startSeconds: 0, endSeconds: 5))
        // Gap from 5s to 80s is capped to 30s -> endSeconds = 35
        #expect(intervals[1] == TranscriptSpeakerInterval(speakerName: "Alice", startSeconds: 5, endSeconds: 35))
        // Last turn from 80s to 130s is capped to 30s -> endSeconds = 110
        #expect(intervals[2] == TranscriptSpeakerInterval(speakerName: "Bob", startSeconds: 80, endSeconds: 110))
    }

    @Test("parses 0-based [HH:MM:SS] imported transcript timestamps even when startTime is later in the day")
    func parsesZeroBasedThreePartTimestamps() {
        let transcript = """
        [00:00:03] Alice: Hello from imported audio
        [00:00:21] Bob: Sounds great
        """
        let intervals = VoiceprintBackfiller.parseTranscriptIntervals(
            rawTranscript: transcript,
            startTime: "2026-11-11T15:30:00Z",
            recordingDuration: 45,
            calendar: utcCalendar
        )

        #expect(intervals == [
            TranscriptSpeakerInterval(speakerName: "Alice", startSeconds: 3, endSeconds: 21),
            TranscriptSpeakerInterval(speakerName: "Bob", startSeconds: 21, endSeconds: 45),
        ])
    }

    @Test("parses wall-clock [HH:MM:SS] timestamps relative to meeting startTime and across midnight")
    func parsesWallClockTimestamps() {
        let transcript = """
        [23:58:00] You: Welcome everyone
        [23:58:15] Alice: Thanks for joining
        [00:02:00] Bob: After midnight point
        """
        let intervals = VoiceprintBackfiller.parseTranscriptIntervals(
            rawTranscript: transcript,
            startTime: "2026-11-11T23:55:00Z",
            recordingDuration: 600,
            calendar: utcCalendar
        )

        #expect(intervals.count == 3)
        #expect(intervals[0] == TranscriptSpeakerInterval(speakerName: "You", startSeconds: 180, endSeconds: 195))
        // 195s -> 420s capped at +30s = 225s
        #expect(intervals[1] == TranscriptSpeakerInterval(speakerName: "Alice", startSeconds: 195, endSeconds: 225))
        #expect(intervals[2] == TranscriptSpeakerInterval(speakerName: "Bob", startSeconds: 420, endSeconds: 450))
    }

    @Test("anchors wall-clock timestamps to first timestamp when startTime is unavailable")
    func parsesWallClockFallbackWithoutStartTime() {
        let transcript = """
        [10:15:05] Alice: First line
        [10:15:20] Bob: Second line
        """
        let intervals = VoiceprintBackfiller.parseTranscriptIntervals(
            rawTranscript: transcript,
            startTime: nil,
            recordingDuration: 40,
            calendar: utcCalendar
        )

        #expect(intervals == [
            TranscriptSpeakerInterval(speakerName: "Alice", startSeconds: 0, endSeconds: 15),
            TranscriptSpeakerInterval(speakerName: "Bob", startSeconds: 15, endSeconds: 40),
        ])
    }

    // MARK: - Cluster matching

    @Test("matches unambiguous cluster to named speaker from transcript profile match")
    func matchesUnambiguousClusterFromTranscript() {
        let aliceCentroid = unit(0)
        let bobCentroid = unit(1)
        let profiles = [
            SpeakerProfileSummary(id: 10, name: "Alice", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 20, name: "Bob", voiceprintCount: 0, meetingCount: 0),
        ]
        let transcript = """
        [10:00:00] alice: Let's review the roadmap.
        [10:00:15] Bob: Sounds good to me.
        """
        let segments = [
            segment("SPEAKER_00", 0, 14, embedding: aliceCentroid),
            segment("SPEAKER_01", 15, 32, embedding: bobCentroid),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(startTime: "2026-11-11T10:00:00Z", durationSeconds: 35, rawTranscript: transcript),
            segments: segments,
            speakerCentroids: [:],
            profiles: profiles,
            calendar: utcCalendar
        )

        #expect(matches.count == 2)
        #expect(matches[0].profileID == 10)
        #expect(matches[0].label == "Alice")
        #expect(SpeakerVoiceprintMatcher.cosineSimilarity(matches[0].centroid, aliceCentroid)! > 0.999)
        #expect(matches[1].profileID == 20)
        #expect(matches[1].label == "Bob")
        #expect(SpeakerVoiceprintMatcher.cosineSimilarity(matches[1].centroid, bobCentroid)! > 0.999)
    }

    @Test("matches private-meeting Speaker N label via existingSpeakers profileID and preserves label")
    func matchesExistingSpeakerRowWithGenericLabel() {
        let centroid = unit(3)
        let profiles = [
            SpeakerProfileSummary(id: 42, name: "Casey", voiceprintCount: 0, meetingCount: 1),
        ]
        let existing = [
            MeetingSpeaker(label: "Speaker 1", profileID: 42, profileName: "Casey", hasVoiceprintSource: false, hasVoiceprintFromMeeting: false),
        ]
        let transcript = "[00:00] Speaker 1: I am speaking in a private meeting."
        let segments = [
            segment("S0", 0, 15, embedding: []),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(durationSeconds: 20, rawTranscript: transcript, existingSpeakers: existing),
            segments: segments,
            speakerCentroids: ["S0": centroid],
            profiles: profiles,
            calendar: utcCalendar
        )

        #expect(matches.count == 1)
        #expect(matches[0].profileID == 42)
        #expect(matches[0].label == "Speaker 1")
        #expect(SpeakerVoiceprintMatcher.cosineSimilarity(matches[0].centroid, centroid)! > 0.999)
    }

    @Test("rejects ambiguous clusters where majority overlap is below 0.60")
    func rejectsAmbiguousCluster() {
        let profiles = [
            SpeakerProfileSummary(id: 1, name: "Alice", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 2, name: "Bob", voiceprintCount: 0, meetingCount: 0),
        ]
        // 11s Alice (55%) and 9s Bob (45%) inside one 20s cluster -> below 60% threshold
        let transcript = """
        [00:00] Alice: First half
        [00:11] Bob: Second half
        """
        let segments = [
            segment("S0", 0, 20, embedding: unit(0)),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(durationSeconds: 20, rawTranscript: transcript),
            segments: segments,
            speakerCentroids: [:],
            profiles: profiles,
            calendar: utcCalendar
        )
        #expect(matches.isEmpty)
    }

    @Test("respects 10s minimum diarized speech duration")
    func respectsMinimumSpeechDuration() {
        let profiles = [
            SpeakerProfileSummary(id: 1, name: "Alice", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 2, name: "Bob", voiceprintCount: 0, meetingCount: 0),
        ]
        let transcript = """
        [00:00] Alice: Short comment
        [00:10] Bob: Longer explanation
        """
        let segments = [
            segment("S0", 0, 9.9, embedding: unit(0)),
            segment("S1", 10, 20.0, embedding: unit(1)),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(durationSeconds: 25, rawTranscript: transcript),
            segments: segments,
            speakerCentroids: [:],
            profiles: profiles,
            calendar: utcCalendar
        )

        #expect(matches.map(\.profileID) == [2])
    }

    @Test("ignores reserved labels You, Others, Speaker N, Local speaker N and keeps You in overlap denominator")
    func ignoresReservedLabelsAndProtectsFromYouOverlap() {
        // Even if a profile were somehow named "You" or "Speaker 1", it must never match.
        let profiles = [
            SpeakerProfileSummary(id: 1, name: "You", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 2, name: "Others", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 3, name: "Speaker 1", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 4, name: "Local speaker 1", voiceprintCount: 0, meetingCount: 0),
            SpeakerProfileSummary(id: 5, name: "Alice", voiceprintCount: 0, meetingCount: 0),
        ]
        // Cluster S0 overlaps 15s of "You" and 5s of "Alice" -> Alice has only 25% of overlapping speech -> rejected!
        // Cluster S1 overlaps 12s of "Speaker 1" / "Others" / "Local speaker 1" -> none are named profiles.
        let transcript = """
        [00:00] You: Talking for fifteen seconds
        [00:15] Alice: Brief reply
        [00:20] Speaker 1: Unnamed speaker
        [00:25] Others: Remote chatter
        [00:30] Local speaker 1: Room voice
        """
        let segments = [
            segment("S0", 0, 20, embedding: unit(0)),
            segment("S1", 20, 35, embedding: unit(1)),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(durationSeconds: 35, rawTranscript: transcript),
            segments: segments,
            speakerCentroids: [:],
            profiles: profiles,
            calendar: utcCalendar
        )

        #expect(matches.isEmpty)
    }

    @Test("weighted-merges centroids when two clusters clearly belong to the same named speaker")
    func mergesSplitClustersForSameSpeaker() {
        let profiles = [
            SpeakerProfileSummary(id: 7, name: "Alice", voiceprintCount: 0, meetingCount: 0),
        ]
        let transcript = """
        [00:00] Alice: First long monologue
        [00:30] Alice: Second long monologue
        """
        // Two separate clusters both overlapping Alice cleanly (>= 10s each, 100% overlap)
        let segments = [
            segment("S0", 0, 15, embedding: unit(0)),
            segment("S1", 30, 45, embedding: unit(1)),
        ]

        let matches = VoiceprintBackfiller.match(
            candidate: candidate(durationSeconds: 50, rawTranscript: transcript),
            segments: segments,
            speakerCentroids: [:],
            profiles: profiles,
            calendar: utcCalendar
        )

        #expect(matches.count == 1)
        #expect(matches[0].profileID == 7)
        let expected = unit(0, toward: 1, mix: 0.5)
        #expect(SpeakerVoiceprintMatcher.cosineSimilarity(matches[0].centroid, expected)! > 0.999)
    }

    @Test("end-to-end backfill leaves transcript and notes untouched and prevents duplicate eligibility")
    func endToEndBackfillStoreAndMatcher() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backfill-e2e-\(UUID().uuidString).db")
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-backfill-e2e-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recordingURL)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: recordingURL)
        }

        let store = DictationStore(databaseURL: dbURL)
        try store.migrateIfNeeded()
        let alice = try store.findOrCreateSpeakerProfile(name: "Alice")

        let meetingStart = Calendar.current.date(
            bySettingHour: 10,
            minute: 0,
            second: 0,
            of: Date(timeIntervalSince1970: 1_800_000_000)
        )!
        let transcript = "[10:00:00] You: Hey Alice\n[10:00:05] Alice: Glad to be here!"
        let notes = "Action items for Alice."
        let meetingID = try store.insertMeeting(
            title: "1:1",
            calendarEventID: nil,
            startTime: meetingStart,
            endTime: meetingStart.addingTimeInterval(30),
            rawTranscript: transcript,
            formattedNotes: notes,
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: recordingURL.path
        )

        let candidates = try store.meetingsEligibleForVoiceprintBackfill()
        #expect(candidates.count == 1)

        let aliceCentroid = unit(4)
        let segments = [
            segment("SPEAKER_00", 5, 25, embedding: aliceCentroid),
        ]
        let matches = VoiceprintBackfiller.match(
            candidate: candidates[0],
            segments: segments,
            speakerCentroids: [:],
            profiles: try store.speakerProfiles()
        )
        #expect(matches.count == 1)
        #expect(matches[0].profileID == alice.id)

        let stored = try store.applyBackfilledVoiceprints(meetingID: meetingID, matches: matches)
        #expect(stored == 1)

        // Transcript & notes preserved
        let updatedMeeting = try #require(try store.meeting(id: meetingID))
        #expect(updatedMeeting.rawTranscript == transcript)
        #expect(updatedMeeting.formattedNotes == notes)

        // No longer eligible
        #expect(try store.meetingsEligibleForVoiceprintBackfill().isEmpty)

        // Future meeting recognizes Alice from the backfilled voiceprint
        let nextMeeting = try store.insertMeeting(
            title: "Follow-up",
            calendarEventID: nil,
            startTime: Date(),
            endTime: Date().addingTimeInterval(30),
            rawTranscript: "[11:00:00] Speaker 1: Checking in",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let recognized = try store.recordMeetingSpeakers(
            meetingID: nextMeeting,
            observations: [MeetingSpeakerObservation(label: "Speaker 1", centroid: aliceCentroid, speechSeconds: 20)],
            renderNames: true
        )
        #expect(recognized == ["Speaker 1": "Alice"])
    }
}
