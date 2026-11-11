import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DiarizationOutcomeLog")
struct DiarizationOutcomeLogTests {
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLog() -> (DiarizationOutcomeLog, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (DiarizationOutcomeLog(fileURL: directory.appendingPathComponent("diarization.log")), directory)
    }

    @Test("each outcome reads as one line with its counts")
    func lineFormat() {
        #expect(DiarizationOutcome.applied(segments: 211, speakers: 3).line(at: moment)
            == "2027-01-15T08:00:00Z applied segments=211 speakers=3")
        #expect(DiarizationOutcome.notLoaded.line(at: moment)
            == "2027-01-15T08:00:00Z skipped diarizer_not_loaded")
        #expect(DiarizationOutcome.failed("timed out").line(at: moment)
            == "2027-01-15T08:00:00Z failed timed out")
    }

    @Test("a multi-line error stays on one line")
    func errorIsFlattened() {
        let line = DiarizationOutcome.failed("first\nsecond\r\nthird").line(at: moment)
        #expect(!line.contains("\n") && !line.contains("\r"))
        #expect(line.hasSuffix("first second third"))
    }

    @Test("records append in order and create the file and its folder")
    func appendsInOrder() throws {
        let (log, directory) = makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        log.record(.notLoaded, at: moment)
        log.record(.applied(segments: 4, speakers: 2), at: moment.addingTimeInterval(60))
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("skipped diarizer_not_loaded"))
        #expect(lines[1].hasSuffix("applied segments=4 speakers=2"))
    }

    @Test("an unwritable location never throws")
    func unwritableLocationIsSilent() {
        let log = DiarizationOutcomeLog(fileURL: URL(fileURLWithPath: "/dev/null/nope/diarization.log"))
        log.record(.notLoaded, at: moment)
    }
}
