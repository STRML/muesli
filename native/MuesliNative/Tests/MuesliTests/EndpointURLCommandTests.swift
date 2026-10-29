import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI
@testable import MuesliNativeApp

/// Answers any request to the two test hosts and records which host each request reached.
private final class EndpointURLCommandURLProtocol: URLProtocol {
    static let savedHost = "saved.urlcommand.test"
    static let commandHost = "command.urlcommand.test"

    private static let lock = NSLock()
    private static var hosts: [String] = []

    static func install() {
        lock.lock()
        hosts = []
        lock.unlock()
        URLProtocol.registerClass(Self.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(Self.self)
    }

    static var recordedHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    override class func canInit(with request: URLRequest) -> Bool {
        [savedHost, commandHost].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.hosts.append(url.host ?? "")
        Self.lock.unlock()
        let body: String
        if url.path.hasSuffix("/api/chat") {
            body = #"{"message":{"content":"OK"}}"#
        } else if url.path.hasSuffix("/models") {
            body = #"{"data":[{"id":"command-model"}]}"#
        } else {
            body = #"{"choices":[{"message":{"content":"OK"}}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Endpoint URL commands", .serialized)
struct EndpointURLCommandTests {
    private static let saved = "https://\(EndpointURLCommandURLProtocol.savedHost)/v1"
    private static let command = "printf 'https://\(EndpointURLCommandURLProtocol.commandHost)/v1\\n'"

    @Test("URL commands persist under snake_case keys")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.customLLMURLCommand = "/usr/local/bin/custom-url"
        config.ollamaURLCommand = "/usr/local/bin/ollama-url"
        config.lmStudioURLCommand = "/usr/local/bin/lmstudio-url"
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["custom_llm_url_command"] as? String == "/usr/local/bin/custom-url")
        #expect(json["ollama_url_command"] as? String == "/usr/local/bin/ollama-url")
        #expect(json["lmstudio_url_command"] as? String == "/usr/local/bin/lmstudio-url")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.customLLMURLCommand == "/usr/local/bin/custom-url")
        #expect(decoded.ollamaURLCommand == "/usr/local/bin/ollama-url")
        #expect(decoded.lmStudioURLCommand == "/usr/local/bin/lmstudio-url")
    }

    @Test("app summaries send to the URL the command prints; the CLI never runs it",
          arguments: ["custom_llm", "ollama", "lmstudio"])
    func summaryUsesCommandURL(backend: String) async throws {
        EndpointURLCommandURLProtocol.install()
        defer { EndpointURLCommandURLProtocol.uninstall() }
        let config = Self.config(backend: backend, command: Self.command)

        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "OK")
        let appHosts = EndpointURLCommandURLProtocol.recordedHosts
        #expect(!appHosts.isEmpty)
        #expect(appHosts.allSatisfy { $0 == EndpointURLCommandURLProtocol.commandHost })

        // muesli-cli executes no configured commands, so it keeps the saved URL.
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(config))
        #expect(try await CLISummaryClient.summarize(transcript: "Transcript", title: "Test", config: cliConfig) == "OK")
        #expect(EndpointURLCommandURLProtocol.recordedHosts.dropFirst(appHosts.count)
            .allSatisfy { $0 == EndpointURLCommandURLProtocol.savedHost })
    }

    @Test("a failing or silent command falls back to the saved URL", arguments: ["exit 3", "printf ''"])
    func unusableCommandFallsBack(command: String) async throws {
        EndpointURLCommandURLProtocol.install()
        defer { EndpointURLCommandURLProtocol.uninstall() }
        var config = Self.config(backend: "custom_llm", command: command)
        config.customLLMURL = "https://\(EndpointURLCommandURLProtocol.commandHost)/v1"

        #expect(try await MeetingSummaryClient.summarize(transcript: "Transcript", meetingTitle: "Test", config: config) == "OK")
        #expect(EndpointURLCommandURLProtocol.recordedHosts == [EndpointURLCommandURLProtocol.commandHost])
    }

    @Test("titles, cleanup, meeting chat and the model list use the command URL")
    func otherCustomLLMRequestsUseCommandURL() async throws {
        EndpointURLCommandURLProtocol.install()
        defer { EndpointURLCommandURLProtocol.uninstall() }
        let config = Self.config(backend: "custom_llm", command: Self.command)

        #expect(await MeetingSummaryClient.generateTitle(transcript: "Transcript", config: config) == "OK")
        #expect(try await TranscriptCleanupClient.generate(
            systemPrompt: "Clean.", userPrompt: "raw", backend: .hosted(.customLLM),
            model: "custom-model", config: config
        ) == "OK")
        #expect(try await MeetingTextGenerationClient().generate(
            MeetingTextGenerationRequest(system: "System", user: "User", config: config)
        ) == "OK")
        #expect(try await CustomLLMModelCatalog.fetch(config: config) == ["command-model"])

        let hosts = EndpointURLCommandURLProtocol.recordedHosts
        #expect(hosts.count == 4)
        #expect(hosts.allSatisfy { $0 == EndpointURLCommandURLProtocol.commandHost })
    }

    @Test("the model list refetches when the URL command changes")
    func fingerprintIncludesURLCommand() {
        var config = AppConfig()
        let before = CustomLLMModelCatalog.fingerprint(config)
        config.customLLMURLCommand = Self.command
        #expect(CustomLLMModelCatalog.fingerprint(config) != before)
    }

    private static func config(backend: String, command: String) -> AppConfig {
        var config = AppConfig()
        config.meetingSummaryBackend = backend
        config.meetingSummaryRetryCount = 0
        config.customLLMURL = saved
        config.customLLMModel = "custom-model"
        config.lmStudioURL = saved
        config.lmStudioModel = "local-model"
        config.ollamaURL = "https://\(EndpointURLCommandURLProtocol.savedHost)"
        config.ollamaModel = "local-model"
        switch backend {
        case "ollama":
            config.ollamaURLCommand = command.replacingOccurrences(of: "/v1", with: "")
        case "lmstudio":
            config.lmStudioURLCommand = command
        default:
            config.customLLMURLCommand = command
        }
        return config
    }
}
