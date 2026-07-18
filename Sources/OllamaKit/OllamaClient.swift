import Foundation

public struct OllamaChatMessage: Equatable, Sendable, Codable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> OllamaChatMessage {
        OllamaChatMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> OllamaChatMessage {
        OllamaChatMessage(role: "user", content: content)
    }

    public static func assistant(_ content: String) -> OllamaChatMessage {
        OllamaChatMessage(role: "assistant", content: content)
    }
}

public struct OllamaChatOptions: @unchecked Sendable {
    public var numPredict: Int?
    public var temperature: Double?
    public var jsonFormat: Bool
    /// Optional JSON Schema object passed as Ollama `format`.
    public var jsonSchema: [String: Any]?

    public init(
        numPredict: Int? = nil,
        temperature: Double? = nil,
        jsonFormat: Bool = false,
        jsonSchema: [String: Any]? = nil
    ) {
        self.numPredict = numPredict
        self.temperature = temperature
        self.jsonFormat = jsonFormat
        self.jsonSchema = jsonSchema
    }
}

public actor OllamaClient {
    private let connectionConfig: OllamaConnectionConfig
    private let urlSession: URLSession

    public init(
        connectionConfig: OllamaConnectionConfig,
        urlSession: URLSession = .shared
    ) {
        self.connectionConfig = connectionConfig
        self.urlSession = urlSession
    }

    public var baseURL: URL {
        connectionConfig.baseURL
    }

    public func chat(
        model: String,
        messages: [OllamaChatMessage],
        options: OllamaChatOptions = .init()
    ) async throws -> String {
        let url = connectionConfig.endpoint("api/chat")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        connectionConfig.applyAuth(to: &request)

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]

        if let jsonSchema = options.jsonSchema {
            body["format"] = jsonSchema
        } else if options.jsonFormat {
            body["format"] = "json"
        }

        var ollamaOptions: [String: Any] = [:]
        if let numPredict = options.numPredict {
            ollamaOptions["num_predict"] = numPredict
        }
        if let temperature = options.temperature {
            ollamaOptions["temperature"] = temperature
        }
        if !ollamaOptions.isEmpty {
            body["options"] = ollamaOptions
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw OllamaError.invalidResponse
        }

        return content
    }

    public func chat(
        model: String,
        system: String? = nil,
        user: String,
        options: OllamaChatOptions = .init()
    ) async throws -> String {
        var messages: [OllamaChatMessage] = []
        if let system, !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(user))
        return try await chat(model: model, messages: messages, options: options)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw OllamaError.notRunning
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OllamaError.httpError(statusCode: http.statusCode, message: message)
        }

        return data
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }

        let message: Message
    }
}
