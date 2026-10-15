import Testing
@testable import MuesliNativeApp

@Suite("Call roster naming")
struct CallRosterNamingTests {
    private func pair(unnamed: [String], roster: [String], named: Set<String> = [], selfNames: Set<String> = ["Samuel Reed"]) -> CallRosterNaming.Assignment? {
        CallRosterNaming.assignment(unnamedLabels: unnamed, rosterNames: roster, namedAlready: named, selfNames: selfNames)
    }

    @Test("R13: one unnamed speaker and one unmatched name are the same person")
    func namesTheOnlyPossibility() {
        #expect(pair(unnamed: ["Speaker 1"], roster: ["Samuel Reed", "Quentin Machu"])
            == .init(label: "Speaker 1", name: "Quentin Machu"))
    }

    @Test("R12: two unnamed speakers are never guessed")
    func twoUnnamedSpeakersAreAmbiguous() {
        #expect(pair(unnamed: ["Speaker 1", "Speaker 2"], roster: ["Quentin Machu", "Dana Okafor"]) == nil)
    }

    @Test("R12: one unnamed speaker among several unmatched names is ambiguous")
    func severalCandidatesAreAmbiguous() {
        #expect(pair(unnamed: ["Speaker 1"], roster: ["Quentin Machu", "Dana Okafor"]) == nil)
    }

    @Test("R14: a name already matched to a voice is not a candidate")
    func namedVoicesAreNotCandidates() {
        #expect(pair(unnamed: ["Speaker 2"], roster: ["Quentin Machu", "Dana Okafor"], named: ["quentin machu"])
            == .init(label: "Speaker 2", name: "Dana Okafor"))
    }

    @Test("nobody left to name, or nobody to name them")
    func emptyCases() {
        #expect(pair(unnamed: [], roster: ["Quentin Machu"]) == nil)
        #expect(pair(unnamed: ["Speaker 1"], roster: []) == nil)
        #expect(pair(unnamed: ["Speaker 1"], roster: ["Samuel Reed"]) == nil)
    }
}
