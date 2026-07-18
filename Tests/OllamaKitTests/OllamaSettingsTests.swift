import Foundation
import Testing
@testable import OllamaKit

@MainActor
struct OllamaSettingsTests {
    @Test func normalizedBaseURLAcceptsHostWithoutScheme() {
        let suiteName = "OllamaSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // OllamaSettings currently uses .standard; exercise public URL helpers via connectionConfig path.
        let settings = OllamaSettings(
            defaultsKeyPrefix: "test.\(UUID().uuidString)",
            keychainService: "eu.rock-soft.DietaLLM.tests.\(UUID().uuidString)",
            defaultModel: "llama3.2"
        )

        settings.baseURLString = "192.168.1.20:11434"
        #expect(settings.normalizedBaseURL?.absoluteString == "http://192.168.1.20:11434")

        settings.deploymentMode = .cloud
        settings.cloudAPIKey = "abc"
        #expect(settings.effectiveBaseURL == OllamaConnectionConfig.cloudBaseURL)
        #expect(settings.connectionConfig.apiKey == "abc")
        #expect(settings.isCloudMode)

        settings.deploymentMode = .local
        #expect(settings.connectionConfig.supportsModelManagement)
        #expect(settings.availabilityToken.contains("local"))
    }

    @Test func defaultModelIsAppliedWhenUnset() {
        let prefix = "test.defaults.\(UUID().uuidString)"
        let settings = OllamaSettings(
            defaultsKeyPrefix: prefix,
            keychainService: "eu.rock-soft.DietaLLM.tests.\(UUID().uuidString)",
            defaultModel: "qwen2.5"
        )

        #expect(settings.model == "qwen2.5")
        #expect(settings.deploymentMode == .local)

        // Cleanup keys we may have written.
        let keys = [
            "\(prefix).deploymentMode",
            "\(prefix).baseURL",
            "\(prefix).cloudAPIKey",
            "\(prefix).model"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

struct OllamaCloudAPIKeyStoreTests {
    @Test func saveReadAndDeleteRoundTripInDebug() {
        let key = "ollama.test.apiKey.\(UUID().uuidString)"
        let store = OllamaCloudAPIKeyStore(
            keychainService: "eu.rock-soft.DietaLLM.tests",
            userDefaultsKey: key
        )
        defer { store.delete() }

        #expect(store.read().isEmpty)

        store.save("  secret-value  ")
        #expect(store.read() == "secret-value")

        store.delete()
        #expect(store.read().isEmpty)
    }
}
