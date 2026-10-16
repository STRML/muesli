import Foundation
import Testing
@testable import MuesliNativeApp

private func row(_ id: Int, _ seconds: Int, _ speaker: String?, _ text: String) -> TranscriptChatMessage {
    let stamp = String(format: "10:%02d:%02d", seconds / 60, seconds % 60)
    return TranscriptChatMessage(id: id, timestamp: stamp, speaker: speaker, text: text)
}

private let resumed = TranscriptChatMessage(id: 50, timestamp: nil, speaker: nil, text: "— Resumed —")

private func build(
    _ rows: [TranscriptChatMessage],
    you: String = "",
    others: String = ""
) -> [LiveTranscriptParagraph] {
    LiveTranscriptParagraphs.build(messages: rows, partialYou: you, partialOthers: others)
}

@Suite("Live transcript paragraphs")
struct LiveTranscriptParagraphsTests {
    // MARK: merge gap

    @Test("same speaker within the merge gap becomes one paragraph with one header")
    func sameSpeakerWithinGapMerges() {
        let out = build([
            row(0, 0, "Speaker 1", "Hello there friend."),
            row(1, 3, "Speaker 1", "This is the second sentence."),
        ])
        #expect(out.count == 1)
        #expect(out[0].committed == "Hello there friend. This is the second sentence.")
        #expect(out[0].timestamp == "10:00:00")
    }

    @Test("a sentence end followed by a longer pause starts a new paragraph")
    func sentenceEndPlusPauseSplits() {
        let out = build([
            row(0, 0, "Speaker 1", "Hello there friend."),
            row(1, 20, "Speaker 1", "Totally new thought."),
        ])
        #expect(out.count == 2)
    }

    @Test("a pause after a sentence end that is still short does not split")
    func shortPauseAfterSentenceEndMerges() {
        let out = build([
            row(0, 0, "Speaker 1", "That's why I like it."),
            row(1, 3, "Speaker 1", "I think there's a lot of downside protection."),
        ])
        #expect(out.count == 1)
    }

    @Test("a mid-sentence cut survives a pause that would split after a sentence end")
    func midSentencePauseMerges() {
        let cut = [row(0, 0, "Speaker 1", "And I think the other components that are playing well with this is that this would be a")]
        let a = build(cut + [row(1, 12, "Speaker 1", "very easy deal.")])
        #expect(a.count == 1)
        let b = build(cut + [row(1, 80, "Speaker 1", "very easy deal.")])
        #expect(b.count == 2)
    }

    @Test("rows one to five seconds apart from one speaker read as a single turn")
    func screenshotTurnIsOneParagraph() {
        let out = build([
            row(0, 0, "Speaker 1", "Making 16.4% and are unpromoted, which should align with the project."),
            row(1, 6, "Speaker 1", "Level, which it does because we're just taking that basically free and clear."),
            row(2, 12, "Speaker 1", "So this would be."),
            row(3, 14, "Speaker 1", "A very easy, hopefully sellable deal to LP so."),
            row(4, 18, "Speaker 1", "That's why I like it."),
            row(5, 20, "Speaker 1", "I think there's a lot of downside protection."),
            row(6, 22, "Speaker 1", "I think the basis is great."),
        ])
        #expect(out.count == 1)
    }

    // MARK: speakers

    @Test("different speakers never merge and interleaving keeps arrival order")
    func interleavingSpeakers() {
        let out = build([
            row(0, 0, "You", "Okay."),
            row(1, 1, "Others", "Go ahead."),
            row(2, 2, "You", "Right."),
            row(3, 3, "Speaker 1", "One."),
            row(4, 4, "Speaker 2", "Two."),
        ])
        #expect(out.map(\.speaker) == ["You", "Others", "You", "Speaker 1", "Speaker 2"])
    }

    // MARK: revisions

    @Test("a revised row replaces the text it revises")
    func reviseInPlace() {
        let out = build([
            row(0, 0, "Others", "Rhino would come in with 50% of it."),
            row(1, 2, "Others", "We would come in with 50% of it."),
        ])
        #expect(out.count == 1)
        #expect(out[0].committed == "We would come in with 50% of it.")
    }

    @Test("a longer row that extends the previous one replaces it")
    func extensionReplaces() {
        let out = build([
            row(0, 0, "Others", "So,"),
            row(1, 2, "Others", "So, what basically this means for us is"),
        ])
        #expect(out[0].committed == "So, what basically this means for us is")
    }

