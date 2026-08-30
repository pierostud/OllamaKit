import Foundation
import Testing
@testable import OllamaKit

/// All URLProtocol-based tests live in one serialized suite so the shared
/// mock handler cannot be overwritten by a parallel test.
@Suite(.serialized)
struct OllamaNetworkingTests {
    // MARK: - Client

    @Test func chatReturnsAssistantContent() async throws {
        let reply = try await MockHTTP.withHandler({ request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/chat")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

            let body = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            #expect(body?["model"] as? String == "llama3.2")
            #expect(body?["stream"] as? Bool == false)

            let messages = body?["messages"] as? [[String: String]]
            #expect(messages?.count == 2)
            #expect(messages?[0]["role"] == "system")
            #expect(messages?[1]["role"] == "user")

            let data = """
            {"message":{"role":"assistant","content":"  hello world  "}}
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return try await client.chat(model: "llama3.2", system: "Be helpful", user: "Hi")
        }

        #expect(reply == "hello world")
    }

    @Test func chatAppliesCloudAuthorizationAndOptions() async throws {
        let reply = try await MockHTTP.withHandler({ request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cloud-key")

            let body = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            #expect(body?["format"] as? String == "json")

            let options = body?["options"] as? [String: Any]
            #expect((options?["num_predict"] as? NSNumber)?.intValue == 128)
            #expect(abs(((options?["temperature"] as? NSNumber)?.doubleValue ?? -1) - 0.2) < 0.0001)

            let data = """
            {"message":{"role":"assistant","content":"{\\"ok\\":true}"}}
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let client = OllamaClient(
                connectionConfig: .cloud(apiKey: "cloud-key"),
                urlSession: MockHTTP.makeSession()
            )
            return try await client.chat(
                model: "cloud-model",
                messages: [.user("ping")],
                options: OllamaChatOptions(numPredict: 128, temperature: 0.2, jsonFormat: true)
            )
        }

        #expect(reply == #"{"ok":true}"#)
    }

    @Test func chatThrowsOnEmptyAssistantContent() async throws {
        do {
            _ = try await MockHTTP.withHandler({ request in
                let data = """
                {"message":{"role":"assistant","content":"   "}}
                """.data(using: .utf8)!
                return (MockHTTP.okResponse(for: request), data)
            }) {
                let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
                return try await client.chat(model: "llama3.2", user: "Hi")
            }
            Issue.record("Expected invalidResponse")
        } catch let error as OllamaError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
    }

    @Test func chatThrowsHttpError() async throws {
        do {
            _ = try await MockHTTP.withHandler({ request in
                return (MockHTTP.okResponse(for: request, statusCode: 404), Data("model not found".utf8))
            }) {
                let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
                return try await client.chat(model: "missing", user: "Hi")
            }
            Issue.record("Expected httpError")
        } catch let error as OllamaError {
            guard case .httpError(let status, let message) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(status == 404)
            #expect(message.contains("model not found"))
        }
    }

    @Test func chatWithToolsReturnsToolCalls() async throws {
        let response = try await MockHTTP.withHandler({ request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/chat")

            let body = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            #expect(body?["model"] as? String == "llama3.2")
            #expect(body?["format"] == nil)

            let tools = body?["tools"] as? [[String: Any]]
            #expect(tools?.count == 1)
            let function = (tools?.first?["function"] as? [String: Any])
            #expect(function?["name"] as? String == "ping")

            let messages = body?["messages"] as? [[String: Any]]
            #expect(messages?.count == 2)
            #expect(messages?[0]["role"] as? String == "system")
            #expect(messages?[1]["role"] as? String == "user")

            let data = """
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "type": "function",
                    "function": {
                      "index": 0,
                      "name": "ping",
                      "arguments": {"value": "hello"}
                    }
                  }
                ]
              },
              "done_reason": "tool_calls"
            }
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return try await client.chatWithTools(
                model: "llama3.2",
                messages: [.system("Be helpful"), .user("Ping")],
                tools: [
                    OllamaToolDefinition(
                        name: "ping",
                        description: "Ping tool",
                        parameters: [
                            "type": "object",
                            "properties": ["value": ["type": "string"]],
                        ]
                    ),
                ]
            )
        }

        #expect(response.content.isEmpty)
        #expect(response.hasToolCalls)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "ping")
        #expect(response.toolCalls[0].parsedArguments()?["value"] as? String == "hello")
        #expect(response.doneReason == "tool_calls")
    }

    @Test func chatWithToolsEncodesAssistantAndToolMessages() async throws {
        let response = try await MockHTTP.withHandler({ request in
            let body = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]]
            #expect(messages?.count == 4)
            #expect(messages?[2]["role"] as? String == "assistant")
            #expect((messages?[2]["tool_calls"] as? [[String: Any]])?.isEmpty == false)
            #expect(messages?[3]["role"] as? String == "tool")
            #expect(messages?[3]["tool_name"] as? String == "ping")
            #expect(messages?[3]["content"] as? String == "pong")

            let data = """
            {"message":{"role":"assistant","content":"done"},"done_reason":"stop"}
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return try await client.chatWithTools(
                model: "llama3.2",
                messages: [
                    .system("sys"),
                    .user("Ping"),
                    .assistant(toolCalls: [OllamaToolCall(index: 0, name: "ping", arguments: #"{"value":"hello"}"#)]),
                    .tool(name: "ping", content: "pong"),
                ],
                tools: [
                    OllamaToolDefinition(
                        name: "ping",
                        description: "Ping tool",
                        parameters: ["type": "object", "properties": [:] as [String: Any]]
                    ),
                ]
            )
        }

        #expect(response.content == "done")
        #expect(response.toolCalls.isEmpty)
    }

    @Test func chatWithToolsDecodesStringArguments() async throws {
        let response = try await MockHTTP.withHandler({ request in
            let data = """
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "type": "function",
                    "function": {
                      "name": "ping",
                      "arguments": "{\\"value\\":\\"hello\\"}"
                    }
                  }
                ]
              }
            }
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return try await client.chatWithTools(
                model: "llama3.2",
                messages: [.user("Ping")],
                tools: [
                    OllamaToolDefinition(
                        name: "ping",
                        description: "Ping tool",
                        parameters: ["type": "object", "properties": [:] as [String: Any]]
                    ),
                ]
            )
        }

        #expect(response.toolCalls[0].arguments.contains("hello"))
    }

    @Test func chatMapsTransportFailureToNotRunning() async throws {
        do {
            _ = try await MockHTTP.withHandler({ _ in
                throw URLError(.cannotConnectToHost)
            }) {
                let client = OllamaClient(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
                return try await client.chat(model: "llama3.2", user: "Hi")
            }
            Issue.record("Expected notRunning")
        } catch let error as OllamaError {
            guard case .notRunning = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
    }

    // MARK: - Model service

    @Test func refreshInstalledModelsMergesTagsAndPs() async throws {
        let models = try await MockHTTP.withHandler({ request in
            if request.url?.path == "/api/tags" {
                let data = """
                {"models":[{"name":"llama3.2"},{"name":"qwen2.5:7b"}]}
                """.data(using: .utf8)!
                return (MockHTTP.okResponse(for: request), data)
            }
            if request.url?.path == "/api/ps" {
                let data = """
                {"models":[{"name":"qwen2.5:7b","model":"qwen2.5:7b","context_length":4096}]}
                """.data(using: .utf8)!
                return (MockHTTP.okResponse(for: request), data)
            }
            throw URLError(.unsupportedURL)
        }) {
            let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return try await service.refreshInstalledModels()
        }

        #expect(models.count == 2)
        #expect(models.first { $0.name == "llama3.2" }?.isLoaded == false)
        #expect(models.first { $0.name == "qwen2.5:7b" }?.isLoaded == true)
        #expect(models.first { $0.name == "qwen2.5:7b" }?.contextLength == 4096)
    }

    @Test func isServerAvailableReturnsTrueOnTagsSuccess() async throws {
        let available = try await MockHTTP.withHandler({ request in
            #expect(request.url?.path == "/api/tags")
            return (MockHTTP.okResponse(for: request), Data("{}".utf8))
        }) {
            let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            return await service.isServerAvailable()
        }
        #expect(available)
    }

    @Test func isServerAvailableReturnsFalseWithoutCloudAPIKey() async {
        let service = OllamaModelService(connectionConfig: .cloud(apiKey: nil), urlSession: MockHTTP.makeSession())
        #expect(await service.isServerAvailable() == false)
    }

    @Test func cloudAvailabilitySendsAuthorizationHeader() async throws {
        let available = try await MockHTTP.withHandler({ request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
            return (MockHTTP.okResponse(for: request), Data(#"{"models":[]}"#.utf8))
        }) {
            let service = OllamaModelService(
                connectionConfig: .cloud(apiKey: "secret-key"),
                urlSession: MockHTTP.makeSession()
            )
            return await service.isServerAvailable()
        }
        #expect(available)
    }

    @Test func loadModelSendsExpectedGeneratePayload() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?

        try await MockHTTP.withHandler({ request in
            #expect(request.url?.path == "/api/generate")
            capturedBody = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            return (MockHTTP.okResponse(for: request), Data(#"{"done":true}"#.utf8))
        }) {
            let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            try await service.loadModel("llama3.2")
        }

        #expect(capturedBody?["model"] as? String == "llama3.2")
        #expect(capturedBody?["prompt"] as? String == "")
        #expect(capturedBody?["stream"] as? Bool == false)
        #expect((capturedBody?["keep_alive"] as? NSNumber)?.intValue == -1)
    }

    @Test func unloadModelSendsKeepAliveZero() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?

        try await MockHTTP.withHandler({ request in
            capturedBody = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            return (MockHTTP.okResponse(for: request), Data(#"{"done":true}"#.utf8))
        }) {
            let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            try await service.unloadModel("llama3.2")
        }

        #expect(capturedBody?["model"] as? String == "llama3.2")
        #expect((capturedBody?["keep_alive"] as? NSNumber)?.intValue == 0)
        #expect(capturedBody?["prompt"] == nil)
    }

    @Test func pullModelParsesStreamingProgress() async throws {
        let stream = """
        {"status":"pulling manifest"}
        {"status":"downloading digest","total":100,"completed":50}
        {"status":"success"}
        """.data(using: .utf8)!

        nonisolated(unsafe) var statuses: [String] = []
        nonisolated(unsafe) var lastFraction: Double?

        try await MockHTTP.withHandler({ request in
            #expect(request.url?.path == "/api/pull")
            let body = try JSONSerialization.jsonObject(with: MockHTTP.bodyData(from: request)) as? [String: Any]
            #expect(body?["model"] as? String == "llama3.2")
            #expect(body?["stream"] as? Bool == true)
            return (MockHTTP.okResponse(for: request), stream)
        }) {
            let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
            try await service.pullModel("llama3.2") { progress in
                statuses.append(progress.status)
                if let fraction = progress.fractionCompleted {
                    lastFraction = fraction
                }
            }
        }

        #expect(statuses == ["pulling manifest", "downloading digest", "success"])
        #expect(lastFraction == 0.5)
    }

    @Test func cloudModeRejectsLocalOnlyOperations() async {
        let service = OllamaModelService(connectionConfig: .cloud(apiKey: "key"), urlSession: MockHTTP.makeSession())
        do {
            try await service.loadModel("x")
            Issue.record("Expected unsupportedOperation")
        } catch let error as OllamaError {
            guard case .unsupportedOperation = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type \(error)")
        }
    }

    @Test func fetchCloudAccountInfoRequiresCloudMode() async {
        let service = OllamaModelService(connectionConfig: .local(), urlSession: MockHTTP.makeSession())
        do {
            _ = try await service.fetchCloudAccountInfo()
            Issue.record("Expected unsupportedOperation")
        } catch let error as OllamaError {
            guard case .unsupportedOperation = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type \(error)")
        }
    }

    @Test func fetchCloudAccountInfoParsesPlanAndEmail() async throws {
        let info = try await MockHTTP.withHandler({ request in
            #expect(request.url?.path == "/api/me")
            #expect(request.httpMethod == "POST")
            let data = """
            {"email":"piero@example.com","plan":"Pro"}
            """.data(using: .utf8)!
            return (MockHTTP.okResponse(for: request), data)
        }) {
            let service = OllamaModelService(
                connectionConfig: .cloud(apiKey: "key"),
                urlSession: MockHTTP.makeSession()
            )
            return try await service.fetchCloudAccountInfo()
        }

        #expect(info.email == "piero@example.com")
        #expect(info.plan == "pro")
        #expect(info.displayPlan == "Pro")
    }

    @Test func refreshInstalledModelsFiltersCloudByAccess() async throws {
        let models = try await MockHTTP.withHandler({ request in
            let path = request.url?.path ?? ""
            if path == "/api/tags" {
                let data = """
                {"models":[{"name":"gemma4:31b"},{"name":"qwen3.5:397b"}]}
                """.data(using: .utf8)!
                return (MockHTTP.okResponse(for: request), data)
            }

            if path == "/api/generate" {
                let body = String(data: MockHTTP.bodyData(from: request), encoding: .utf8) ?? ""
                if body.contains("qwen3.5:397b") {
                    let data = #"{"error":"this model requires a subscription, upgrade for access"}"#.data(using: .utf8)!
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 403,
                            httpVersion: nil,
                            headerFields: nil
                        )!,
                        data
                    )
                }
                return (MockHTTP.okResponse(for: request), Data("{}".utf8))
            }

            Issue.record("Unexpected path \(path)")
            return (MockHTTP.okResponse(for: request), Data())
        }) {
            let service = OllamaModelService(
                connectionConfig: .cloud(apiKey: "key"),
                urlSession: MockHTTP.makeSession()
            )
            return try await service.refreshInstalledModels(forceCloudAccessValidation: true)
        }

        #expect(models.map(\.name) == ["gemma4:31b"])
    }

    @Test func refreshInstalledModelsRequiresCloudAPIKey() async {
        let service = OllamaModelService(connectionConfig: .cloud(apiKey: nil), urlSession: MockHTTP.makeSession())
        do {
            _ = try await service.refreshInstalledModels()
            Issue.record("Expected missingAPIKey")
        } catch let error as OllamaError {
            guard case .missingAPIKey = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type \(error)")
        }
    }
}
