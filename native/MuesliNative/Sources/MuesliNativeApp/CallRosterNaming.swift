import Foundation

/// Names a diarized speaker from the people on the call, only when there is one possibility.
/// A guess between two names would put the wrong person's name on someone's words.
/// Design and failure matrix: docs/call-roster.md.
enum CallRosterNaming {
    struct Assignment: Equatable {
        let label: String
        let name: String
    }

    /// - Parameters:
    ///   - unnamedLabels: speakers no voiceprint or person has been matched to ("Speaker 1").
    ///   - rosterNames: everyone read from the call.
    ///   - namedAlready: people already matched to a voice, in `CallRosterParser.normalized` form.
    static func assignment(
        unnamedLabels: [String],
        rosterNames: [String],
        namedAlready: Set<String>,
        selfNames: Set<String>
    ) -> Assignment? {
        let excluded = namedAlready.union(selfNames.map(CallRosterParser.normalized))
        let candidates = rosterNames.filter { !excluded.contains(CallRosterParser.normalized($0)) }
        guard unnamedLabels.count == 1, candidates.count == 1,
              let label = unnamedLabels.first, let name = candidates.first else { return nil }
        return Assignment(label: label, name: name)
    }
}

/// Which names read from a call are new to the meeting. Keeps every name it has offered so a
/// participant the user removed is not added back on the next pass.
struct CallRosterTracker {
    private var offered: Set<String> = []
    private(set) var seenNames: [String] = []

    mutating func newNames(roster: [String], existing: [String]) -> [String] {
        let known = Set(existing.map(CallRosterParser.normalized))
        var added: [String] = []
        for name in roster {
            let key = CallRosterParser.normalized(name)
            guard !key.isEmpty, !offered.contains(key) else { continue }
            offered.insert(key)
            seenNames.append(name)
            guard !known.contains(key) else { continue }
            added.append(name)
        }
        return added
    }
}
