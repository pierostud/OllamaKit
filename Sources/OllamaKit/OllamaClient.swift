import Foundation

public struct OllamaChatMessage: Equatable, Sendable {
    public var role: String
    public var content: String
    public var toolCalls: [OllamaToolCall]?
    public var toolName: String?

    public init(
        role: String,
        content: String,
        toolCalls: [OllamaToolCall]? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
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

    public static func assistant(content: String = "", toolCalls: [OllamaToolCall]) -> OllamaChatMessage {
        OllamaChatMessage(role: "assistant", content: content, toolCalls: toolCalls)
    }

    public static func tool(name: String, content: String) -> OllamaChatMessage {
        OllamaChatMessage(role: "tool", content: content, toolName: name)
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
            "messages": messages.map { Self.encodeBasicMessage($0) },
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

    /// Chat with tool calling. Do not pass `jsonFormat` / `jsonSchema` in options — Ollama ignores tools when structured output is enabled.
    public func chatWithTools(
        model: String,
        messages: [OllamaChatMessage],
        tools: [OllamaToolDefinition],
        options: OllamaChatOptions = .init()
    ) async throws -> OllamaChatResponse {
        let url = connectionConfig.endpoint("api/chat")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        connectionConfig.applyAuth(to: &request)

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages.map { Self.encodeToolMessage($0) },
            "tools": tools.map { $0.toRequestDictionary() },
        ]

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
        let decoded = try JSONDecoder().decode(ToolChatResponse.self, from: data)
        let toolCalls = Self.decodeToolCalls(from: decoded.message.toolCalls)
        let content = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty || !toolCalls.isEmpty else {
            throw OllamaError.invalidResponse
        }

        return OllamaChatResponse(
            content: content,
            toolCalls: toolCalls,
            doneReason: decoded.doneReason
        )
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

    private static func encodeBasicMessage(_ message: OllamaChatMessage) -> [String: Any] {
        ["role": message.role, "content": message.content]
    }

    private static func encodeToolMessage(_ message: OllamaChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role]
        if !message.content.isEmpty || message.toolCalls == nil {
            dict["content"] = message.content
        }
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls.map { encodeToolCallForRequest($0) }
        }
        if let toolName = message.toolName {
            dict["tool_name"] = toolName
        }
        return dict
    }

    private static func encodeToolCallForRequest(_ call: OllamaToolCall) -> [String: Any] {
        var function: [String: Any] = [
            "name": call.name,
            "arguments": parseArgumentsJSON(call.arguments) ?? [:],
        ]
        if let index = call.index {
            function["index"] = index
        }
        var dict: [String: Any] = [
            "type": "function",
            "function": function,
        ]
        if let id = call.id {
            dict["id"] = id
        }
        return dict
    }

    private static func parseArgumentsJSON(_ arguments: String) -> Any? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func decodeToolCalls(from raw: [ToolChatResponse.ToolCall]?) -> [OllamaToolCall] {
        guard let raw else { return [] }
        return raw.compactMap { item in
            let name = item.function.name
            guard !name.isEmpty else { return nil }
            let arguments: String
            switch item.function.arguments {
            case .string(let value):
                arguments = value
            case .object(let value):
                let plain = value.mapValues(\.value)
                if let data = try? JSONSerialization.data(withJSONObject: plain),
                   let string = String(data: data, encoding: .utf8) {
                    arguments = string
                } else {
                    arguments = "{}"
                }
            case .none:
                arguments = "{}"
            }
            return OllamaToolCall(
                id: item.id,
                index: item.function.index,
                name: name,
                arguments: arguments
            )
        }
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }

        let message: Message
    }

    private struct ToolChatResponse: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCall: Decodable {
            struct Function: Decodable {
                let index: Int?
                let name: String
                let arguments: ArgumentValue?
            }

            enum ArgumentValue: Decodable {
                case string(String)
                case object([String: AnyDecodable])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let string = try? container.decode(String.self) {
                        self = .string(string)
                    } else if let object = try? container.decode([String: AnyDecodable].self) {
                        self = .object(object)
                    } else {
                        self = .string("{}")
                    }
                }
            }

            let id: String?
            let function: Function
        }

        let message: Message
        let doneReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case doneReason = "done_reason"
        }
    }

    private struct AnyDecodable: Decodable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let array = try? container.decode([AnyDecodable].self) {
                value = array.map(\.value)
            } else if let dict = try? container.decode([String: AnyDecodable].self) {
                value = dict.mapValues(\.value)
            } else {
                value = NSNull()
            }
        }
    }
}
