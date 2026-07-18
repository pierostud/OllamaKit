import Foundation

public struct OllamaConnectionConfig: Equatable, Sendable {
    public static let cloudBaseURL = URL(string: "https://ollama.com")!
    public static let defaultLocalBaseURL = URL(string: "http://127.0.0.1:11434")!

    public let baseURL: URL
    public let apiKey: String?
    public let supportsModelManagement: Bool

    public var requiresAuthentication: Bool {
        apiKey != nil
    }

    public init(baseURL: URL, apiKey: String?, supportsModelManagement: Bool) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.supportsModelManagement = supportsModelManagement
    }

    public static func local(baseURL: URL = defaultLocalBaseURL) -> OllamaConnectionConfig {
        OllamaConnectionConfig(
            baseURL: baseURL,
            apiKey: nil,
            supportsModelManagement: true
        )
    }

    public static func cloud(apiKey: String?) -> OllamaConnectionConfig {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OllamaConnectionConfig(
            baseURL: cloudBaseURL,
            apiKey: (trimmed?.isEmpty == false) ? trimmed : nil,
            supportsModelManagement: false
        )
    }

    public static func make(
        mode: OllamaDeploymentMode,
        localBaseURL: URL = defaultLocalBaseURL,
        cloudAPIKey: String?
    ) -> OllamaConnectionConfig {
        switch mode {
        case .local:
            return .local(baseURL: localBaseURL)
        case .cloud:
            return .cloud(apiKey: cloudAPIKey)
        }
    }

    public func applyAuth(to request: inout URLRequest) {
        guard let apiKey, !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    /// Builds an absolute API URL (e.g. `"api/chat"` → `http://host/api/chat`).
    public func endpoint(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appending(path: trimmed)
    }
}
