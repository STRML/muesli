import Testing
@testable import MuesliNativeApp

@Suite("Active recording sidebar item")
struct ActiveRecordingSidebarItemTests {
    private let titles: [Int64: String] = [7: "Reed - Bi-Weekly Check-In", 8: "   "]

    @Test("no active meeting means no item")
    func noActiveMeeting() {
        #expect(ActiveRecordingSidebarItem.make(activeMeetingID: nil, isPaused: false, titleFor: { titles[$0] }) == nil)
        #expect(ActiveRecordingSidebarItem.make(activeMeetingID: nil, isPaused: true, titleFor: { titles[$0] }) == nil)
    }

    @Test("a recording meeting shows its title and the Recording label")
    func recording() throws {
        let item = try #require(ActiveRecordingSidebarItem.make(activeMeetingID: 7, isPaused: false, titleFor: { titles[$0] }))
        #expect(item.meetingID == 7)
        #expect(item.title == "Reed - Bi-Weekly Check-In")
        #expect(item.statusLabel == "Recording")
        #expect(item.isPulsing)
    }

    @Test("a paused meeting says Paused and stops pulsing")
    func paused() throws {
        let item = try #require(ActiveRecordingSidebarItem.make(activeMeetingID: 7, isPaused: true, titleFor: { titles[$0] }))
        #expect(item.statusLabel == "Paused")
        #expect(!item.isPulsing)
    }

    @Test("an unknown or blank title falls back to Meeting")
    func titleFallback() throws {
        let unknown = try #require(ActiveRecordingSidebarItem.make(activeMeetingID: 99, isPaused: false, titleFor: { titles[$0] }))
        let blank = try #require(ActiveRecordingSidebarItem.make(activeMeetingID: 8, isPaused: false, titleFor: { titles[$0] }))
        #expect(unknown.title == "Meeting")
        #expect(blank.title == "Meeting")
    }
}
