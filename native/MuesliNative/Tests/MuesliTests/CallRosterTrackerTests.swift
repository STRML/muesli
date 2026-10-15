import Testing
@testable import MuesliNativeApp

@Suite("Call roster tracker")
struct CallRosterTrackerTests {
    @Test("R8: names the meeting already has are skipped, however they are written")
    func skipsKnownParticipants() {
        var tracker = CallRosterTracker()
        let added = tracker.newNames(roster: ["Quentin Machu", "dana okafor", "Priya Raman"],
                                     existing: ["Dana Okafor", "Quentin  Machu"])
        #expect(added == ["Priya Raman"])
    }

    @Test("a name is offered once, even when it shows up again")
    func offersEachNameOnce() {
        var tracker = CallRosterTracker()
        #expect(tracker.newNames(roster: ["Quentin Machu"], existing: []) == ["Quentin Machu"])
        #expect(tracker.newNames(roster: ["Quentin Machu", "Dana Okafor"], existing: []) == ["Dana Okafor"])
    }

    @Test("R9: a participant the user removed does not come back")
    func removedParticipantStaysRemoved() {
        var tracker = CallRosterTracker()
        _ = tracker.newNames(roster: ["Quentin Machu"], existing: [])
        // The user removed the row, so the meeting no longer lists the name.
        #expect(tracker.newNames(roster: ["Quentin Machu"], existing: []).isEmpty)
    }

    @Test("the roster so far keeps every name seen, in order")
    func remembersTheRoster() {
        var tracker = CallRosterTracker()
        _ = tracker.newNames(roster: ["Quentin Machu"], existing: [])
        _ = tracker.newNames(roster: ["Dana Okafor"], existing: [])
        #expect(tracker.seenNames == ["Quentin Machu", "Dana Okafor"])
    }
}
