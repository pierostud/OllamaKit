import Foundation
import Observation

@MainActor
@Observable
public final class OllamaSettings {
    public var deploymentMode: OllamaDeploymentMode {
        didSet { UserDefaults.standard.set(deploymentMode.rawValue, forKey: keys.deploymentMode) }
    }

    public var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: keys.baseURL) }
    }

    public var cloudAPIKey: String {
        didSet { apiKeyStore.save(cloudAPIKey) }
    }

    public var model: String {
        didSet { UserDefaults.standard.set(model, forKey: keys.model) }
    }

    public var isCloudMode: Bool {
        deploymentMode == .cloud
    }

    public var connectionConfig: OllamaConnectionConfig {
        OllamaConnectionConfig.make(
            mode: deploymentMode,
            localBaseURL: normalizedBaseURL ?? OllamaConnectionConfig.defaultLocalBaseURL,
            cloudAPIKey: cloudAPIKey
        )
    }

    public var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        return URL(string: "http://\(trimmed)")
    }

    public var effectiveBaseURL: URL {
        switch deploymentMode {
        case .local:
            return normalizedBaseURL ?? OllamaConnectionConfig.defaultLocalBaseURL
        case .cloud:
            return OllamaConnectionConfig.cloudBaseURL
        }
    }

    public var availabilityToken: String {
        [
            deploymentMode.rawValue,
            cloudAPIKey.isEmpty ? "0" : "1",
            baseURLString
        ].joined(separator: "|")
    }

    private let keys: Keys
    private let apiKeyStore: OllamaCloudAPIKeyStore

    public init(
        defaultsKeyPrefix: String = "ollama",
        keychainService: String,
        defaultModel: String = "llama3.2"
    ) {
        let keys = Keys(prefix: defaultsKeyPrefix)
        self.keys = keys
        self.apiKeyStore = OllamaCloudAPIKeyStore(
            keychainService: keychainService,
            userDefaultsKey: keys.cloudAPIKey
        )

        if let storedMode = UserDefaults.standard.string(forKey: keys.deploymentMode),
           let mode = OllamaDeploymentMode(rawValue: storedMode) {
            deploymentMode = mode
        } else {
            deploymentMode = .local
        }

        baseURLString = UserDefaults.standard.string(forKey: keys.baseURL)
            ?? OllamaConnectionConfig.defaultLocalBaseURL.absoluteString
        cloudAPIKey = apiKeyStore.read()
        model = UserDefaults.standard.string(forKey: keys.model) ?? defaultModel
    }

    private struct Keys {
        let deploymentMode: String
        let baseURL: String
        let cloudAPIKey: String
        let model: String

        init(prefix: String) {
            deploymentMode = "\(prefix).deploymentMode"
            baseURL = "\(prefix).baseURL"
            cloudAPIKey = "\(prefix).cloudAPIKey"
            model = "\(prefix).model"
        }
    }
}
