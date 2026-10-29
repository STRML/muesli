import Foundation
import MuesliCore

extension AppConfig {
    /// Returns a copy whose Ollama, LM Studio and Custom LLM URLs come from their URL commands.
    ///
    /// Each command runs via `/bin/sh -c` before the request, so the endpoint can follow
    /// the network (a LAN host at home, a tailnet host elsewhere). Its trimmed stdout replaces
    /// the saved URL; an empty command, a failure, a timeout or no output keeps the saved URL.
    func resolvingEndpointURLCommands() async throws -> AppConfig {
        var resolved = self
        resolved.ollamaURL = try await CredentialCommandRunner.resolve(command: ollamaURLCommand, fallback: ollamaURL)
        resolved.lmStudioURL = try await CredentialCommandRunner.resolve(command: lmStudioURLCommand, fallback: lmStudioURL)
        resolved.customLLMURL = try await CredentialCommandRunner.resolve(command: customLLMURLCommand, fallback: customLLMURL)
        return resolved
    }
}

extension MeetingTextGenerationRequest {
    func resolvingEndpointURLCommands() async throws -> MeetingTextGenerationRequest {
        var resolved = self
        resolved.config = try await config.resolvingEndpointURLCommands()
        return resolved
    }
}
