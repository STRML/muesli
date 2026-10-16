// Purpose: Pure rules that turn the Live tab's per-chunk caption rows and streaming partials
// into one flowing paragraph per speaker turn. Display only: the saved transcript is untouched.

import Foundation

struct LiveTranscriptParagraph: Identifiable, Equatable {
    struct Segment: Equatable {
        /// Seconds since midnight from the row's `[HH:MM:SS]` stamp; nil when it had none.
        var start: TimeInterval?
        var text: String
    }

    /// First row's id (or a fixed negative id for a tail-only paragraph), so identity survives
    /// rows being appended or revised and SwiftUI keeps unchanged paragraphs untouched.
    let id: Int
    let speaker: String?
    let timestamp: String?
    let isBoundary: Bool
    fileprivate(set) var segments: [Segment]
    /// Still-changing streaming text for this turn; rendered lighter, never part of `committed`.
    fileprivate(set) var tail: String

    var committed: String { segments.map(\.text).joined(separator: " ") }

    var isUser: Bool { speaker?.caseInsensitiveCompare("You") == .orderedSame }
}

enum LiveTranscriptParagraphs {
    /// Rows from one speaker whose silence in between is at most this stay one paragraph.
    static let mergePause: TimeInterval = 3
    /// Past `mergePause`, a paragraph only splits if the previous row ended a sentence, or the
    /// silence reaches this length. Caption rows are cut at VAD boundaries, often mid-sentence.
    static let midSentencePause: TimeInterval = 10
    /// A row that restates one of the last two rows within this long is a revision of it.
    static let revisionWindow: TimeInterval = 8
    /// Soft cap: once a paragraph is this long it splits at the next sentence end.
    static let maxParagraphCharacters = 900
    /// Rows carry only a start time, so a row's end is estimated from its word count.
    static let speechWordsPerSecond: Double = 2.5
    /// Word-overlap (Jaccard) at which two rows of 3+ words count as the same speech revised.
    static let revisionSimilarity = 0.6

    private static let youTailID = -1
    private static let systemTailID = -2

