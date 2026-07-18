import Foundation

public enum OllamaDeploymentMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case cloud

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local:
            return String(localized: "Local")
        case .cloud:
            return String(localized: "Cloud")
        }
    }
}
