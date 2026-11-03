import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

/// Opt-in check against a real summary endpoint, using an app config file.
/// Run: `MUESLI_LIVE_CONFIG="$HOME/Library/Application Support/MuesliDev/config.json" swift test --filter LiveStudioSummaryTests`
/// It prints lengths and outcomes only, never transcript text or credentials.
@Suite("Live summary endpoint (opt-in)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MUESLI_LIVE_CONFIG"] != nil))
struct LiveStudioSummaryTests {
    private func loadConfig() throws -> AppConfig {
        let path = try #require(ProcessInfo.processInfo.environment["MUESLI_LIVE_CONFIG"])
        var config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Fail fast and visibly instead of retrying for minutes.
        config.meetingSummaryRetryCount = 0
        return config
    }

    private let transcript = """
    [00:00:01] You: Let's review the invoices. Two vendors changed terms this month.
    [00:00:09] Others: Ohlins moved to net 15 and Mauser wants a deposit. I'll send the updated schedule Friday.
    [00:00:20] You: Fine. Approve the rest and flag the tariff line for Jenn.
    """

    @Test("a normal meeting is summarized by the configured endpoint, with the key fetched at call time")
    func normalMeeting() async throws {
        let config = try loadConfig()
        let notes: String
        do {
            notes = try await MeetingSummaryClient.summarize(
                transcript: transcript, meetingTitle: "Invoice review", config: config, isPrivateMeeting: false)
        } catch {
            print("LIVE normal FAILED: \(error.localizedDescription)")
            throw error
        }
        print("LIVE normal: backend=\(PrivateMeetingPolicy.effectiveBackend(of: config)) summaryChars=\(notes.count)")
        #expect(notes.count > 40)
    }

    @Test("a private meeting is summarized when the backend is trusted for private meetings")
    func privateMeetingTrusted() async throws {
        let config = try loadConfig()
        #expect(PrivateMeetingPolicy.allowsBackend(config), "config must trust the selected backend for this check")
        let notes = try await MeetingSummaryClient.summarize(
            transcript: transcript, meetingTitle: "Counsel call", config: config, isPrivateMeeting: true)
        print("LIVE private+trusted: summaryChars=\(notes.count)")
        #expect(notes.count > 40)
    }

    @Test("the same private meeting is refused, with no request, once the trust is removed")
    func privateMeetingUntrusted() async throws {
        var config = try loadConfig()
        config.privateTrustedBackends = []
        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: transcript, meetingTitle: "Counsel call", config: config, isPrivateMeeting: true)
            #expect(Bool(false), "expected a block")
        } catch let error as MeetingSummaryError {
            guard case .privateMeetingBlocked = error else { #expect(Bool(false), "wrong error: \(error)"); return }
            print("LIVE private+untrusted: blocked")
        }
    }
}
