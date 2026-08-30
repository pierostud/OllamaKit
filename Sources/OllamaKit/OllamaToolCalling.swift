import Foundation

// MARK: - Tool definitions

public struct OllamaToolDefinition: @unchecked Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: Any]

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    func toRequestDictionary() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

// MARK: - Tool calls

public struct OllamaToolCall: Equatable, Sendable, Identifiable {
    public var id: String?
    public var index: Int?
    public var name: String
    public var arguments: String

    public init(id: String? = nil, index: Int? = nil, name: String, arguments: String) {
        self.id = id
        self.index = index
        self.name = name
        self.arguments = arguments
    }

    public func parsedArguments() -> [String: Any]? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Chat response with tools

public struct OllamaChatResponse: Equatable, Sendable {
    public var content: String
    public var toolCalls: [OllamaToolCall]
    public var doneReason: String?

    public init(content: String, toolCalls: [OllamaToolCall] = [], doneReason: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.doneReason = doneReason
    }

    public var hasToolCalls: Bool { !toolCalls.isEmpty }
}
