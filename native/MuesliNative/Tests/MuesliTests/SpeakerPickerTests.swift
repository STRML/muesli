@testable import MuesliCore
@testable import MuesliNativeApp
import SwiftUI
import Testing

@Suite("Speaker picker")
struct SpeakerPickerTests {
    private func profile(
        _ id: Int64,
        _ name: String,
        voiceprints: Int = 1,
        meetings: Int = 2
    ) -> SpeakerProfileSummary {
        SpeakerProfileSummary(
            id: id,
            name: name,
            voiceprintCount: voiceprints,
            meetingCount: meetings
        )
    }

    private func known(_ identifier: String, _ name: String, email: String? = nil) -> MeetingParticipantDraft {
        MeetingParticipantDraft(
            participantIdentifier: identifier,
            displayName: name,
            emailAddress: email
        )
    }

    // MARK: - Ranking & deduplication

    @Test("candidates rank in meeting, saved profiles, known people, then merge clusters")
    func rankingOrderAndDeduplication() {
        let output = SpeakerPickerFilter.filter(
            query: "",
            currentClusterLabel: "Speaker 1",
            inMeetingNames: ["Blair Hosie", "Ken Thwaites"],
            profiles: [
                profile(10, "blair hosie", voiceprints: 3, meetings: 5),
                profile(11, "Sarah Lin", voiceprints: 1, meetings: 1),
            ],
            knownPeople: [
                known("c1", "Ken Thwaites", email: "ken@example.com"),
                known("c2", "Sarah Lin", email: "sarah@example.com"),
                known("c3", "Devon Brooks", email: "devon@example.com"),
            ],
            activeClusterLabels: ["Speaker 1", "Speaker 2", "You", "Others"]
        )

        #expect(output.validationError == nil)
        #expect(output.candidates.map(\.section) == [
            .inMeeting,
            .inMeeting,
            .savedProfiles,
            .knownPeople,
            .mergeClusters,
        ])
        #expect(output.candidates.map(\.displayName) == [
            "Blair Hosie",
            "Ken Thwaites",
            "Sarah Lin",
            "Devon Brooks",
            "Speaker 2",
        ])

        // In-meeting entries inherit profileID and participantIdentifier during dedup.
        #expect(output.candidates[0].profileID == 10)
        #expect(output.candidates[1].participantIdentifier == "c1")
        #expect(output.candidates[1].subtitle == "ken@example.com")
        #expect(output.candidates[2].profileID == 11)
        #expect(output.candidates[2].participantIdentifier == "c2")
    }

    @Test("saved profile subtitles omit 0 voiceprints clutter and show positive counts")
    func savedProfileSubtitles() {
        let output = SpeakerPickerFilter.filter(
            query: "",
            inMeetingNames: ["Alex Kim"],
            profiles: [
                profile(1, "Alex Kim", voiceprints: 0, meetings: 3),
                profile(2, "Blair Hosie", voiceprints: 0, meetings: 1),
                profile(3, "Ken Thwaites", voiceprints: 0, meetings: 0),
                profile(4, "Sarah Lin", voiceprints: 1, meetings: 2),
                profile(5, "Devon Brooks", voiceprints: 2, meetings: 0),
            ]
        )

        let subtitlesByName = Dictionary(
            uniqueKeysWithValues: output.candidates.map { ($0.displayName, $0.subtitle) }
        )
        #expect(subtitlesByName["Alex Kim"] == "3 meetings")
        #expect(subtitlesByName["Blair Hosie"] == "1 meeting")
        #expect(subtitlesByName["Ken Thwaites"] == "Saved speaker")
        #expect(subtitlesByName["Sarah Lin"] == "1 voiceprint · 2 meetings")
        #expect(subtitlesByName["Devon Brooks"] == "2 voiceprints")
        for subtitle in subtitlesByName.values {
            #expect(subtitle?.contains("0 voiceprints") != true)
        }
    }

    @Test("prefix matches rank ahead of substring matches when filtering")
    func prefixBeforeSubstring() {
        let output = SpeakerPickerFilter.filter(
            query: "al",
            inMeetingNames: ["Walden Reed", "Alice Chen", "Malcolm Grant", "Alex Kim"]
        )

        #expect(output.candidates.first?.isCreateAction == true)
        #expect(output.candidates.first?.displayName == "al")
        let existingNames = output.candidates.dropFirst().map(\.displayName)
        #expect(existingNames == ["Alice Chen", "Alex Kim", "Walden Reed", "Malcolm Grant"])
    }

    // MARK: - Create vs exact match

    @Test("typed query with no exact match puts Add action first as default highlight")
    func createActionIsDefaultWhenNoExactMatch() {
        let output = SpeakerPickerFilter.filter(
            query: "  Alice ",
            currentClusterLabel: "Speaker 1",
            inMeetingNames: ["Alice Chen"]
        )

        let first = output.candidates.first
        #expect(first?.isCreateAction == true)
        #expect(first?.displayName == "Alice")
        #expect(first?.subtitle == "Add and assign to Speaker 1")
        #expect(output.defaultHighlightedID == first?.id)
    }

    @Test("exact case-insensitive match suppresses Add action and selects existing person")
    func exactMatchSuppressesCreateAction() {
        let output = SpeakerPickerFilter.filter(
            query: "blair hosie",
            currentClusterLabel: "Speaker 1",
            inMeetingNames: ["Blair Hosie"],
            profiles: [profile(7, "Blair Hosie")]
        )

        #expect(!output.candidates.contains { $0.isCreateAction })
        #expect(output.candidates.count == 1)
        #expect(output.defaultHighlightedID == output.candidates[0].id)
    }

    // MARK: - Merge clusters

    @Test("merge clusters respect allowMergeClusters and exclude current or reserved labels")
    func mergeClustersBehavior() {
        let enabled = SpeakerPickerFilter.filter(
            query: "",
            currentClusterLabel: "Speaker 1",
            activeClusterLabels: ["Speaker 1", "Speaker 2", "Speaker 3", "You", "Others"],
            allowMergeClusters: true
        )
        #expect(enabled.candidates.map(\.mergeClusterLabel) == ["Speaker 2", "Speaker 3"])

        let disabled = SpeakerPickerFilter.filter(
            query: "",
            currentClusterLabel: "Speaker 1",
            activeClusterLabels: ["Speaker 1", "Speaker 2"],
            allowMergeClusters: false
        )
        #expect(disabled.candidates.isEmpty)

        let noCurrentCluster = SpeakerPickerFilter.filter(
            query: "",
            currentClusterLabel: nil,
            activeClusterLabels: ["Speaker 1", "Speaker 2"],
            allowMergeClusters: true
        )
        #expect(noCurrentCluster.candidates.isEmpty)
    }

    // MARK: - Validation

    @Test("reserved labels, colons, newlines, and overly long names show validation errors")
    func nameValidation() {
        for invalid in ["You", "you", "Others", "Speaker 1", "speaker 12", "Local speaker", "Local speaker 2", "Multiple speakers", "Unknown speaker", "Alice: PM", "Alice\nBob"] {
            let result = SpeakerNameValidator.validate(invalid)
            if case .invalid = result {
                // expected
            } else {
                Issue.record("Expected invalid result for '\(invalid)', got \(result)")
            }

            let filtered = SpeakerPickerFilter.filter(query: invalid)
            #expect(filtered.validationError != nil)
            #expect(!filtered.candidates.contains { $0.isCreateAction })
        }

        let tooLong = String(repeating: "a", count: SpeakerNameValidator.maxLength + 1)
        if case .invalid = SpeakerNameValidator.validate(tooLong) {} else {
            Issue.record("Expected over-length name to fail validation")
        }

        for valid in ["Blair Hosie", "Mary-Ann O'Neil Jr.", "Alex (PM)"] {
            #expect(SpeakerNameValidator.validate(valid) == .valid(valid))
        }
        #expect(SpeakerNameValidator.validate("   \n ") == .empty)
    }

    // MARK: - Sample quotes & deterministic palette

    @Test("sample quote extractor returns concise first meaningful utterance per speaker")
    func sampleQuotes() {
        let transcript = """
        [10:00:00] You: Hi.
        [10:00:02] Speaker 1: Oh.
        [10:00:05] Speaker 1: We should ship the beta release right after Friday's design review.
        [10:00:12] Speaker 2: Sounds good, I will prep the release notes today.
        """

        let quotes = SpeakerSampleQuoteExtractor.sampleQuotes(
            for: ["Speaker 1", "Speaker 2", "Speaker 3"],
            in: transcript,
            maxLength: 40
        )

        #expect(quotes["Speaker 1"] == "We should ship the beta release right…")
        #expect(quotes["Speaker 2"] == "Sounds good, I will prep the release…")
        #expect(quotes["Speaker 3"] == nil)
    }

    @Test("speaker color palette is deterministic for identical speaker names")
    func colorPaletteDeterminism() {
        #expect(SpeakerColorPalette.color(for: "Blair Hosie") == SpeakerColorPalette.color(for: "  blair hosie "))
        #expect(SpeakerColorPalette.color(for: "You") == MuesliTheme.accentText)
        #expect(SpeakerColorPalette.color(for: "Others") == MuesliTheme.textTertiary)
    }

    // MARK: - Quick-add participant filter

    @Test("quick-add participant filter excludes already attached participants and ranks create first")
    func participantQuickAddFilter() {
        let existing = [
            MeetingParticipant(meetingID: 1, participantIdentifier: "manual:1", displayName: "Blair Hosie", insertionOrder: 0)
        ]
        let candidates = MeetingParticipantQuickAddFilter.candidates(
            query: "Ken",
            existingParticipants: existing,
            profiles: [profile(1, "Blair Hosie"), profile(2, "Ken Thwaites")],
            knownPeople: [known("c1", "Kenji Sato", email: "kenji@example.com")]
        )

        #expect(candidates.map(\.displayName) == ["Ken", "Kenji Sato", "Ken Thwaites"])
        #expect(candidates[0].isCreateAction)
        #expect(!candidates.contains { $0.displayName.caseInsensitiveCompare("Blair Hosie") == .orderedSame })

        #expect(MeetingParticipantQuickAddFilter.isAlreadyAttached(name: "  blair hosie ", in: existing))
        #expect(!MeetingParticipantQuickAddFilter.isAlreadyAttached(name: "Ken", in: existing))
    }
}
