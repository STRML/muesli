import Foundation
import MuesliCore

enum CustomLLMModelCatalogError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidHeaders(String)
    case unauthorized
    case http(Int)
    case unreachable(String)
    case unreadable
    case noModels

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "the endpoint is not a valid URL"
        case .invalidHeaders(let message):
            message
        case .unauthorized:
            "the server refused the API key"
        case .http(let status):
            "the server answered HTTP \(status)"
        case .unreachable(let message):
            "the server is unreachable (\(message))"
        case .unreadable:
            "the server did not return a model list"
        case .noModels:
            "the server lists no models"
        }
    }
}

/// Asks a Custom LLM endpoint which models it serves, so Settings can offer a picker instead of a
/// free-text field. OpenAI-compatible servers and Anthropic both answer `GET .../v1/models`.
enum CustomLLMModelCatalog {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Short: the picker waits on this while the user is looking at Settings.
    static let timeout: TimeInterval = 10

    /// The models URL next to the chat endpoint Muesli already resolves, so every form of the
    /// endpoint the user may type (base URL, `/v1`, the full `chat/completions` path) lists from the same place.
    static func modelsURL(config: AppConfig) -> URL? {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        guard let chat = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: format),
              var components = URLComponents(url: chat, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.suffix(2).elementsEqual(["chat", "completions"]) {
            parts.removeLast(2)
        } else if parts.last == "messages" || parts.last == "completions" {
            parts.removeLast()
        }
        components.path = "/" + (parts + ["models"]).joined(separator: "/")
        components.query = nil
        return components.url
    }

    /// Everything that changes what the endpoint will answer. Picking a model is not part of it.
    static func fingerprint(_ config: AppConfig) -> String {
        let headers = config.customLLMHeaders.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        return [
            config.customLLMURL.trimmingCharacters(in: .whitespacesAndNewlines),
            config.customLLMURLCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            config.customLLMFormat,
            config.customLLMAPIKey,
            config.customLLMAPIKeyCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            headers,
        ].joined(separator: "\u{1F}")
    }

    static func fetch(
        config: AppConfig,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [String] {
        let config = try await config.resolvingEndpointURLCommand(forBackend: MeetingSummaryBackendOption.customLLM.backend)
        guard let url = modelsURL(config: config) else { throw CustomLLMModelCatalogError.invalidEndpoint }
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = ((try? await MeetingSummaryClient.resolveCustomLLMAPIKey(config: config)) ?? config.customLLMAPIKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if format == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            try CustomLLMRequestHeaders.apply(config.customLLMHeaders, to: &request)
        } catch {
            throw CustomLLMModelCatalogError.invalidHeaders(error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CustomLLMModelCatalogError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CustomLLMModelCatalogError.unreadable }
        switch http.statusCode {
        case 200..<300:
            return try parseModelIDs(from: data)
        case 401, 403:
            throw CustomLLMModelCatalogError.unauthorized
        default:
            throw CustomLLMModelCatalogError.http(http.statusCode)
        }
    }

    /// Understands OpenAI, LM Studio and Anthropic (`data[].id`), Ollama (`models[].name`) and a bare array.
    static func parseModelIDs(from data: Data) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw CustomLLMModelCatalogError.unreadable
        }
        let entries: [Any]
        if let list = json as? [Any] {
            entries = list
        } else if let object = json as? [String: Any],
                  let list = (object["data"] as? [Any]) ?? (object["models"] as? [Any]) {
            entries = list
        } else {
            throw CustomLLMModelCatalogError.unreadable
        }

        var seen = Set<String>()
        var ids: [String] = []
        for entry in entries {
            let raw: String?
            if let text = entry as? String {
                raw = text
            } else if let object = entry as? [String: Any] {
                raw = (object["id"] as? String) ?? (object["name"] as? String) ?? (object["model"] as? String)
            } else {
                raw = nil
            }
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { throw CustomLLMModelCatalogError.noModels }
        return ids
    }
}
