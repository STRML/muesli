import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Listing the models a Custom LLM endpoint serves, so Settings can offer a picker instead of a free-text field.
@Suite("Custom LLM model catalog")
struct CustomLLMModelCatalogTests {
    private func config(
        url: String = "http://localhost:8080/v1",
        format: CustomLLMFormat = .openAI,
        apiKey: String = "",
        headers: [CustomLLMRequestHeader] = []
    ) -> AppConfig {
        var config = AppConfig()
        config.customLLMURL = url
        config.customLLMFormat = format.rawValue
        config.customLLMAPIKey = apiKey
        config.customLLMHeaders = headers
        return config
    }

    private func response(_ status: Int = 200, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: Models URL

    @Test("the models URL is derived from whatever form of the endpoint the user typed", arguments: [
        ("http://localhost:8080/v1", "http://localhost:8080/v1/models"),
        ("http://localhost:8080/v1/", "http://localhost:8080/v1/models"),
        ("https://studio.example.ts.net/v1/chat/completions", "https://studio.example.ts.net/v1/models"),
        ("https://studio.example.ts.net", "https://studio.example.ts.net/v1/models"),
        ("https://host.example.net/api", "https://host.example.net/api/v1/models"),
        ("", "http://localhost:8080/v1/models"),
    ])
    func openAIModelsURL(entered: String, expected: String) {
        #expect(CustomLLMModelCatalog.modelsURL(config: config(url: entered))?.absoluteString == expected)
    }

    @Test("Anthropic endpoints list models under /v1/models")
    func anthropicModelsURL() {
        #expect(CustomLLMModelCatalog.modelsURL(config: config(url: "", format: .anthropic))?.absoluteString
            == "https://api.anthropic.com/v1/models")
        #expect(CustomLLMModelCatalog.modelsURL(config: config(url: "https://proxy.example.net/v1/messages", format: .anthropic))?.absoluteString
            == "https://proxy.example.net/v1/models")
    }

    @Test("an endpoint that is not a URL has no models URL")
    func invalidEndpoint() {
        #expect(CustomLLMModelCatalog.modelsURL(config: config(url: "not a url")) == nil)
    }

    // MARK: Parsing

    @Test("OpenAI, LM Studio and Anthropic style lists")
    func parsesDataList() throws {
        let json = #"{"object":"list","data":[{"id":"qwen3-8b","object":"model"},{"id":" llama-3 "},{"id":"qwen3-8b"}]}"#
        #expect(try CustomLLMModelCatalog.parseModelIDs(from: Data(json.utf8)) == ["qwen3-8b", "llama-3"])
    }

    @Test("Ollama style lists and bare arrays")
    func parsesOtherShapes() throws {
        let ollama = #"{"models":[{"name":"llama3:8b"},{"model":"mistral:7b"}]}"#
        #expect(try CustomLLMModelCatalog.parseModelIDs(from: Data(ollama.utf8)) == ["llama3:8b", "mistral:7b"])
        let bare = #"["a","b"]"#
        #expect(try CustomLLMModelCatalog.parseModelIDs(from: Data(bare.utf8)) == ["a", "b"])
    }

    @Test("an empty list and a page that is not JSON are different failures")
    func parseFailures() {
        #expect(throws: CustomLLMModelCatalogError.noModels) {
            try CustomLLMModelCatalog.parseModelIDs(from: Data(#"{"data":[]}"#.utf8))
        }
        #expect(throws: CustomLLMModelCatalogError.unreadable) {
            try CustomLLMModelCatalog.parseModelIDs(from: Data("<html>hello</html>".utf8))
        }
    }

    // MARK: Fetching

    @Test("an OpenAI-compatible request sends the bearer key and any custom headers")
    func sendsAuthAndHeaders() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let models = try await CustomLLMModelCatalog.fetch(
            config: config(apiKey: "sk-test", headers: [CustomLLMRequestHeader(name: "X-Route", value: "studio")]),
            transport: { request in
                captured.set(request)
                return (Data(#"{"data":[{"id":"m1"}]}"#.utf8), self.response(for: request))
            }
        )
        #expect(models == ["m1"])
        let request = try #require(captured.get())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://localhost:8080/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "X-Route") == "studio")
        #expect(request.timeoutInterval <= 15)
    }

    @Test("an Anthropic request sends x-api-key and the version header")
    func anthropicHeaders() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        _ = try await CustomLLMModelCatalog.fetch(
            config: config(url: "", format: .anthropic, apiKey: "ant-key"),
            transport: { request in
                captured.set(request)
                return (Data(#"{"data":[{"id":"claude-x"}]}"#.utf8), self.response(for: request))
            }
        )
        let request = try #require(captured.get())
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "ant-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("no key means no Authorization header, for local servers")
    func noKeyNoHeader() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        _ = try await CustomLLMModelCatalog.fetch(config: config(), transport: { request in
            captured.set(request)
            return (Data(#"{"data":[{"id":"m"}]}"#.utf8), self.response(for: request))
        })
        #expect(captured.get()?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("401 and 403 mean the credentials were refused")
    func unauthorized() async {
        for status in [401, 403] {
            await #expect(throws: CustomLLMModelCatalogError.unauthorized) {
                try await CustomLLMModelCatalog.fetch(config: config(), transport: { request in
                    (Data(), self.response(status, for: request))
                })
            }
        }
    }

    @Test("other HTTP errors carry the status")
    func httpError() async {
        await #expect(throws: CustomLLMModelCatalogError.http(503)) {
            try await CustomLLMModelCatalog.fetch(config: config(), transport: { request in
                (Data(), self.response(503, for: request))
            })
        }
    }

    @Test("a transport failure is reported as the server being unreachable")
    func unreachable() async {
        do {
            _ = try await CustomLLMModelCatalog.fetch(config: config(), transport: { _ in throw URLError(.cannotConnectToHost) })
            Issue.record("expected an error")
        } catch let error as CustomLLMModelCatalogError {
            if case .unreachable = error {} else { Issue.record("wrong error: \(error)") }
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("an invalid endpoint never reaches the network")
    func invalidEndpointNeverFetches() async {
        let called = LockedBox(false)
        await #expect(throws: CustomLLMModelCatalogError.invalidEndpoint) {
            try await CustomLLMModelCatalog.fetch(config: config(url: "not a url"), transport: { request in
                called.set(true)
                return (Data(), self.response(for: request))
            })
        }
        #expect(called.get() == false)
    }

    @Test("a cancelled fetch stays a cancellation, not a failure message")
    func cancellation() async {
        await #expect(throws: CancellationError.self) {
            try await CustomLLMModelCatalog.fetch(config: config(), transport: { _ in throw CancellationError() })
        }
    }

    // MARK: Fingerprint

    @Test("the fingerprint changes with everything that changes the answer, and nothing else")
    func fingerprint() {
        let base = CustomLLMModelCatalog.fingerprint(config())
        #expect(base == CustomLLMModelCatalog.fingerprint(config()))
        #expect(base != CustomLLMModelCatalog.fingerprint(config(url: "http://other:1/v1")))
        #expect(base != CustomLLMModelCatalog.fingerprint(config(format: .anthropic)))
        #expect(base != CustomLLMModelCatalog.fingerprint(config(apiKey: "k")))
        #expect(base != CustomLLMModelCatalog.fingerprint(config(headers: [CustomLLMRequestHeader(name: "X-A", value: "1")])))
        var other = config()
        other.customLLMModel = "something-else"
        #expect(base == CustomLLMModelCatalog.fingerprint(other), "picking a model must not refetch the list")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
