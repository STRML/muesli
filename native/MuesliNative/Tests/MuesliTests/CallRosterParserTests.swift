import Testing
@testable import MuesliNativeApp

@Suite("Call roster parser")
struct CallRosterParserTests {
    /// Meet puts each person's name at the same depth under the same wrapper chain, and the
    /// wrappers' class names are obfuscated, so tests use arbitrary tokens for them.
    private let tile = ["a1", "b2", "c3", "d4", "e5", "f6"]
    private let clock = ["x1", "y2"]
    private let other = ["p9", "q8", "r7"]

    private func node(_ text: String, _ ancestry: [String]) -> CallRosterTextNode {
        CallRosterTextNode(text: text, ancestry: ancestry)
    }

    private func names(_ nodes: [CallRosterTextNode], selfNames: Set<String> = ["Samuel Reed"], known: [String] = []) -> [String] {
        CallRosterParser.names(from: nodes, selfNames: selfNames, knownNames: known)
    }

    @Test("R3, R4: tile names stay, the user, clock, and the meeting code go")
    func keepsTileNamesOnly() {
        let nodes = [
            node("3:06", clock), node("PM", clock),
            node("qfm-jwnh-ret", other),
            node("Quentin Machu", tile), node("Samuel Reed", tile),
        ]
        #expect(names(nodes) == ["Quentin Machu"])
    }

    @Test("R3: a tile that says You is the user")
    func dropsYou() {
        let nodes = [node("You", tile), node("Quentin Machu", tile), node("Dana Okafor", tile)]
        #expect(names(nodes) == ["Quentin Machu", "Dana Okafor"])
    }

    @Test("R5: a label repeated across tiles is a status, not a person")
    func dropsRepeatedLabels() {
        let nodes = [
            node("Quentin Machu", tile), node("Muted", tile),
            node("Dana Okafor", tile), node("Muted", tile),
        ]
        #expect(names(nodes) == ["Quentin Machu", "Dana Okafor"])
    }

    @Test("R6: a single word is a person only when the calendar knows it")
    func singleWordNeedsAKnownContact() {
        let nodes = [node("Gemini", tile), node("Quentin Machu", tile), node("Priya", tile)]
        #expect(names(nodes) == ["Quentin Machu"])
        #expect(names(nodes, known: ["Priya Raman"]) == ["Quentin Machu", "Priya"])
    }

    @Test("a lone text in a chain is not a tile")
    func needsARepeatedChain() {
        #expect(names([node("Quentin Machu", tile)]).isEmpty)
    }

    @Test("a name on the tile grid and in the People list is listed once, in first-seen order")
    func dedupesAcrossGroups() {
        let peopleList = ["l1", "l2", "l3", "l4", "l5", "l6"]
        let nodes = [
            node("Quentin Machu", tile), node("Dana Okafor", tile),
            node("quentin machu", peopleList), node("Priya Raman", peopleList),
        ]
        #expect(names(nodes) == ["Quentin Machu", "Dana Okafor", "Priya Raman"])
    }

    @Test("only the nearest wrappers define a tile, so the outer wrapper may differ per tile")
    func outerWrappersMayDiffer() {
        let first = ["top-a"] + tile
        let second = ["top-b"] + tile
        #expect(names([node("Quentin Machu", first), node("Dana Okafor", second)]) == ["Quentin Machu", "Dana Okafor"])
    }
}
