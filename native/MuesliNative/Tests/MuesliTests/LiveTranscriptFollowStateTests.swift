import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Live transcript follow state")
struct LiveTranscriptFollowStateTests {
    @Test("a panel that has just rendered follows new captions")
    func followsAtFirstRender() {
        #expect(LiveTranscriptFollowState().shouldFollowNewContent)
    }

    @Test("a marker inside the visible area follows")
    func markerInsideViewportFollows() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
    }

    @Test("a small scroll up leaves the marker loaded below the screen and stops following")
    func loadedButOffscreenMarkerStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: 460, viewportHeight: 400)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("a marker that is not loaded stops following")
    func unloadedMarkerStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: .infinity, viewportHeight: 400)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("returning to the bottom resumes following")
    func returningToTheBottomResumes() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: 400, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
    }

    @Test("an unmeasured viewport changes nothing")
    func unmeasuredViewportIsIgnored() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 0)
        #expect(state.shouldFollowNewContent)
    }

    @Test("a growing tail scrolls a follower, a cleared or whitespace-only tail does not")
    func tailChangeDecidesWhetherToScroll() {
        #expect(LiveTranscriptFollowState.tailChanged(from: "", to: "hello"))
        #expect(LiveTranscriptFollowState.tailChanged(from: "hello", to: "hello there"))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "hello", to: " hello "))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "hello", to: ""))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "", to: "  "))
    }
}

@Suite("Live transcript scroll-to-bottom toast")
struct LiveTranscriptScrollToBottomToastTests {
    @Test("scrolled up shows the toast and pauses following")
    func scrolledUpShowsToast() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        #expect(state.showsScrollToBottomToast)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("at the bottom the toast is hidden")
    func atBottomHidesToast() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: 390, viewportHeight: 400)
        #expect(!state.showsScrollToBottomToast)
    }

    @Test("content shorter than the viewport never shows the toast")
    func shortContentNeverShows() {
        // Short content keeps the bottom marker inside the viewport.
        var state = LiveTranscriptFollowState()
        #expect(!state.showsScrollToBottomToast)
        state.noteBottomMarker(markerMinY: 120, viewportHeight: 400)
        #expect(!state.showsScrollToBottomToast)
        #expect(state.shouldFollowNewContent)
    }

    @Test("tapping re-pins before the scroll lands")
    func tapRePins() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        state.tapScrollToBottom()
        #expect(!state.showsScrollToBottomToast)
        #expect(state.shouldFollowNewContent)
    }

    @Test("rows arriving while scrolled up keep following paused")
    func newRowsWhileScrolledUpDoNotScroll() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        for y in stride(from: 950, through: 1_150, by: 50) {
            state.noteBottomMarker(markerMinY: CGFloat(y), viewportHeight: 400)
            #expect(!state.shouldFollowNewContent)
        }
        #expect(state.showsScrollToBottomToast)
    }

    @Test("the toast is shown if and only if following is paused, in every reachable state")
    func toastMatchesFollowingInvariant() {
        var state = LiveTranscriptFollowState()
        var disagreements = 0
        func check(_ s: LiveTranscriptFollowState) {
            if s.showsScrollToBottomToast == s.shouldFollowNewContent { disagreements += 1 }
        }
        check(state)
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400); check(state)
        state.noteBottomMarker(markerMinY: 460, viewportHeight: 400); check(state)
        state.noteBottomMarker(markerMinY: .infinity, viewportHeight: 400); check(state)
        state.tapScrollToBottom(); check(state)
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 0); check(state)
        state.noteBottomMarker(markerMinY: 400, viewportHeight: 400); check(state)
        #expect(disagreements == 0)
    }
}
