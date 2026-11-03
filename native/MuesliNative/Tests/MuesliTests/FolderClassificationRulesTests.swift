import Testing
import Foundation
import MuesliCore

@Suite("Folder classification rules")
struct FolderClassificationRulesTests {
    private let rush: Int64 = 1
    private let v12: Int64 = 2
    private let folderNames: [Int64: String] = [1: "Rush", 2: "V12"]

    private func memory(
        _ kind: ClassificationMemoryKind,
        _ key: String,
        folder: Int64,
        confirmations: Int = 0,
        contradictions: Int = 0
    ) -> ClassificationMemory {
        ClassificationMemory(kind: kind, key: key, folderID: folder, confirmations: confirmations, contradictions: contradictions)
    }

    private func classify(
        series: String? = nil,
        emails: [String] = [],
        title: String = "Untitled",
        memory: [ClassificationMemory],
        selfEmails: Set<String> = []
    ) -> [FolderSuggestionCandidate] {
        FolderClassificationRules.classify(
            ClassificationEvidence(seriesID: series, emails: emails, title: title),
            memory: memory,
            selfEmails: selfEmails,
            folderNames: folderNames
        )
    }

    // MARK: - Abstain

    @Test("empty memory abstains")
    func emptyMemoryAbstains() {
        #expect(classify(series: "s1", emails: ["a@x.com"], title: "Weekly sync", memory: []).isEmpty)
    }

    @Test("unknown folder in memory abstains rather than suggesting a deleted folder")
    func unknownFolderAbstains() {
        let result = classify(series: "s1", memory: [memory(.series, "s1", folder: 99, confirmations: 3)])
        #expect(result.isEmpty)
    }

    // MARK: - Series rule

    @Test("series seen once with no contradictions is decisive")
    func seriesDecisive() throws {
        let result = classify(series: "s1", memory: [memory(.series, "s1", folder: rush, confirmations: 4)])
        let candidate = try #require(result.first)
        #expect(result.count == 1)
        #expect(candidate.folderID == rush)
        #expect(candidate.source == .series)
        #expect(candidate.reason == "Same recurring series as 4 meetings in Rush")
        #expect(candidate.confidence > 0.9)
    }

    @Test("series with a contradiction abstains")
    func seriesContradictedAbstains() {
        let result = classify(series: "s1", memory: [memory(.series, "s1", folder: rush, confirmations: 4, contradictions: 1)])
        #expect(result.isEmpty)
    }

    @Test("series confirmed into two folders abstains")
    func seriesSplitAbstains() {
        let result = classify(series: "s1", memory: [
            memory(.series, "s1", folder: rush, confirmations: 3),
            memory(.series, "s1", folder: v12, confirmations: 1),
        ])
        #expect(result.isEmpty)
    }

    @Test("series rule wins over a conflicting email rule")
    func seriesWinsFirst() throws {
        let result = classify(series: "s1", emails: ["a@x.com"], memory: [
            memory(.series, "s1", folder: rush, confirmations: 1),
            memory(.email, "a@x.com", folder: v12, confirmations: 5),
        ])
        #expect(try #require(result.first).folderID == rush)
        #expect(result.count == 1)
    }

    // MARK: - Email rule

    @Test("email: unanimous known attendees with two confirmations is decisive")
    func emailUnanimousDecisive() throws {
        let result = classify(emails: ["a@x.com", "b@x.com"], memory: [
            memory(.email, "a@x.com", folder: rush, confirmations: 2),
            memory(.email, "b@x.com", folder: rush, confirmations: 3),
        ])
        let candidate = try #require(result.first)
        #expect(candidate.folderID == rush)
        #expect(candidate.source == .email)
        #expect(candidate.reason.contains("Rush"))
    }

    @Test("email: one confirmation is not enough")
    func emailSingleConfirmationAbstains() {
        let result = classify(emails: ["a@x.com"], memory: [memory(.email, "a@x.com", folder: rush, confirmations: 1)])
        #expect(result.isEmpty)
    }

    @Test("email: weakest known voter below two confirmations abstains")
    func emailWeakestVoterAbstains() {
        let result = classify(emails: ["a@x.com", "b@x.com"], memory: [
            memory(.email, "a@x.com", folder: rush, confirmations: 5),
            memory(.email, "b@x.com", folder: rush, confirmations: 1),
        ])
        #expect(result.isEmpty)
    }

    @Test("email: attendees split across folders abstains")
    func emailSplitAbstains() {
        let result = classify(emails: ["a@x.com", "b@x.com"], memory: [
            memory(.email, "a@x.com", folder: rush, confirmations: 3),
            memory(.email, "b@x.com", folder: v12, confirmations: 3),
        ])
        #expect(result.isEmpty)
    }

    @Test("email: one attendee known in two folders abstains")
    func emailAttendeeInTwoFoldersAbstains() {
        let result = classify(emails: ["a@x.com"], memory: [
            memory(.email, "a@x.com", folder: rush, confirmations: 3),
            memory(.email, "a@x.com", folder: v12, confirmations: 2),
        ])
        #expect(result.isEmpty)
    }

