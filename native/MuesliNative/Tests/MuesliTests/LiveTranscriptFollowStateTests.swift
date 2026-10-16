import Testing
@testable import MuesliNativeApp

@Suite("Live transcript follow state")
struct LiveTranscriptFollowStateTests {
    @Test("a panel that has just rendered follows new captions")
    func followsAtFirstRender() {
        #expect(LiveTranscriptFollowState().shouldFollowNewContent)
    }

    @Test("scrolling up stops the panel from pulling the reader down")
    func scrollingUpStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: true)
        state.noteBottomMarker(visible: false)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("returning to the bottom resumes following")
    func returningToTheBottomResumes() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        state.noteBottomMarker(visible: true)
        #expect(state.shouldFollowNewContent)
    }
}

@Suite("Live transcript scroll-to-bottom toast")
struct LiveTranscriptScrollToBottomToastTests {
    @Test("scrolled up shows the toast and pauses following")
    func scrolledUpShowsToast() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        let scrolls = state.beginFollowScroll()
        #expect(state.showsScrollToBottomToast)
        #expect(!scrolls)
    }

    @Test("at the bottom the toast is hidden")
    func atBottomHidesToast() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        state.noteBottomMarker(visible: true)
        #expect(!state.showsScrollToBottomToast)
    }

    @Test("content shorter than the viewport never shows the toast")
    func shortContentNeverShows() {
        // Short content keeps the bottom marker on screen, so it only ever reports visible.
        var state = LiveTranscriptFollowState()
        #expect(!state.showsScrollToBottomToast)
        state.noteBottomMarker(visible: true)
        let scrolls = state.beginFollowScroll()
        #expect(!state.showsScrollToBottomToast)
        #expect(scrolls)
    }

    @Test("tapping re-pins, and a following partial keeps following")
    func tapRePins() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        state.tapScrollToBottom()
        #expect(!state.showsScrollToBottomToast)
        state.noteBottomMarker(visible: true)
        let scrolls = state.beginFollowScroll()
        #expect(scrolls)
    }

    @Test("new rows arriving while scrolled up never request a scroll")
    func newRowsWhileScrolledUpDoNotScroll() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        var requested = 0
        for _ in 0..<5 where state.beginFollowScroll() { requested += 1 }
        #expect(requested == 0)
        #expect(state.showsScrollToBottomToast)
    }

    @Test("growth that pushes the marker off screen mid-follow does not read as scrolling up")
    func growthDuringFollowKeepsPin() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: true)
        let first = state.beginFollowScroll()
        state.noteBottomMarker(visible: false)
        #expect(first)
        #expect(!state.showsScrollToBottomToast)
        state.finishFollowScroll()
        state.noteBottomMarker(visible: true)
        let second = state.beginFollowScroll()
        #expect(second)
    }

    @Test("the toast is shown if and only if following is paused, in every reachable state")
    func toastMatchesFollowingInvariant() {
        var state = LiveTranscriptFollowState()
        var disagreements = 0
        func check(_ s: LiveTranscriptFollowState) {
            if s.showsScrollToBottomToast == s.shouldFollowNewContent { disagreements += 1 }
        }
        check(state)
        state.noteBottomMarker(visible: true); check(state)
        _ = state.beginFollowScroll(); check(state)
        state.noteBottomMarker(visible: false); check(state)
        state.finishFollowScroll(); check(state)
        state.noteBottomMarker(visible: false); check(state)
        _ = state.beginFollowScroll(); check(state)
        state.tapScrollToBottom(); check(state)
        _ = state.beginFollowScroll(); check(state)
        state.noteBottomMarker(visible: true); check(state)
        state.finishFollowScroll(); check(state)
        #expect(disagreements == 0)
    }
}
