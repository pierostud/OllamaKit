import Foundation
import Testing
@testable import OllamaKit

struct OllamaConnectionConfigTests {
    @Test func localConfigUsesBaseURLWithoutAuth() {
        let config = OllamaConnectionConfig.local()

        #expect(config.requiresAuthentication == false)
        #expect(config.supportsModelManagement)
        #expect(config.apiKey == nil)
        #expect(config.baseURL == OllamaConnectionConfig.defaultLocalBaseURL)

        var request = URLRequest(url: config.baseURL)
        config.applyAuth(to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func cloudConfigAddsBearerToken() {
        let config = OllamaConnectionConfig.cloud(apiKey: "test-key")

        #expect(config.requiresAuthentication)
        #expect(config.supportsModelManagement == false)
        #expect(config.baseURL == OllamaConnectionConfig.cloudBaseURL)

        var request = URLRequest(url: config.baseURL)
        config.applyAuth(to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func emptyCloudKeyIsTreatedAsMissing() {
        let config = OllamaConnectionConfig.cloud(apiKey: "   ")
        #expect(config.apiKey == nil)
        #expect(config.requiresAuthentication == false)
    }

    @Test func makeSelectsLocalOrCloud() {
        let local = OllamaConnectionConfig.make(
            mode: .local,
            localBaseURL: URL(string: "http://192.168.1.10:11434")!,
            cloudAPIKey: "ignored"
        )
        #expect(local.baseURL.host == "192.168.1.10")
        #expect(local.supportsModelManagement)
        #expect(local.apiKey == nil)

        let cloud = OllamaConnectionConfig.make(
            mode: .cloud,
            localBaseURL: URL(string: "http://127.0.0.1:11434")!,
            cloudAPIKey: "secret"
        )
        #expect(cloud.baseURL == OllamaConnectionConfig.cloudBaseURL)
        #expect(cloud.apiKey == "secret")
        #expect(cloud.supportsModelManagement == false)
    }
}

struct OllamaDeploymentModeTests {
    @Test func casesHaveStableIdentifiers() {
        #expect(OllamaDeploymentMode.local.id == "local")
        #expect(OllamaDeploymentMode.cloud.id == "cloud")
        #expect(OllamaDeploymentMode.allCases.count == 2)
    }
}

struct OllamaPullProgressTests {
    @Test func fractionCompletedRequiresPositiveTotal() {
        #expect(OllamaPullProgress(status: "x", total: nil, completed: 10).fractionCompleted == nil)
        #expect(OllamaPullProgress(status: "x", total: 0, completed: 10).fractionCompleted == nil)
        #expect(OllamaPullProgress(status: "x", total: 100, completed: 25).fractionCompleted == 0.25)
    }
}

struct OllamaErrorTests {
    @Test func httpErrorDescriptionIncludesStatusAndMessage() {
        let error = OllamaError.httpError(statusCode: 500, message: "boom")
        #expect(error.errorDescription == "HTTP 500: boom")
    }

    @Test func networkAndUnsupportedPassThroughMessage() {
        #expect(OllamaError.network("offline").errorDescription == "offline")
        #expect(OllamaError.unsupportedOperation("nope").errorDescription == "nope")
    }
}

struct OllamaChatMessageTests {
    @Test func factoriesSetExpectedRoles() {
        #expect(OllamaChatMessage.system("s").role == "system")
        #expect(OllamaChatMessage.user("u").role == "user")
        #expect(OllamaChatMessage.assistant("a").role == "assistant")
    }
}

struct OllamaCloudModelAccessCheckerTests {
    @Test func interpretAccessResponseRecognizesSubscriptionGate() {
        let body = Data(#"{"error":"upgrade subscription"}"#.utf8)
        let result = OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 403, body: body)
        #expect(result == .requiresSubscription)
    }

    @Test func interpretAccessResponseTreatsSuccessAsAccessible() {
        let result = OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 200, body: Data())
        #expect(result == .accessible)
    }

    @Test func interpretAccessResponseTreats404AsUnavailable() {
        let result = OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 404, body: Data())
        #expect(result == .unavailable)
    }

    @Test func interpretAccessResponseTreatsRateLimitAsAccessible() {
        #expect(OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 429, body: Data()) == .accessible)
        #expect(OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 402, body: Data()) == .accessible)
    }

    @Test func interpretAccessResponseTreatsUnknownErrorsAsInconclusive() {
        let result = OllamaCloudModelAccessChecker.interpretAccessResponse(statusCode: 500, body: Data())
        #expect(result == .inconclusive)
    }
}
