import AppKit
import SwiftUI
import Testing
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
}
