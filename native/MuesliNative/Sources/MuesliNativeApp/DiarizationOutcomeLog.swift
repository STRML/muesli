import Foundation

enum DiarizationOutcome: Equatable, Sendable {
    case applied(segments: Int, speakers: Int)
    case notLoaded
    case failed(String)

    func line(source: String, at date: Date) -> String {
        let stamp = date.formatted(.iso8601)
        switch self {
        case .applied(let segments, let speakers):
            return "\(stamp) \(source) applied segments=\(segments) speakers=\(speakers)"
        case .notLoaded:
            return "\(stamp) \(source) skipped diarizer_not_loaded"
        case .failed(let description):
            let flattened = description.split(whereSeparator: \.isNewline).joined(separator: " ")
            return "\(stamp) \(source) failed \(flattened)"
        }
    }
}

struct DiarizationOutcomeLog {
    let fileURL: URL

    static var shared: DiarizationOutcomeLog {
        DiarizationOutcomeLog(fileURL: AppIdentity.supportDirectoryURL.appendingPathComponent("diarization.log"))
    }

    func record(_ outcome: DiarizationOutcome, source: String, at date: Date = Date()) {
        let data = Data((outcome.line(source: source, at: date) + "\n").utf8)
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
