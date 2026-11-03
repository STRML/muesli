import Foundation
import Testing
@testable import MuesliNativeApp

/// Failure matrix row 5 (docs/mlx-asr-backends.md).
@Suite("MLX ASR decode guard")
struct MLXAsrDecodeGuardTests {
    /// Feeds `tokens` to the guard and reports how many the loop pulled.
    private func run(_ tokens: [Int], maxTokens: Int = 10_000) throws -> (outcome: MLXAsrDecodeOutcome, pulled: Int) {
        var pulled = 0
        let outcome = try MLXAsrDecodeGuard.decode(maxTokens: maxTokens) {
            defer { pulled += 1 }
            return pulled < tokens.count ? tokens[pulled] : nil
        }
        return (outcome, min(pulled, tokens.count))
    }

    @Test("Token cap is max(48, ceil(10 * seconds)) and ignores bad lengths",
          arguments: [
              (0.5, 48), (4.0, 48), (4.85, 49), (5.0, 50), (10.0, 100), (28.0, 280), (30.0, 300),
              (-3.0, 48), (Double.nan, 48), (Double.infinity, 48),
          ])
    func capScalesWithDuration(seconds: Double, expected: Int) {
        #expect(MLXAsrDecodeGuard.maxTokens(forChunkSeconds: seconds) == expected)
    }

    @Test("Reaching the cap keeps every token and reports tokenCap")
    func capKeepsTokens() throws {
        var next = 0
        let outcome = try MLXAsrDecodeGuard.decode(maxTokens: 5) { defer { next += 1 }; return 1000 + next }
        #expect(outcome.tokens == [1000, 1001, 1002, 1003, 1004])
        #expect(outcome.stopReason == .tokenCap)
        #expect(outcome.guardTripped)
    }

    @Test("End of sequence before the cap is not a guard trip")
    func endOfSequenceIsClean() throws {
        let (outcome, _) = try run(Array(0..<20))
        #expect(outcome.tokens == Array(0..<20))
        #expect(outcome.stopReason == .endOfSequence)
        #expect(!outcome.guardTripped)
    }

    @Test("A 3 to 8 token n-gram repeated four times stops the loop and keeps the first copy",
          arguments: 3...8)
    func repeatedNgramStopsAndTruncates(n: Int) throws {
        let prefix = [100, 101, 102, 103, 104]
        let block = Array(1...n)
        let stream = prefix + Array(repeating: block, count: 10).flatMap { $0 }
        let (outcome, pulled) = try run(stream)
        #expect(outcome.tokens == prefix + block)
        #expect(outcome.stopReason == .repetition)
        #expect(outcome.guardTripped)
        // The loop must stop pulling as soon as the fourth copy completes.
        #expect(pulled == prefix.count + 4 * n)
    }

    @Test("A 3-gram seen eight times in the last 64 tokens stops and keeps up to its first occurrence")
    func windowRuleStopsAndTruncates() throws {
        // Unit = the 3-gram plus a distinct filler token, so no consecutive repeat exists.
        let stream = (0..<12).flatMap { [1, 2, 3, 500 + $0] }
        let (outcome, pulled) = try run(stream)
        #expect(outcome.tokens == [1, 2, 3])
        #expect(outcome.stopReason == .repetition)
        // The eighth occurrence completes on the third token of the eighth unit.
        #expect(pulled == 7 * 4 + 3)
    }

    @Test("Repeats that are legitimate speech do not trip the guard")
    func legitimateRepeatNotTripped() throws {
        let cases: [(String, [Int])] = [
            ("no no no", [7, 7, 7]),
            ("three copies of a 3-gram", [1, 2, 3, 1, 2, 3, 1, 2, 3, 40, 41]),
            ("three copies of an 8-gram", Array(repeating: Array(1...8), count: 3).flatMap { $0 } + [99]),
            ("a 3-gram seven times, spread out",
             (0..<7).flatMap { unit in [1, 2, 3] + (0..<6).map { 1000 + unit * 6 + $0 } }),
            ("long varied text", Array(0..<300)),
        ]
        for (name, stream) in cases {
            let (outcome, _) = try run(stream)
            #expect(outcome.tokens == stream, "\(name)")
            #expect(outcome.stopReason == .endOfSequence, "\(name)")
        }
    }

    @Test("Occurrences older than 64 tokens do not count toward the window rule")
    func windowRuleForgets() throws {
        // One 3-gram every 10 tokens: at most 7 land in any 64-token window.
        let stream = (0..<12).flatMap { unit in [1, 2, 3] + (0..<7).map { 10_000 + unit * 7 + $0 } }
        let (outcome, _) = try run(stream)
        #expect(outcome.tokens == stream)
        #expect(!outcome.guardTripped)
    }

    @Test("The guard never throws on arbitrary token streams")
    func guardNeverThrows() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let length = Int.random(in: 0...400, using: &generator)
            let alphabet = Int.random(in: 1...6, using: &generator)
            let stream = (0..<length).map { _ in Int.random(in: 0..<alphabet, using: &generator) }
            let cap = Int.random(in: 1...120, using: &generator)
            #expect(throws: Never.self) {
                let (outcome, _) = try run(stream, maxTokens: cap)
                #expect(outcome.tokens.count <= cap)
                #expect(outcome.tokens.count <= stream.count)
            }
        }
    }

    @Test("A zero or negative cap returns an empty, tripped result without pulling a token")
    func nonPositiveCap() throws {
        for cap in [0, -4] {
            var pulled = 0
            let outcome = try MLXAsrDecodeGuard.decode(maxTokens: cap) { pulled += 1; return 1 }
            #expect(outcome.tokens.isEmpty)
            #expect(outcome.stopReason == .tokenCap)
            #expect(pulled == 0)
        }
    }

    @Test("Cancellation is checked on every token and is the only error the loop raises")
    func cancellationStopsTheLoop() async {
        let task = Task { () throws -> Int in
            var pulled = 0
            _ = try MLXAsrDecodeGuard.decode(maxTokens: 1_000_000) {
                pulled += 1
                if pulled == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                return pulled
            }
            return pulled
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("A cancellation token on a plain thread stops the loop the same way")
    func tokenCancellationOnDedicatedThread() async {
        let token = MLXAsrCancellation.Token()
        let outcome: Result<Int, Error> = await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Result {
                    try MLXAsrCancellation.withToken(token) {
                        var pulled = 0
                        _ = try MLXAsrDecodeGuard.decode(maxTokens: 1_000_000) {
                            pulled += 1
                            if pulled == 5 { token.cancel() }
                            return pulled
                        }
                        return pulled
                    }
                })
            }
            thread.start()
        }
        do {
            _ = try outcome.get()
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Errors thrown by the model step propagate unchanged")
    func modelErrorsPropagate() {
        struct StepFailure: Error, Equatable {}
        #expect(throws: StepFailure.self) {
            _ = try MLXAsrDecodeGuard.decode(maxTokens: 10) { throw StepFailure() }
        }
    }
}
