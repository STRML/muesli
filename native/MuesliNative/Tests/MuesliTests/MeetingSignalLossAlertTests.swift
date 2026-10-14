import Foundation
import Testing
@testable import MuesliNativeApp

/// What the user is told when the call a recording follows goes away: a toast that comes back
/// every few minutes and a sidebar alert that stays until it is answered.
@Suite("Meeting signal-loss alert")
struct MeetingSignalLossAlertTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let quiet: TimeInterval = 45
    private var reoffer: TimeInterval { MeetingSignalLossPromptState.reofferInterval }

    private func evaluate(_ state: inout MeetingSignalLossPromptState, after seconds: TimeInterval) -> MeetingSignalLossAction {
        state.evaluateSignalLoss(now: t0.addingTimeInterval(seconds), transcriptQuietPeriod: quiet)
    }

    @Test("the first loss raises the alert and the toast together")
    func firstLoss() {
        var state = MeetingSignalLossPromptState()
        #expect(!state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 0) == .raiseAlertAndToast)
        #expect(state.isCallEndedAlertActive)
    }

    @Test("the toast is offered again every five minutes while the signal stays lost")
    func reofferCadence() {
        var state = MeetingSignalLossPromptState()
        #expect(reoffer == 300)
        _ = evaluate(&state, after: 0)
        #expect(evaluate(&state, after: 3) == .none)
        #expect(evaluate(&state, after: 299) == .none)
        #expect(evaluate(&state, after: 300) == .reofferToast)
        // The cadence restarts from the re-offer, not from the first loss.
        #expect(evaluate(&state, after: 599) == .none)
        #expect(evaluate(&state, after: 600) == .reofferToast)
        #expect(state.isCallEndedAlertActive)
    }

    @Test("an explicit dismissal ends the alert and every later offer for this recording")
    func dismissal() {
        var state = MeetingSignalLossPromptState()
        _ = evaluate(&state, after: 0)
        state.markDismissedByUser()
        #expect(!state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 10_000) == .none)
        #expect(!state.isCallEndedAlertActive)

        // Not even a recovery and a second loss brings it back.
        state.markSourceRecovered()
        #expect(evaluate(&state, after: 20_000) == .none)
        #expect(!state.isCallEndedAlertActive)

        state.resetForRecording()
        #expect(evaluate(&state, after: 30_000) == .raiseAlertAndToast)
    }

    @Test("a toast that was only auto-dismissed does not stop the offers or clear the alert")
    func missedToast() {
        var state = MeetingSignalLossPromptState()
        _ = evaluate(&state, after: 0)
        // 30 s later the toast has gone away on its own: nothing is recorded, the alert stays.
        #expect(evaluate(&state, after: 31) == .none)
        #expect(state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 300) == .reofferToast)
    }

    @Test("the call coming back clears the alert, and a second loss raises it at once")
    func recovery() {
        var state = MeetingSignalLossPromptState()
        _ = evaluate(&state, after: 0)
        state.markSourceRecovered()
        #expect(!state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 60) == .raiseAlertAndToast)
        #expect(state.isCallEndedAlertActive)
    }

    @Test("transcript activity defers the first alert and every re-offer, but never clears a raised alert")
    func transcriptActivity() {
        var state = MeetingSignalLossPromptState()
        // The speakers are still producing words (a video, say): hold back.
        state.noteTranscriptActivity(now: t0)
        #expect(evaluate(&state, after: 10) == .none)
        #expect(!state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 45) == .raiseAlertAndToast)

        // Words arrive just before a re-offer is due: the re-offer waits, the alert stays.
        state.noteTranscriptActivity(now: t0.addingTimeInterval(340))
        #expect(evaluate(&state, after: 345) == .none)
        #expect(state.isCallEndedAlertActive)
        #expect(evaluate(&state, after: 385) == .reofferToast)
    }

    @Test("the user's own voice is not evidence that the call is still going")
    func ownVoiceDoesNotDeferTheAlert() {
        var state = MeetingSignalLossPromptState()
        // The call ended and the user kept talking at the desk: the mic keeps producing words.
        state.noteTranscriptActivity(from: "You", now: t0)
        #expect(evaluate(&state, after: 10) == .raiseAlertAndToast)

        // Remote speech still holds the alert back.
        var remote = MeetingSignalLossPromptState()
        remote.noteTranscriptActivity(from: "Others", now: t0)
        #expect(evaluate(&remote, after: 10) == .none)
        var labelled = MeetingSignalLossPromptState()
        labelled.noteTranscriptActivity(from: "Speaker 2", now: t0)
        #expect(evaluate(&labelled, after: 10) == .none)
    }

    @Test("a new recording starts clean")
    func reset() {
        var state = MeetingSignalLossPromptState()
        state.noteTranscriptActivity(now: t0)
        _ = evaluate(&state, after: 100)
        state.resetForRecording()
        #expect(state == MeetingSignalLossPromptState())
    }

    // MARK: Sidebar

    private let titles: [Int64: String] = [7: "Reed - Bi-Weekly Check-In"]

    @Test("the sidebar item turns into an amber stop prompt while the call-ended alert is active")
    func sidebarAlert() throws {
        let item = try #require(ActiveRecordingSidebarItem.make(
            activeMeetingID: 7, isPaused: false, isCallEnded: true, titleFor: { titles[$0] }
        ))
        #expect(item.isCallEnded)
        #expect(item.statusLabel == "Call ended?")
        #expect(item.stopActionLabel == "Stop")
        #expect(item.isPulsing)
        #expect(item.accessibilityLabel == "Call ended? Stop: Reed - Bi-Weekly Check-In")
        #expect(item.title == "Reed - Bi-Weekly Check-In")
        #expect(item.meetingID == 7)
    }

    @Test("a paused recording with the alert still asks, and keeps the dot moving")
    func sidebarAlertWhilePaused() throws {
        let item = try #require(ActiveRecordingSidebarItem.make(
            activeMeetingID: 7, isPaused: true, isCallEnded: true, titleFor: { titles[$0] }
        ))
        #expect(item.statusLabel == "Call ended?")
        #expect(item.isPulsing)
    }

    @Test("without the alert the item has no stop action")
    func sidebarNoAlert() throws {
        let item = try #require(ActiveRecordingSidebarItem.make(
            activeMeetingID: 7, isPaused: false, titleFor: { titles[$0] }
        ))
        #expect(!item.isCallEnded)
        #expect(item.stopActionLabel == nil)
        #expect(item.accessibilityLabel == "Recording: Reed - Bi-Weekly Check-In")
        #expect(ActiveRecordingSidebarItem.make(
            activeMeetingID: nil, isPaused: false, isCallEnded: true, titleFor: { titles[$0] }
        ) == nil)
    }
}
