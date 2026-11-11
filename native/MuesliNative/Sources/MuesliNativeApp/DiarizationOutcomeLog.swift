import Foundation

enum DiarizationOutcome: Equatable, Sendable {
    case applied(segments: Int, speakers: Int)
    case notLoaded
    case failed(String)

    func line(at date: Date) -> String {
        let stamp = date.formatted(.iso8601)
        switch self {
        case .applied(let segments, let speakers):
            return "\(stamp) applied segments=\(segments) speakers=\(speakers)"
        case .notLoaded:
            return "\(stamp) skipped diarizer_not_loaded"
        case .failed(let description):
            let flattened = description.split(whereSeparator: \.isNewline).joined(separator: " ")
            return "\(stamp) failed \(flattened)"
        }
    }
}

struct DiarizationOutcomeLog {
    let fileURL: URL

    static var shared: DiarizationOutcomeLog {
        DiarizationOutcomeLog(fileURL: AppIdentity.supportDirectoryURL.appendingPathComponent("diarization.log"))
    }

    func record(_ outcome: DiarizationOutcome, at date: Date = Date()) {
        let data = Data((outcome.line(at: date) + "\n").utf8)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("[diarization] could not write outcome log: \(error)\n", stderr)
        }
    }
}