    @Test("an identical late repeat keeps one copy")
    func identicalRepeatCollapses() {
        let out = build([
            row(0, 0, "Others", "That works for me."),
            row(1, 1, "Others", "That works for me."),
        ])
        #expect(out[0].committed == "That works for me.")
    }

    @Test("a shorter prefix arriving late does not truncate the paragraph")
    func shorterPrefixKeepsLongerText() {
        let out = build([
            row(0, 0, "Others", "We would come in with half of it."),
            row(1, 1, "Others", "We would come in"),
        ])
        #expect(out[0].committed == "We would come in with half of it.")
    }

    @Test("different content from the same speaker is appended, not treated as a revision")
    func differentContentAppends() {
        let out = build([
            row(0, 0, "Speaker 1", "I think the basis is great."),
            row(1, 3, "Speaker 1", "I think it's a cash yield, very nice play."),
        ])
        #expect(out[0].committed == "I think the basis is great. I think it's a cash yield, very nice play.")
    }

    @Test("the same short row far outside the revision window is a real repeat")
    func repeatOutsideWindowKept() {
        let out = build([
            row(0, 0, "You", "Yes, absolutely."),
            row(1, 30, "You", "Yes, absolutely."),
        ])
        #expect(out.map(\.committed).joined(separator: " ") == "Yes, absolutely. Yes, absolutely.")
    }

    // MARK: partial tails

    @Test("an identical partial twice produces identical output")
    func partialIdempotent() {
        let rows = [row(0, 0, "Others", "Hello there friend.")]
        #expect(build(rows, others: "and then") == build(rows, others: "and then"))
    }

    @Test("a revised partial replaces the tail instead of adding a paragraph")
    func partialRevisedMidSentence() {
        let rows = [row(0, 0, "Others", "Hello there friend.")]
        let first = build(rows, others: "we would come")
        let second = build(rows, others: "we would come in with 50%")
        #expect(first.count == 1 && second.count == 1)
        #expect(second[0].tail == "we would come in with 50%")
    }

    @Test("a partial attaches to its speaker's open paragraph under the diarized label")
    func partialAttachesToDiarizedSpeaker() {
        let out = build([row(0, 0, "Speaker 1", "I think the basis is great.")], others: "sort of like a socializat")
        #expect(out.count == 1)
        #expect(out[0].speaker == "Speaker 1")
        #expect(out[0].tail == "sort of like a socializat")
    }

    @Test("with no committed system speech a system partial is labelled Others")
    func partialDefaultsToOthers() {
        let out = build([row(0, 0, "You", "Hi.")], others: "hello")
        #expect(out.map(\.speaker) == ["You", "Others"])
        #expect(out[1].committed.isEmpty && out[1].tail == "hello")
    }

    @Test("a system partial after a You turn takes the latest system-side label")
    func partialLabelSkipsYou() {
        let out = build([
            row(0, 0, "Speaker 2", "Go on."),
            row(1, 4, "You", "Sure."),
        ], others: "so then")
        #expect(out.map(\.speaker) == ["Speaker 2", "You", "Speaker 2"])
        #expect(out.last?.tail == "so then")
    }

    @Test("a You partial attaches to the You paragraph")
    func youPartialAttaches() {
        let out = build([row(0, 0, "You", "Let me explain.")], you: "so the thing is")
        #expect(out.count == 1)
        #expect(out[0].tail == "so the thing is")
    }

    @Test("a partial already contained in the last commit is hidden")
    func commitCoversPartial() {
        let out = build([row(0, 0, "Others", "We would come in with 50% of it.")], others: "we would come in")
        #expect(out.count == 1)
        #expect(out[0].tail.isEmpty)
    }

    @Test("a partial that is new speech after the last commit stays visible")
    func partialNewSpeechVisible() {
        let out = build([row(0, 0, "Others", "We would come in")], others: "with fifty percent of it")
        #expect(out[0].tail == "with fifty percent of it")
    }

    // MARK: degenerate input

    @Test("blank rows and blank partials produce nothing")
    func blankInput() {
        let out = build([row(0, 0, "You", "   "), row(1, 1, "Others", "")], you: " \n", others: "  ")
        #expect(out.isEmpty)
    }