    @Test("email: a contradicted attendee abstains")
    func emailContradictedAbstains() {
        let result = classify(emails: ["a@x.com", "b@x.com"], memory: [
            memory(.email, "a@x.com", folder: rush, confirmations: 3),
            memory(.email, "b@x.com", folder: rush, confirmations: 3, contradictions: 1),
        ])
        #expect(result.isEmpty)
    }

    @Test("email: zero known attendees abstains")
    func emailZeroKnownAbstains() {
        let result = classify(emails: ["a@x.com", "b@x.com"], memory: [memory(.email, "c@x.com", folder: rush, confirmations: 4)])
        #expect(result.isEmpty)
    }

    @Test("email: an unknown attendee does not block a unanimous known group")
    func emailUnknownAttendeeDoesNotBlock() throws {
        let result = classify(emails: ["a@x.com", "stranger@y.com"], memory: [memory(.email, "a@x.com", folder: rush, confirmations: 2)])
        #expect(try #require(result.first).folderID == rush)
    }

    @Test("email: the user's own address is ignored")
    func emailSelfIgnored() throws {
        let memory = [
            memory(.email, "me@me.com", folder: v12, confirmations: 9),
            memory(.email, "a@x.com", folder: rush, confirmations: 2),
        ]
        let result = classify(emails: ["MAILTO:Me@me.com", "a@x.com"], memory: memory, selfEmails: ["me@me.com"])
        #expect(try #require(result.first).folderID == rush)
        // Only the self address known: abstain.
        #expect(classify(emails: ["me@me.com"], memory: memory, selfEmails: ["me@me.com"]).isEmpty)
    }

    @Test("email: mailto prefixes and case are normalized before lookup")
    func emailNormalizedLookup() throws {
        let result = classify(emails: ["mailto:A@X.com"], memory: [memory(.email, "a@x.com", folder: rush, confirmations: 2)])
        #expect(try #require(result.first).folderID == rush)
    }

    // MARK: - Title rule

    @Test("title: exact normalized title with two confirmations is decisive")
    func titleDecisive() throws {
        let result = classify(title: "Zoom: Rush Weekly Sync 10/13", memory: [memory(.title, "rush weekly sync", folder: rush, confirmations: 2)])
        let candidate = try #require(result.first)
        #expect(candidate.source == .title)
        #expect(candidate.reason == "Same title as 2 meetings in Rush")
    }

    @Test("title: one confirmation abstains")
    func titleSingleConfirmationAbstains() {
        #expect(classify(title: "Rush Weekly Sync", memory: [memory(.title, "rush weekly sync", folder: rush, confirmations: 1)]).isEmpty)
    }

    @Test("title: contradicted title abstains")
    func titleContradictedAbstains() {
        #expect(classify(title: "Rush Weekly Sync", memory: [memory(.title, "rush weekly sync", folder: rush, confirmations: 4, contradictions: 1)]).isEmpty)
    }

    @Test("title normalization strips prefixes, dates, times and digits", arguments: [
        ("Zoom: Rush Weekly Sync", "rush weekly sync"),
        ("Zoom Meeting: Rush Weekly Sync", "rush weekly sync"),
        ("Microsoft Teams Meeting - Rush Weekly Sync", "rush weekly sync"),
        ("FW: Re: Rush Weekly Sync", "rush weekly sync"),
        ("Rush Weekly Sync 10/13", "rush weekly sync"),
        ("Rush Weekly Sync - Oct 13, 2026 3:00 PM", "rush weekly sync"),
        ("Rush Weekly Sync (2026-10-13 15:00)", "rush weekly sync"),
        ("Rush weekly sync 3pm", "rush weekly sync"),
        ("RUSH   weekly\tsync", "rush weekly sync"),
        ("May planning", "may planning"),
    ])
    func titleNormalization(input: String, expected: String) {
        #expect(FolderClassificationRules.normalizeTitle(input) == expected)
    }

    @Test("title normalization of empty or digit-only titles yields no key", arguments: ["", "   ", "123", "10/13 3:00 PM", "Zoom:"])
    func titleNormalizationEmpty(input: String) {
        #expect(FolderClassificationRules.normalizeTitle(input) == nil)
    }

    @Test("email normalization", arguments: [
        ("mailto:A@X.com", "a@x.com" as String?),
        ("  b@y.org ", "b@y.org"),
        ("not-an-email", nil),
        ("", nil),
    ])
    func emailNormalization(input: String, expected: String?) {
        #expect(FolderClassificationRules.normalizeEmail(input) == expected)
    }

    @Test("memory keys exclude self and duplicates")
    func memoryKeys() {
        let evidence = ClassificationEvidence(seriesID: "s1", emails: ["a@x.com", "mailto:A@x.com", "me@me.com"], title: "Zoom: Sync 3pm")
        let keys = FolderClassificationRules.memoryKeys(for: evidence, selfEmails: ["me@me.com"])
        #expect(keys == [
            ClassificationMemoryKey(kind: .series, key: "s1"),
            ClassificationMemoryKey(kind: .email, key: "a@x.com"),
            ClassificationMemoryKey(kind: .title, key: "sync"),
        ])
    }
}
