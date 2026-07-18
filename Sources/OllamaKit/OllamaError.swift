import Foundation

public enum OllamaError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case notRunning
    case missingAPIKey
    case httpError(statusCode: Int, message: String)
    case network(String)
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid Ollama URL.")
        case .invalidResponse:
            return String(localized: "Invalid response from Ollama.")
        case .notRunning:
            return String(localized: "Ollama is not reachable.")
        case .missingAPIKey:
            return String(localized: "An Ollama Cloud API key is required.")
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .network(let message):
            return message
        case .unsupportedOperation(let message):
            return message
        }
    }
}
