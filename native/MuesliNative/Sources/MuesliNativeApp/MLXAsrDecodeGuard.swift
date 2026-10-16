import Foundation

/// Why a decode loop stopped.
enum MLXAsrStopReason: String, Sendable, Equatable {
    /// The model produced its end-of-sequence token. This is the only clean stop.
    case endOfSequence
    /// The duration-scaled token cap was reached; every generated token is kept.
    case tokenCap
    /// The repetition guard fired; the tokens were cut at the first repeat boundary.
    case repetition
}

/// Cancellation for a decode that runs on a dedicated thread, outside any Swift Task.
///
/// `MLXAsrTranscriber` runs each window on its own thread so a multi-second synchronous
/// decode never holds a cooperative-pool thread. `Task.isCancelled` is not visible there,
/// so the transcriber installs a token on the thread and `MLXAsrDecodeGuard.decode` reads it.
enum MLXAsrCancellation {
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private static let threadKey = "muesli.mlxasr.cancellationToken"

    /// Runs `body` with `token` visible to `isCancelled` on the current thread.
    static func withToken<T>(_ token: Token, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        dictionary[threadKey] = token
        defer { dictionary.removeObject(forKey: threadKey) }
        return try body()
    }

    /// True when the current Task or the current thread's token has been cancelled.
    static var isCancelled: Bool {
        Task.isCancelled || (Thread.current.threadDictionary[threadKey] as? Token)?.isCancelled == true
    }
}

/// What a guarded decode loop produced, as token ids.
struct MLXAsrDecodeOutcome: Sendable, Equatable {
    let tokens: [Int]
    let stopReason: MLXAsrStopReason
    /// True when the guard, not the model, ended the loop.
    var guardTripped: Bool { stopReason != .endOfSequence }
}

/// Bounds a model's autoregressive loop so a runaway decode cannot hang a meeting or
/// swallow a chunk. Pure functions; the rules are documented in docs/mlx-asr-backends.md.
///
/// A model port calls `decode(maxTokens:nextToken:)` with its single-token step instead of
/// writing its own loop, which gives it the cap, the repetition guard and the per-token
/// cancellation check without further work. The guard never throws; the only error the loop
/// raises is `CancellationError` (or whatever `nextToken` itself throws).
enum MLXAsrDecodeGuard {
    static let minimumTokenCap = 48
    /// English speech is a few tokens per second; 10 leaves wide headroom.
    static let tokensPerSecond = 10.0
    private static let maximumTokenCap = 100_000

    private static let loopLengths = 3...8
    private static let consecutiveCopies = 4
    private static let windowTokenCount = 64
    private static let windowTrigramLimit = 8

    /// `max(48, ceil(10 * seconds))`. A non-finite or non-positive length gets the floor.
    static func maxTokens(forChunkSeconds seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return minimumTokenCap }
        let scaled = min((seconds * tokensPerSecond).rounded(.up), Double(maximumTokenCap))
        return max(minimumTokenCap, Int(scaled))
    }

    /// If the tail of `tokens` just completed a repetition loop, returns how many leading
    /// tokens to keep. `nil` means no loop.
    ///
    /// - Consecutive rule: for n in 3...8, the last 4n tokens are four copies of one n-gram.
    ///   Keeps the first copy. The shortest period wins.
    /// - Window rule: the 3-gram ending at the last token occurs 8 or more times among the
    ///   last 64 tokens. Keeps everything up to the end of its first occurrence in that window.
    static func loopBoundary(in tokens: [Int]) -> Int? {
        [consecutiveBoundary(tokens), windowBoundary(tokens)].compactMap { $0 }.min()
    }

    private static func consecutiveBoundary(_ tokens: [Int]) -> Int? {
        for n in loopLengths {
            let span = n * consecutiveCopies
            guard tokens.count >= span else { continue }
            let start = tokens.count - span
            let repeated = (0..<(span - n)).allSatisfy { tokens[start + $0] == tokens[start + $0 + n] }
            if repeated { return start + n }
        }
        return nil
    }

    private static func windowBoundary(_ tokens: [Int]) -> Int? {
        let count = tokens.count
        guard count >= 3 else { return nil }
        let (a, b, c) = (tokens[count - 3], tokens[count - 2], tokens[count - 1])
        let windowStart = max(0, count - windowTokenCount)
        var occurrences = 0
        var first: Int?
        for index in windowStart...(count - 3)
        where tokens[index] == a && tokens[index + 1] == b && tokens[index + 2] == c {
            occurrences += 1
            first = first ?? index
        }
        guard occurrences >= windowTrigramLimit, let first else { return nil }
        return first + 3
    }

    /// Runs `nextToken` until it returns `nil` (end of sequence), the cap is reached or the
    /// repetition guard fires. Checks `MLXAsrCancellation.isCancelled` (the Task, or the
    /// transcriber's per-thread token) before every token.
    static func decode(maxTokens: Int, nextToken: () throws -> Int?) throws -> MLXAsrDecodeOutcome {
        guard maxTokens > 0 else { return MLXAsrDecodeOutcome(tokens: [], stopReason: .tokenCap) }
        var tokens: [Int] = []
        tokens.reserveCapacity(min(maxTokens, 1_024))
        while true {
            if MLXAsrCancellation.isCancelled { throw CancellationError() }
            guard let token = try nextToken() else {
                return MLXAsrDecodeOutcome(tokens: tokens, stopReason: .endOfSequence)
            }
            tokens.append(token)
            if let keep = loopBoundary(in: tokens) {
                return MLXAsrDecodeOutcome(tokens: Array(tokens.prefix(keep)), stopReason: .repetition)
            }
            if tokens.count >= maxTokens {
                return MLXAsrDecodeOutcome(tokens: tokens, stopReason: .tokenCap)
            }
        }
    }
}
