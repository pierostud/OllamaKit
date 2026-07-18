import Foundation

public struct OllamaInstalledModel: Identifiable, Equatable, Sendable {
    public let name: String
    public let isLoaded: Bool
    public let contextLength: Int?

    public var id: String { name }

    public init(name: String, isLoaded: Bool, contextLength: Int?) {
        self.name = name
        self.isLoaded = isLoaded
        self.contextLength = contextLength
    }
}

public struct OllamaPullProgress: Equatable, Sendable {
    public let status: String
    public let total: Int64?
    public let completed: Int64?

    public var fractionCompleted: Double? {
        guard let total, let completed, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    public init(status: String, total: Int64?, completed: Int64?) {
        self.status = status
        self.total = total
        self.completed = completed
    }
}

public struct OllamaCloudAccountInfo: Equatable, Sendable {
    public let plan: String
    public let email: String?

    public init(plan: String, email: String?) {
        self.plan = plan
        self.email = email
    }

    public var displayPlan: String {
        switch plan.lowercased() {
        case "free":
            return String(localized: "Free")
        case "pro":
            return String(localized: "Pro")
        case "max":
            return String(localized: "Max")
        default:
            return plan.capitalized
        }
    }
}

public actor OllamaModelService {
    private let connectionConfig: OllamaConnectionConfig
    private let urlSession: URLSession

    public init(
        connectionConfig: OllamaConnectionConfig,
        urlSession: URLSession = .shared
    ) {
        self.connectionConfig = connectionConfig
        self.urlSession = urlSession
    }

    public var supportsModelManagement: Bool {
        connectionConfig.supportsModelManagement
    }

    public func isServerAvailable() async -> Bool {
        if !connectionConfig.supportsModelManagement, connectionConfig.apiKey == nil {
            return false
        }

        let url = connectionConfig.endpoint("api/tags")

        let request = makeRequest(url: url, method: "GET", timeout: 5)

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    public func refreshInstalledModels(
        forceCloudAccessValidation: Bool = false,
        accountPlan: String? = nil,
        onCloudAccessProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [OllamaInstalledModel] {
        if !connectionConfig.supportsModelManagement {
            guard connectionConfig.apiKey != nil else {
                throw OllamaError.missingAPIKey
            }
        }

        if !connectionConfig.supportsModelManagement,
           !forceCloudAccessValidation,
           let apiKey = connectionConfig.apiKey,
           let cached = OllamaCloudModelAccessChecker.cachedSnapshot(for: apiKey) {
            return cached.models.map {
                OllamaInstalledModel(name: $0, isLoaded: false, contextLength: nil)
            }
        }

        var installedNames = try await fetchInstalledModelNames()

        if !connectionConfig.supportsModelManagement {
            let checker = OllamaCloudModelAccessChecker(
                connectionConfig: connectionConfig,
                urlSession: urlSession
            )
            installedNames = await checker.filterAccessibleModels(
                installedNames,
                accountPlan: accountPlan,
                forceValidation: forceCloudAccessValidation,
                onProgress: onCloudAccessProgress
            )
        }

        let runningModels: [RunningModel]
        if connectionConfig.supportsModelManagement {
            runningModels = try await fetchRunningModels()
        } else {
            runningModels = []
        }

        return installedNames.map { name in
            let running = runningModels.first { $0.name == name || $0.model == name }
            return OllamaInstalledModel(
                name: name,
                isLoaded: running != nil,
                contextLength: running?.contextLength
            )
        }
    }

    public func fetchCloudAccountInfo() async throws -> OllamaCloudAccountInfo {
        guard !connectionConfig.supportsModelManagement else {
            throw OllamaError.unsupportedOperation("Account info is only available in Ollama Cloud mode.")
        }
        guard connectionConfig.apiKey != nil else {
            throw OllamaError.missingAPIKey
        }

        let checker = OllamaCloudModelAccessChecker(
            connectionConfig: connectionConfig,
            urlSession: urlSession
        )
        return try await checker.fetchAccountInfo()
    }

    public func loadModel(_ name: String) async throws {
        guard connectionConfig.supportsModelManagement else {
            throw OllamaError.unsupportedOperation("Model loading is only available with a local Ollama server.")
        }
        try await postGenerate(model: name, prompt: "", keepAlive: -1, timeout: 300)
    }

    public func unloadModel(_ name: String) async throws {
        guard connectionConfig.supportsModelManagement else {
            throw OllamaError.unsupportedOperation("Model unloading is only available with a local Ollama server.")
        }
        try await postGenerate(model: name, prompt: nil, keepAlive: 0, timeout: 30)
    }

    public func pullModel(
        _ name: String,
        onProgress: @Sendable @escaping (OllamaPullProgress) -> Void
    ) async throws {
        guard connectionConfig.supportsModelManagement else {
            throw OllamaError.unsupportedOperation("Model downloads are only available with a local Ollama server.")
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaError.network("Model name is required.")
        }

        let url = connectionConfig.endpoint("api/pull")

        var request = makeRequest(url: url, method: "POST", timeout: 3600)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": trimmed,
            "stream": true
        ])

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OllamaError.network("Ollama pull request failed")
        }

        var lastStatus = ""
        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty,
                  let data = trimmedLine.data(using: .utf8),
                  let event = try? JSONDecoder().decode(PullEvent.self, from: data) else {
                continue
            }

            let progress = OllamaPullProgress(
                status: event.status,
                total: event.total,
                completed: event.completed
            )
            onProgress(progress)
            lastStatus = event.status.lowercased()

            if lastStatus == "success" {
                return
            }

            if lastStatus.contains("error") {
                throw OllamaError.network(event.status)
            }
        }

        if lastStatus != "success" {
            throw OllamaError.network("Ollama pull did not complete successfully.")
        }
    }

    public func isModelLoaded(_ name: String) async -> Bool {
        guard let runningModels = try? await fetchRunningModels() else { return false }
        return runningModels.contains { $0.name == name || $0.model == name }
    }

    private func makeRequest(url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        connectionConfig.applyAuth(to: &request)
        return request
    }

    private func fetchInstalledModelNames() async throws -> [String] {
        let url = connectionConfig.endpoint("api/tags")

        let request = makeRequest(url: url, method: "GET", timeout: 10)
        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map(\.name).sorted()
    }

    private func fetchRunningModels() async throws -> [RunningModel] {
        let url = connectionConfig.endpoint("api/ps")

        let request = makeRequest(url: url, method: "GET", timeout: 10)
        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(PsResponse.self, from: data)
        return decoded.models
    }

    private func postGenerate(
        model: String,
        prompt: String?,
        keepAlive: Int,
        timeout: TimeInterval
    ) async throws {
        let url = connectionConfig.endpoint("api/generate")

        var request = makeRequest(url: url, method: "POST", timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": keepAlive
        ]
        if let prompt {
            body["prompt"] = prompt
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
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

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }

        let models: [Model]
    }

    private struct RunningModel: Decodable {
        let name: String
        let model: String
        let contextLength: Int

        enum CodingKeys: String, CodingKey {
            case name
            case model
            case contextLength = "context_length"
        }
    }

    private struct PsResponse: Decodable {
        let models: [RunningModel]
    }

    private struct PullEvent: Decodable {
        let status: String
        let total: Int64?
        let completed: Int64?
    }
}