    static func build(
        messages: [TranscriptChatMessage],
        partialYou: String,
        partialOthers: String
    ) -> [LiveTranscriptParagraph] {
        var paragraphs: [LiveTranscriptParagraph] = []
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if isResumeBoundary(message) {
                paragraphs.append(LiveTranscriptParagraph(
                    id: message.id, speaker: nil, timestamp: nil, isBoundary: true, segments: [], tail: ""
                ))
                continue
            }
            let segment = LiveTranscriptParagraph.Segment(start: seconds(message.timestamp), text: text)
            if let last = paragraphs.last, accepts(last, speaker: message.speaker, segment: segment) {
                paragraphs[paragraphs.count - 1].add(segment)
            } else {
                paragraphs.append(LiveTranscriptParagraph(
                    id: message.id, speaker: message.speaker, timestamp: message.timestamp,
                    isBoundary: false, segments: [segment], tail: ""
                ))
            }
        }
        attachTail(partialOthers, speaker: systemSideSpeaker(in: paragraphs), tailID: systemTailID, to: &paragraphs)
        attachTail(partialYou, speaker: "You", tailID: youTailID, to: &paragraphs)
        return paragraphs
    }

    // MARK: - Merge rules

    private static func accepts(
        _ paragraph: LiveTranscriptParagraph,
        speaker: String?,
        segment: LiveTranscriptParagraph.Segment
    ) -> Bool {
        guard !paragraph.isBoundary, sameSpeaker(paragraph.speaker, speaker),
              let last = paragraph.segments.last else { return false }
        if paragraph.revision(by: segment) != nil { return true }
        if paragraph.committed.count >= maxParagraphCharacters, endsSentence(last.text) { return false }
        guard let lastStart = last.start, let start = segment.start else { return true }
        let lastEnd = lastStart + Double(words(last.text).count) / speechWordsPerSecond
        let pause = max(0, start - lastEnd)
        if pause <= mergePause { return true }
        return !endsSentence(last.text) && pause < midSentencePause
    }

    // MARK: - Partial tails

    /// Rule for labelling a system-audio partial: it takes the speaker of the most recent
    /// committed system-side paragraph (anything that is not "You") since the last boundary,
    /// whatever label that is (Others, Speaker N, ...), so the tail continues that turn instead
    /// of opening a second "Others" bubble. With no such paragraph it is "Others".
    private static func systemSideSpeaker(in paragraphs: [LiveTranscriptParagraph]) -> String {
        for paragraph in paragraphs.reversed() {
            if paragraph.isBoundary { break }
            if let speaker = paragraph.speaker, !paragraph.isUser { return speaker }
        }
        return "Others"
    }

    private static func attachTail(
        _ rawTail: String,
        speaker: String,
        tailID: Int,
        to paragraphs: inout [LiveTranscriptParagraph]
    ) {
        let tail = rawTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }
        if let last = paragraphs.last, !last.isBoundary, sameSpeaker(last.speaker, speaker) {
            if let lastText = last.segments.last?.text, isCoveredByCommit(tail, committed: lastText) { return }
            paragraphs[paragraphs.count - 1].tail = tail
        } else {
            paragraphs.append(LiveTranscriptParagraph(
                id: tailID, speaker: speaker, timestamp: nil, isBoundary: false, segments: [], tail: tail
            ))
        }
    }

    /// The commit for this speech already landed; the partial is just the engine catching up.
    private static func isCoveredByCommit(_ tail: String, committed: String) -> Bool {
        let tailWords = words(tail)
        let committedWords = words(committed)
        if tailWords.isEmpty { return true }
        if containsContiguously(committedWords, tailWords) { return true }
        return tailWords.count >= 3 && jaccard(tailWords, committedWords) >= 0.8
    }

    // MARK: - Text helpers

    fileprivate enum Relation { case replaces, redundant }

    fileprivate static func relation(of new: String, to old: String) -> Relation? {
        let newWords = words(new)
        let oldWords = words(old)
        guard !newWords.isEmpty, !oldWords.isEmpty else { return nil }
        if newWords == oldWords { return newWords.count >= 2 ? .replaces : nil }
        if newWords.starts(with: oldWords) { return .replaces }
        if oldWords.starts(with: newWords) { return newWords.count >= 2 ? .redundant : nil }
        if newWords.count >= 3, oldWords.count >= 3, jaccard(newWords, oldWords) >= revisionSimilarity {
            return .replaces
        }
        return nil
    }

    fileprivate static func words(_ text: String) -> [String] {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’%"))
        return text.lowercased()
            .components(separatedBy: keep.inverted)
            .filter { !$0.isEmpty }
    }

    private static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let setA = Set(a), setB = Set(b)
        let union = setA.union(setB).count
        return union == 0 ? 0 : Double(setA.intersection(setB).count) / Double(union)
    }

    private static func containsContiguously(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"')”’]")))
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }

    private static func sameSpeaker(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }

    private static func isResumeBoundary(_ message: TranscriptChatMessage) -> Bool {
        message.speaker == nil
            && message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == MeetingResumePolicy.resumeSeparator.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func seconds(_ timestamp: String?) -> TimeInterval? {
        guard let timestamp else { return nil }
        let parts = timestamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }
}

extension LiveTranscriptParagraph {
    /// How many trailing segments (1 or 2) `new` revises, when it does so close enough in time.
    fileprivate func revision(by new: Segment) -> (count: Int, relation: LiveTranscriptParagraphs.Relation)? {
        for count in 1...min(2, segments.count) {
            let old = segments.suffix(count)
            if let oldStart = old.first?.start, let newStart = new.start,
               abs(newStart - oldStart) > LiveTranscriptParagraphs.revisionWindow { continue }
            let oldText = old.map(\.text).joined(separator: " ")
            if let relation = LiveTranscriptParagraphs.relation(of: new.text, to: oldText) {
                return (count, relation)
            }
        }
        return nil
    }

    fileprivate mutating func add(_ new: Segment) {
        guard let revision = revision(by: new) else {
            segments.append(new)
            return
        }
        guard revision.relation == .replaces else { return }
        segments.removeLast(revision.count)
        segments.append(new)
    }
}

/// Switches a recording meeting to its Live tab once per recording, and never again after the
/// user picks a tab themselves.
struct LiveTabAutoSelect: Equatable {
    private var handledMeetingID: Int64?

    /// True when the caller should select the Live tab now.
    mutating func shouldSelectLive(meetingID: Int64, isRecording: Bool) -> Bool {
        guard isRecording else {
            handledMeetingID = nil
            return false
        }
        guard handledMeetingID != meetingID else { return false }
        handledMeetingID = meetingID
        return true
    }

    mutating func noteUserPick(meetingID: Int64) {
        handledMeetingID = meetingID
    }
}
