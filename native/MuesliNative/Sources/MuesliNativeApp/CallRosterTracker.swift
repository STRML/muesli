import Foundation

/// The roster of the meeting being recorded. It belongs to one meeting: names read in an earlier
/// call must never be offered to a later one (a Zoom call after a Meet call).
struct CallRosterBook {
    private var meetingID: Int64?
    private var tracker = CallRosterTracker()

    mutating func newNames(meetingID: Int64, roster: [String], existing: [String]) -> [String] {
        if self.meetingID != meetingID {
            self.meetingID = meetingID
            tracker = CallRosterTracker()
        }
        return tracker.newNames(roster: roster, existing: existing)
    }

    func names(for meetingID: Int64) -> [String] {
        self.meetingID == meetingID ? tracker.seenNames : []
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
