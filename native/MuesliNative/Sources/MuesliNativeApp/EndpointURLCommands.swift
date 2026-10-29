import Foundation
import MuesliCore

extension AppConfig {
    /// The URL field and its URL command for each backend that has a configurable endpoint.
    private static let endpointURLFields: [String: (url: WritableKeyPath<AppConfig, String>, command: KeyPath<AppConfig, String>)] = [
        MeetingSummaryBackendOption.ollama.backend: (\.ollamaURL, \.ollamaURLCommand),
        MeetingSummaryBackendOption.lmStudio.backend: (\.lmStudioURL, \.lmStudioURLCommand),
        MeetingSummaryBackendOption.customLLM.backend: (\.customLLMURL, \.customLLMURLCommand),
    ]

    /// Returns a copy whose URL for `backend` comes from that backend's URL command.
    ///
    /// The command runs via `/bin/sh -c` before the request, so the endpoint can follow
    /// the network (a LAN host at home, a tailnet host elsewhere). Its trimmed stdout replaces
    /// the saved URL; an empty command, a failure, a timeout or no output keeps the saved URL.
    /// Only the named backend's command runs; other backends' commands are left alone.
    func resolvingEndpointURLCommand(forBackend backend: String) async throws -> AppConfig {
        guard let fields = Self.endpointURLFields[backend] else { return self }
        var resolved = self
        resolved[keyPath: fields.url] = try await CredentialCommandRunner.resolve(
            command: self[keyPath: fields.command],
            fallback: self[keyPath: fields.url]
        )
        return resolved
    }

    /// Resolves the URL command of the meeting summary backend, which summaries, titles and chat use.
    func resolvingSummaryEndpointURLCommand() async throws -> AppConfig {
        try await resolvingEndpointURLCommand(forBackend: MeetingSummaryBackendOption.resolved(meetingSummaryBackend).backend)
    }
}

extension MeetingTextGenerationRequest {
    func resolvingEndpointURLCommand() async throws -> MeetingTextGenerationRequest {
        var resolved = self
        resolved.config = try await config.resolvingSummaryEndpointURLCommand()
        return resolved
    }
}
