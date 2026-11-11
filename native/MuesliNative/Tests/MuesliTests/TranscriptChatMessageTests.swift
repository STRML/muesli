import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Transcript chat message parsing")
struct TranscriptChatMessageTests {
    @Test("uncertain recorded-audio speakers retain their explicit labels")
    func uncertainSpeakers() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Multiple speakers: Hello\n[00:00:06] Unknown speaker: Goodbye")
        #expect(messages.map(\.speaker) == ["Multiple speakers", "Unknown speaker"])
        #expect(messages.map(\.text) == ["Hello", "Goodbye"])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("in-room microphone speakers keep their local labels")
    func localSpeakers() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] Local speaker 1: Ahoj.
        [10:00:02] Local speaker 12: Dobrý den.
        [10:00:05] Local speaker: Ano.
        """)
        #expect(messages.map(\.speaker) == ["Local speaker 1", "Local speaker 12", "Local speaker"])
        #expect(messages.map(\.text) == ["Ahoj.", "Dobrý den.", "Ano."])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("timestamped speaker lines become chat messages")
    func timestampedSpeakerLinesBecomeChatMessages() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: Hello there.
        [10:00:04] Speaker 1: Hi back.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].timestamp == "10:00:00")
        #expect(messages[0].speaker == "You")
        #expect(messages[0].text == "Hello there.")
        #expect(messages[0].isUser)
        #expect(messages[1].speaker == "Speaker 1")
        #expect(messages[1].text == "Hi back.")
        #expect(!messages[1].isUser)
    }

    @Test("playback offsets follow wall-clock stamps from a live meeting")
    func liveMeetingOffsets() throws {
        let calendar = Self.utcCalendar
        let playback = try #require(TranscriptPlayback(
            firstTimestamp: "10:46:06", meetingStartTime: "2026-11-11T10:46:06Z", duration: 3000, calendar: calendar
        ))
        #expect(playback.offset(of: "10:46:08") == 2)
        #expect(playback.offset(of: "11:36:05") == 2999)
        #expect(playback.offset(of: "11:40:00") == nil)
        #expect(playback.offset(of: "garbage") == nil)
    }

    @Test("playback reads fractional-second and legacy local start times")
    func legacyStartTimeFormats() throws {
        let fractional = try #require(TranscriptPlayback(
            firstTimestamp: "10:46:06", meetingStartTime: "2026-11-11T10:46:06.250Z", duration: 3000, calendar: Self.utcCalendar
        ))
        #expect(fractional.offset(of: "10:46:08") == 2)

        let local = try #require(TranscriptPlayback(
            firstTimestamp: "10:46:06",
            meetingStartTime: "2026-11-11T\(Self.localClock(10, 46, 6)).000000",
            duration: 3000
        ))
        #expect(local.offset(of: "10:46:08") == 2)
    }

    private static func localClock(_ h: Int, _ m: Int, _ s: Int) -> String {
        String(format: "%02d:%02d:%02d", h, m, s)
    }

    @Test("playback offsets survive midnight and a silent start")
    func midnightAndSilentStart() throws {
        let calendar = Self.utcCalendar
        let playback = try #require(TranscriptPlayback(
            firstTimestamp: "23:58:00", meetingStartTime: "2026-11-11T23:55:00Z", duration: 1800, calendar: calendar
        ))
        #expect(playback.offset(of: "23:58:00") == 180)
        #expect(playback.offset(of: "00:10:00") == 900)
    }

    @Test("a re-transcribed meeting is read as offsets from zero")
    func zeroBasedOffsets() throws {
        let playback = try #require(TranscriptPlayback(
            firstTimestamp: "00:00:03", meetingStartTime: "2026-11-11T10:46:06Z", duration: 3000, calendar: Self.utcCalendar
        ))
        #expect(playback.offset(of: "00:00:03") == 3)
        #expect(playback.offset(of: "00:20:00") == 1200)
    }

    @Test("a first stamp that fits both conventions gives no playback")
    func ambiguousNearMidnight() {
        #expect(TranscriptPlayback(
            firstTimestamp: "00:00:03", meetingStartTime: "2026-11-11T23:55:00Z", duration: 1800, calendar: Self.utcCalendar
        ) == nil)
    }

    @Test("a first stamp that fits no convention gives no playback")
    func unplaceableTranscript() {
        #expect(TranscriptPlayback(
            firstTimestamp: "15:00:00", meetingStartTime: "2026-11-11T10:46:06Z", duration: 3000, calendar: Self.utcCalendar
        ) == nil)
        #expect(TranscriptPlayback(
            firstTimestamp: nil, meetingStartTime: "2026-11-11T10:46:06Z", duration: 3000, calendar: Self.utcCalendar
        ) == nil)
        #expect(TranscriptPlayback(
            firstTimestamp: "10:46:06", meetingStartTime: "2026-11-11T10:46:06Z", duration: 0, calendar: Self.utcCalendar
        ) == nil)
    }

    @Test("a seek request outside the recording is ignored")
    func seekTargetBounds() {
        #expect(TranscriptPlayback.seekTarget(seconds: 12, duration: 100) == 12)
        #expect(TranscriptPlayback.seekTarget(seconds: 100, duration: 100) == 100)
        #expect(TranscriptPlayback.seekTarget(seconds: 101, duration: 100) == nil)
        #expect(TranscriptPlayback.seekTarget(seconds: -1, duration: 100) == nil)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("plain transcript lines are preserved")
    func plainTranscriptLinesArePreserved() {
        let messages = TranscriptChatMessage.messages(from: """
        Product: launch timeline changed.

        This line has no speaker.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].speaker == nil)
        #expect(messages[0].text == "Product: launch timeline changed.")
        #expect(messages[1].text == "This line has no speaker.")
    }
}
