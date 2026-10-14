import Foundation

/// Decides whether a private meeting's content may be sent to a summary backend.
///
/// Nothing is trusted by default. Ollama, LM Studio, and Custom LLM can all point
/// at remote hosts, so the user lists the backends they trust for private meetings.
enum PrivateMeetingPolicy {
    /// The backend id the summary client will actually call for this config:
    /// an empty value means ChatGPT and an unknown value falls through to OpenAI.
    static func effectiveBackend(of config: AppConfig) -> String {
        let raw = config.meetingSummaryBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return MeetingSummaryBackendOption.chatGPT.backend }
        if MeetingSummaryBackendOption.all.contains(where: { $0.backend == raw }) { return raw }
        return MeetingSummaryBackendOption.openAI.backend
    }

    /// True when a private meeting may be sent to the backend `config` selects.
    static func allowsBackend(_ config: AppConfig) -> Bool {
        let trusted = Set(config.privateTrustedBackends.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return trusted.contains(effectiveBackend(of: config))
    }

    /// True when content for this meeting may be sent to the selected backend.
    static func allowsContent(isPrivateMeeting: Bool, config: AppConfig) -> Bool {
        !isPrivateMeeting || allowsBackend(config)
    }

    static let blockedNotice = "Private meeting: summary skipped. Trust this backend for private meetings in Settings to enable it."
}