    @Test("out-of-order timestamps neither crash nor reorder arrival order")
    func outOfOrderTimestamps() {
        let out = build([
            row(0, 30, "Speaker 1", "First arrived."),
            row(1, 10, "Speaker 1", "Second arrived with an earlier stamp."),
        ])
        #expect(out.count == 1)
        #expect(out[0].committed == "First arrived. Second arrived with an earlier stamp.")
    }

    @Test("a single very long turn is split at a sentence end once it is long enough")
    func longTurnSplits() {
        let rows = (0..<60).map { row($0, $0 * 4, "Speaker 1", "Alpha\($0) bravo\($0) charlie\($0) delta\($0) echo\($0) foxtrot\($0) golf\($0) hotel\($0).") }
        let out = build(rows)
        #expect(out.count > 1)
        let rowLength = rows[0].text.count + 1
        let limit = LiveTranscriptParagraphs.maxParagraphCharacters + rowLength
        #expect(out.allSatisfy { $0.committed.count <= limit })
        #expect(out.reduce(0) { $0 + $1.segments.count } == 60)
    }

    // MARK: resumed boundary

    @Test("a Resumed marker is a boundary: no merging across it, and it stays a row")
    func resumedBoundary() {
        let out = build([
            row(0, 0, "You", "Before the break"),
            resumed,
            row(1, 2, "You", "after the break."),
        ])
        #expect(out.count == 3)
        #expect(out[1].isBoundary)
        #expect(out[0].committed == "Before the break")
        #expect(out[2].committed == "after the break.")
    }

    @Test("a revision never reaches across a Resumed boundary")
    func revisionStopsAtBoundary() {
        let out = build([
            row(0, 0, "You", "Same words here."),
            resumed,
            row(1, 1, "You", "Same words here."),
        ])
        #expect(out.filter { !$0.isBoundary }.count == 2)
    }

    @Test("a partial straight after a boundary starts its own paragraph")
    func partialAfterBoundary() {
        let out = build([row(0, 0, "You", "Before."), resumed], you: "after")
        #expect(out.count == 3)
        #expect(out[1].isBoundary && out[1].tail.isEmpty)
        #expect(out[2].tail == "after")
    }

    // MARK: identity

    @Test("paragraph identity is stable as rows are appended")
    func stableIdentity() {
        let a = build([row(0, 0, "Speaker 1", "Hello there friend.")])
        let b = build([row(0, 0, "Speaker 1", "Hello there friend."), row(1, 2, "Speaker 1", "More.")])
        #expect(a[0].id == b[0].id)
    }
}

private func select(_ s: inout LiveTabAutoSelect, _ id: Int64, _ isRecording: Bool) -> Bool {
    s.shouldSelectLive(meetingID: id, isRecording: isRecording)
}

@Suite("Live tab auto-selection")
struct LiveTabAutoSelectTests {
    @Test("a recording that starts while viewed switches to Live once")
    func switchesOnStart() {
        var s = LiveTabAutoSelect()
        #expect(!select(&s, 1, false))
        #expect(select(&s, 1, true))
        #expect(!select(&s, 1, true))
    }

    @Test("opening an already recording meeting switches to Live")
    func switchesOnOpen() {
        var s = LiveTabAutoSelect()
        #expect(select(&s, 7, true))
    }

    @Test("a manual tab pick during the recording is never overridden")
    func userPickSticks() {
        var s = LiveTabAutoSelect()
        #expect(select(&s, 1, true))
        s.noteUserPick(meetingID: 1)
        #expect(!select(&s, 1, true))
    }

    @Test("a pick made before the first evaluation still wins")
    func earlyPickSticks() {
        var s = LiveTabAutoSelect()
        s.noteUserPick(meetingID: 1)
        #expect(!select(&s, 1, true))
    }

    @Test("stopping leaves the tab alone and re-arms for the next recording")
    func stopThenResume() {
        var s = LiveTabAutoSelect()
        #expect(select(&s, 1, true))
        s.noteUserPick(meetingID: 1)
        #expect(!select(&s, 1, false))
        #expect(select(&s, 1, true))
    }

    @Test("viewing a different recording meeting switches for that meeting")
    func differentMeeting() {
        var s = LiveTabAutoSelect()
        #expect(select(&s, 1, true))
        s.noteUserPick(meetingID: 1)
        #expect(select(&s, 2, true))
    }
}
