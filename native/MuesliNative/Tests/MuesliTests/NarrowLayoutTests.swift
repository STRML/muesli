import AppKit
import SwiftUI
import Testing
import MuesliCore
@testable import MuesliNativeApp

/// A window narrow enough to show a meeting list beside the sidebar leaves a pane of about 240 pt.
/// Rows of buttons and menus that cannot shrink must wrap there instead of widening the page.
@Suite("Narrow layout")
@MainActor
struct NarrowLayoutTests {
    private func width<Content: View>(of content: Content, proposed: CGFloat) -> CGFloat {
        NSHostingController(rootView: content).sizeThatFits(in: CGSize(width: proposed, height: 600)).width
    }

    private func buttons(_ titles: [String]) -> some View {
        WrappingHStack {
            ForEach(titles, id: \.self) { Button($0) {}.fixedSize() }
        }
    }

    @Test("wrapping stack stays inside the proposed width when its children could not")
    func wrapsInsteadOfOverflowing() {
        let view = buttons(["Accept", "Choose Another Folder", "Dismiss"])
        #expect(width(of: view, proposed: 240) <= 240)
    }

    @Test("wrapping stack keeps one line when there is room and wraps when there is not")
    func wrapsOnlyWhenItMust() {
        func size(_ proposed: CGFloat) -> CGSize {
            NSHostingController(rootView: buttons(["Alpha", "Beta", "Gamma"])).sizeThatFits(in: CGSize(width: proposed, height: 600))
        }
        let roomy = size(600)
        let cramped = size(90)
        #expect(roomy.width <= 600)
        #expect(cramped.height > roomy.height)
    }

    @Test("the record source filter fits a 240 pt pane")
    func recordSourceFilterFitsNarrowPane() {
        let picker = RecordOriginPicker(selection: .constant(.all))
        #expect(width(of: picker, proposed: 240) <= 240)
    }

    @Test("a dictation row fits a 240 pt pane")
    func dictationRowFitsNarrowPane() {
        let record = DictationRecord(
            id: 1, timestamp: "2026-10-15T12:00:00Z", durationSeconds: 9,
            rawText: "Remind me to send the revised term sheet to the lender once legal signs off on the covenant language.",
            appContext: "", wordCount: 18, targetAppName: "Notes", targetAppBundleID: "com.apple.Notes"
        )
        let row = DictationRowView(record: record, timeOnly: "12:00", onCopy: {}, onDelete: {})
        #expect(width(of: row, proposed: 240) <= 240)
    }

    @Test("the stat cards fit a 240 pt pane")
    func statCardsFitNarrowPane() {
        let header = StatsHeaderView(
            dictationStats: DictationStats(
                totalWords: 123_456, totalSessions: 321, averageWordsPerSession: 38,
                averageWPM: 140, currentStreakDays: 12, longestStreakDays: 30
            ),
            meetingStats: MeetingStats(totalWords: 98_765, totalMeetings: 40, averageWPM: 120),
            onSelect: { _ in }
        )
        #expect(width(of: header, proposed: 240) <= 240)
    }
}
