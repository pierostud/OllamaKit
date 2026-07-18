import Foundation

/// Stores the Ollama Cloud API key.
/// In DEBUG builds it uses UserDefaults for convenience; in Release it uses the Keychain.
public struct OllamaCloudAPIKeyStore: Sendable {
    public let keychainService: String
    public let userDefaultsKey: String

    public init(
        keychainService: String,
        userDefaultsKey: String = "ollama.cloudAPIKey"
    ) {
        self.keychainService = keychainService
        self.userDefaultsKey = userDefaultsKey
    }

    public func read() -> String {
        #if DEBUG
        UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        #else
        OllamaKeychainStore.read(service: keychainService) ?? ""
        #endif
    }

    public func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        #if DEBUG
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: userDefaultsKey)
        }
        #else
        if trimmed.isEmpty {
            OllamaKeychainStore.delete(service: keychainService)
        } else {
            OllamaKeychainStore.save(trimmed, service: keychainService)
        }
        #endif
    }

    public func delete() {
        save("")
    }
}
