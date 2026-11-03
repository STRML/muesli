import Foundation

/// One piece of text from a call page and the class lists of the elements around it, outermost first.
struct CallRosterTextNode: Equatable {
    let text: String
    let ancestry: [String]
}

/// Picks participant names out of a call page's text without knowing the page's markup (Meet's class
/// names are obfuscated and change). People are laid out as repeated tiles, so a name is a text that
/// sits in a wrapper chain shared by at least two texts and is the only one of its kind there.
/// Design and failure matrix: docs/call-roster.md.
enum CallRosterParser {
    /// The nearest wrappers define a tile. Outer ones can differ per tile (the user's own, a pinned one).
    static let tileDepth = 6

    static func names(from nodes: [CallRosterTextNode], selfNames: Set<String>, knownNames: [String]) -> [String] {
        let own = Set(selfNames.map(normalized)).union(["you"])
        let knownFirstNames = Set(knownNames.compactMap { normalized($0).split(separator: " ").first.map(String.init) })
        let groups = Dictionary(grouping: nodes) { $0.ancestry.suffix(tileDepth).joined(separator: "/") }

        var result: [String] = []
        var seen = Set<String>()
        for node in nodes {
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(text)
            guard let group = groups[node.ancestry.suffix(tileDepth).joined(separator: "/")], group.count >= 2,
                  group.filter({ normalized($0.text) == key }).count == 1,
                  isNameShaped(text), !own.contains(key), !seen.contains(key),
                  key.contains(" ") || knownFirstNames.contains(key) else { continue }
            seen.insert(key)
            result.append(text)
        }
        return result
    }

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static let nameMarks = CharacterSet(charactersIn: " '’.-")

    /// Letters, spaces and the marks names use. Rules out times, digits, codes and sentences.
    private static func isNameShaped(_ text: String) -> Bool {
        guard (2...40).contains(text.count), text.split(separator: " ").count <= 5,
              let first = text.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(nameMarks)
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
