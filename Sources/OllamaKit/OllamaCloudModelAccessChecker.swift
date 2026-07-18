import CryptoKit
import Foundation

public enum OllamaCloudModelAccessResult: Equatable, Sendable {
    case accessible
    case requiresSubscription
    case unavailable
    case inconclusive
}

public struct OllamaCloudModelAccessChecker: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let urlSession: URLSession
    private let maxConcurrentChecks = 4

    public init(
        connectionConfig: OllamaConnectionConfig,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = connectionConfig.baseURL
        self.apiKey = connectionConfig.apiKey ?? ""
        self.urlSession = urlSession
    }

    public func fetchAccountInfo() async throws -> OllamaCloudAccountInfo {
        let url = baseURL.appending(path: "api/me")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OllamaError.network("Could not read Ollama account details.")
        }

        let decoded = try JSONDecoder().decode(MeResponse.self, from: data)
        let plan = decoded.plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return OllamaCloudAccountInfo(
            plan: plan?.isEmpty == false ? plan! : "free",
            email: decoded.email
        )
    }

    public func filterAccessibleModels(
        _ modelNames: [String],
        accountPlan: String? = nil,
        forceValidation: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [String] {
        // Without an API key we cannot verify plan access — never return the full catalog.
        guard !apiKey.isEmpty else { return [] }
        guard !modelNames.isEmpty else { return [] }

        let cache = Self.loadCache(for: apiKey)
        let cacheIsFresh = cache.map { Date().timeIntervalSince($0.updatedAt) < Self.cacheLifetime } ?? false

        if !forceValidation, cacheIsFresh, let cache {
            let accessible = Set(cache.accessibleModels)
            let inaccessible = Set(cache.inaccessibleModels)
            let allKnown = modelNames.allSatisfy { accessible.contains($0) || inaccessible.contains($0) }
            if allKnown {
                return modelNames.filter { accessible.contains($0) }.sorted()
            }
        }

        var accessible = Set<String>()
        var inaccessible = Set<String>()

        let pending: [String]
        if !forceValidation, cacheIsFresh, let cache {
            accessible = Set(cache.accessibleModels)
            inaccessible = Set(cache.inaccessibleModels)
            pending = modelNames.filter { name in
                !cache.accessibleModels.contains(name) && !cache.inaccessibleModels.contains(name)
            }
        } else {
            pending = modelNames
        }

        let total = pending.count
        var completed = 0

        if total > 0 {
            onProgress?(0, total)
        }

        await withTaskGroup(of: (String, OllamaCloudModelAccessResult).self) { group in
            var iterator = pending.makeIterator()

            for _ in 0..<min(maxConcurrentChecks, pending.count) {
                guard let name = iterator.next() else { break }
                group.addTask { await (name, self.checkModelAccess(name)) }
            }

            while let result = await group.next() {
                completed += 1
                onProgress?(completed, total)

                switch result.1 {
                case .accessible:
                    accessible.insert(result.0)
                case .requiresSubscription, .unavailable:
                    inaccessible.insert(result.0)
                case .inconclusive:
                    // Keep out of both lists so a later refresh can re-check.
                    break
                }

                if let next = iterator.next() {
                    group.addTask { await (next, self.checkModelAccess(next)) }
                }
            }
        }

        Self.saveCache(
            for: apiKey,
            accessibleModels: modelNames.filter { accessible.contains($0) }.sorted(),
            inaccessibleModels: modelNames.filter { inaccessible.contains($0) }.sorted(),
            accountPlan: accountPlan ?? cache?.accountPlan
        )

        return modelNames.filter { accessible.contains($0) }.sorted()
    }

    public static func hasFreshCache(for apiKey: String) -> Bool {
        guard let cache = loadCache(for: apiKey) else { return false }
        return Date().timeIntervalSince(cache.updatedAt) < cacheLifetime
    }

    public static func cachedSnapshot(for apiKey: String) -> (models: [String], plan: String)? {
        guard hasFreshCache(for: apiKey), let cache = loadCache(for: apiKey) else { return nil }
        guard !cache.accessibleModels.isEmpty else { return nil }
        return (cache.accessibleModels, cache.accountPlan ?? "")
    }

    public func checkModelAccess(_ modelName: String) async -> OllamaCloudModelAccessResult {
        let url = baseURL.appending(path: "api/generate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": modelName,
            "prompt": ".",
            "stream": false,
            "options": ["num_predict": 1]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .inconclusive
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .inconclusive
            }
            return Self.interpretAccessResponse(statusCode: httpResponse.statusCode, body: data)
        } catch {
            return .inconclusive
        }
    }

    public static func interpretAccessResponse(statusCode: Int, body: Data) -> OllamaCloudModelAccessResult {
        if (200...299).contains(statusCode) {
            return .accessible
        }

        let message = String(data: body, encoding: .utf8)?.lowercased() ?? ""

        if statusCode == 403,
           message.contains("subscription") || message.contains("upgrade") {
            return .requiresSubscription
        }

        if statusCode == 404 {
            return .unavailable
        }

        if statusCode == 402 || statusCode == 429 {
            return .accessible
        }

        if statusCode == 403 {
            return .requiresSubscription
        }

        return .inconclusive
    }

    private static func loadCache(for apiKey: String) -> CacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: cacheDefaultsKey) else { return nil }
        guard let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        guard entry.fingerprint == fingerprint(for: apiKey) else { return nil }
        return entry
    }

    private static func saveCache(
        for apiKey: String,
        accessibleModels: [String],
        inaccessibleModels: [String],
        accountPlan: String? = nil
    ) {
        let existingPlan = loadCache(for: apiKey)?.accountPlan
        let entry = CacheEntry(
            fingerprint: fingerprint(for: apiKey),
            updatedAt: Date(),
            accessibleModels: accessibleModels,
            inaccessibleModels: inaccessibleModels,
            accountPlan: accountPlan ?? existingPlan
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cacheDefaultsKey)
    }

    private static func fingerprint(for apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let cacheDefaultsKey = "ollama.cloudModelAccessCache"
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private struct CacheEntry: Codable {
        let fingerprint: String
        let updatedAt: Date
        let accessibleModels: [String]
        let inaccessibleModels: [String]
        let accountPlan: String?
    }

    private struct MeResponse: Decodable {
        let email: String?
        let plan: String?
    }
}
