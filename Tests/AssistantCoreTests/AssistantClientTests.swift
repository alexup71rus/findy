import Foundation
import XCTest
@testable import AssistantCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

final class AssistantClientTests: XCTestCase, @unchecked Sendable {
    func testEndpointSupportsBasesFullRoutesAndAPISwitching() throws {
        let cases: [(String, AssistantAPIStyle, String)] = [
            ("https://example.test", .chatCompletions, "https://example.test/chat/completions"),
            ("https://example.test/v1/", .chatCompletions, "https://example.test/v1/chat/completions"),
            (" https://example.test/custom/v2/chat/completions/ \n", .chatCompletions, "https://example.test/custom/v2/chat/completions"),
            ("https://example.test/custom/v2/chat/completions", .responses, "https://example.test/custom/v2/responses"),
            ("https://example.test/custom/responses", .chatCompletions, "https://example.test/custom/chat/completions"),
            ("https://example.test/prefix%20name", .responses, "https://example.test/prefix%20name/responses"),
            ("http://localhost:9000/v1", .chatCompletions, "http://localhost:9000/v1/chat/completions"),
            ("http://127.0.0.1:9000", .responses, "http://127.0.0.1:9000/responses"),
            ("http://127.20.1.2:9000", .responses, "http://127.20.1.2:9000/responses"),
            ("http://[::1]:9000/v1", .responses, "http://[::1]:9000/v1/responses"),
            ("http://192.168.1.5:8080/custom", .chatCompletions, "http://192.168.1.5:8080/custom/chat/completions"),
            ("http://llm.home:8080/v1/responses", .chatCompletions, "http://llm.home:8080/v1/chat/completions"),
            ("http://example.test/v1", .responses, "http://example.test/v1/responses")
        ]
        for (endpoint, style, expected) in cases {
            let config = AssistantConfiguration(endpoint: endpoint, model: "test-model", apiStyle: style)
            XCTAssertEqual(try config.validatedEndpoint().absoluteString, expected, endpoint)
        }
    }

    func testInvalidEndpointsAreRejectedWithoutEchoingTheirContents() {
        for endpoint in [
            "", "not-a-url", "https:///no-host", "ftp://example.test/v1",
            "https://", "http://", "mailto:user@example.test",
            "https://example.test/with space", "https://example.test/with\nnewline",
            "https://user:secret@example.test/v1", "https://example.test/v1?key=secret",
            "https://example.test/v1#secret", "https://example.test/v1?"
        ] {
            XCTAssertThrowsError(try AssistantConfiguration(endpoint: endpoint, model: "test-model").validatedEndpoint()) { error in
                XCTAssertEqual(error as? AssistantClientError, .invalidEndpoint, endpoint)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        XCTAssertThrowsError(try AssistantConfiguration(model: " \n ").validatedEndpoint()) {
            XCTAssertEqual($0 as? AssistantClientError, .missingModel)
        }
        XCTAssertThrowsError(try AssistantConfiguration(model: "test-model", webSearchEnabled: true).validatedEndpoint()) {
            XCTAssertEqual($0 as? AssistantClientError, .unsupportedWebSearch)
        }
    }

    func testProvidersAndGlobalModelSelectionRoundTripAndDeriveTheChosenConfiguration() throws {
        let provider = AssistantProvider(
            name: "Домашний сервер",
            endpoint: "http://192.168.1.5:8080/custom",
            apiStyle: .responses,
            models: ["model-a", "model-b"],
            systemPrompt: "Отвечай по-русски",
            webSearchEnabled: true
        )
        let otherProvider = AssistantProvider(name: "Другой сервис", endpoint: "https://example.test/v1", models: ["model-b"])
        XCTAssertNotEqual(provider.id, otherProvider.id)
        let selection = AssistantModelSelection(providerID: provider.id, modelID: "model-b")
        let config = provider.configuration(for: selection.modelID)
        XCTAssertEqual(config.endpoint, provider.endpoint)
        XCTAssertEqual(config.model, "model-b")
        XCTAssertEqual(config.apiStyle, .responses)
        XCTAssertEqual(config.systemPrompt, "Отвечай по-русски")
        XCTAssertTrue(config.webSearchEnabled)
        XCTAssertEqual(try config.validatedEndpoint().absoluteString, "http://192.168.1.5:8080/custom/responses")
        XCTAssertEqual(try JSONDecoder().decode(AssistantProvider.self, from: JSONEncoder().encode(provider)), provider)
        XCTAssertEqual(try JSONDecoder().decode(AssistantModelSelection.self, from: JSONEncoder().encode(selection)), selection)
        XCTAssertEqual(AssistantProvider(name: "Без авторизации", endpoint: "http://llm.home").models, [])
    }

    func testModelDiscoveryUsesGETWithOptionalAuthAndNormalizesACompleteEndpoint() async throws {
        for style in AssistantAPIStyle.allCases {
            let fixture = Fixture(body: #"{"data":[{"id":" z-model "},{"id":"a-model"},{"id":"z-model"},{"id":""},{"id":"  "},{"id":"A-model"}]}"#)
            defer { fixture.close() }
            let fullPath = fixture.configuration().endpoint + (style == .chatCompletions ? "/chat/completions/" : "/responses")
            let models = try await fixture.client.availableModels(endpoint: fullPath, apiStyle: style, apiKey: "")
            XCTAssertEqual(models, ["A-model", "a-model", "z-model"])
            let request = try XCTUnwrap(fixture.request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/prefix/models")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 45)
        }
        let fixture = Fixture(body: #"{"data":[{"id":"one"}]}"#)
        defer { fixture.close() }
        let models = try await fixture.client.availableModels(
            endpoint: fixture.configuration().endpoint + "/models",
            apiKey: "  fake-model-key "
        )
        XCTAssertEqual(models, ["one"])
        XCTAssertEqual(fixture.request?.url?.path, "/prefix/models")
        XCTAssertEqual(fixture.request?.value(forHTTPHeaderField: "Authorization"), "Bearer fake-model-key")
    }

    func testModelDiscoveryAcceptsAnEmptyCatalogButRejectsMalformedCatalogs() async throws {
        let empty = Fixture(body: #"{"data":[]}"#)
        defer { empty.close() }
        let models = try await empty.client.availableModels(endpoint: empty.configuration().endpoint, apiKey: "")
        XCTAssertEqual(models, [])
        for (body, expected) in [
            ("not JSON", AssistantClientError.invalidResponse),
            ("{}", .invalidResponse),
            (#"{"models":[{"id":"not-the-openai-format"}]}"#, .invalidResponse),
            (#"{"data":[{"id":42}]}"#, .invalidResponse),
            (#"{"data":[{"object":"model"}]}"#, .invalidResponse),
            (#"{"error":{"message":"SECRET provider message"}}"#, .failedResponse)
        ] {
            let fixture = Fixture(body: body)
            defer { fixture.close() }
            do {
                _ = try await fixture.client.availableModels(endpoint: fixture.configuration().endpoint, apiKey: "")
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testModelDiscoveryUsesTheSameSafeFailureAndValidationRules() async throws {
        let fixture = Fixture(status: 401, body: #"{"error":{"message":"SECRET fake-model-key"}}"#)
        defer { fixture.close() }
        do {
            _ = try await fixture.client.availableModels(endpoint: fixture.configuration().endpoint, apiKey: "fake-model-key")
            XCTFail("Expected rejected credentials")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            XCTAssertFalse(error.localizedDescription.contains("fake-model-key"))
        }
        let invalid = Fixture(body: #"{"data":[]}"#)
        defer { invalid.close() }
        do {
            _ = try await invalid.client.availableModels(endpoint: "http://example.test/v1?key=SECRET", apiKey: "")
            XCTFail("Expected invalid endpoint")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .invalidEndpoint)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        for key in ["fake\r\nkey", "fake\u{0}key", "fake\tkey"] {
            do {
                _ = try await invalid.client.availableModels(endpoint: invalid.configuration().endpoint, apiKey: key)
                XCTFail("Expected invalid header")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, .invalidAPIKey)
            }
        }
        XCTAssertNil(invalid.request)
    }

    func testChatRequestIncludesSystemAndConversationButNoProviderSpecificGenerationOptions() async throws {
        let fixture = Fixture(body: #"{"choices":[{"message":{"content":"Ответ"},"finish_reason":"stop"}]}"#)
        defer { fixture.close() }
        let history = [
            AssistantMessage(role: .user, text: "Меня зовут Саша"),
            AssistantMessage(role: .assistant, text: "Привет, Саша"),
            AssistantMessage(role: .user, text: "Как меня зовут?")
        ]
        let reply = try await fixture.client.reply(
            configuration: fixture.configuration(systemPrompt: "Отвечай кратко"),
            apiKey: "  fake-test-key  ",
            messages: history
        )
        XCTAssertEqual(reply, AssistantReply(text: "Ответ"))
        let request = try XCTUnwrap(fixture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/prefix/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 45)
        let body = try jsonBody(request)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["Отвечай кратко", "Меня зовут Саша", "Привет, Саша", "Как меня зовут?"])
    }

    func testConfiguredCountKeepsLongHistoryAndLongVoiceInput() async throws {
        let fixture = Fixture(body: #"{"choices":[{"message":{"content":"Ответ"}}]}"#)
        defer { fixture.close() }
        var configuration = fixture.configuration()
        configuration.contextMessageCount = 5
        let history = [AssistantMessage(role: .user, text: "Старый вопрос"),
                       AssistantMessage(role: .assistant, text: String(repeating: "д", count: 60_000)),
                       AssistantMessage(role: .user, text: String(repeating: "🙂", count: 501))]
        _ = try await fixture.client.reply(configuration: configuration, apiKey: "", messages: history)
        let body = try jsonBody(XCTUnwrap(fixture.request))
        let sent = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(sent.suffix(3).compactMap { $0["content"] }, history.map(\.text))
    }

    func testEmptyKeyAndSystemPromptAreSupportedForAnUnauthenticatedProvider() async throws {
        let fixture = Fixture(body: #"{"choices":[{"message":{"content":"Готов"}}]}"#)
        defer { fixture.close() }
        _ = try await fixture.client.reply(
            configuration: fixture.configuration(systemPrompt: ""),
            apiKey: "",
            messages: [AssistantMessage(role: .user, text: "Привет")]
        )
        let request = try XCTUnwrap(fixture.request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try jsonBody(request)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["user"])
    }

    func testResponsesRequestUsesRawMessagesAndHostedSearchOnlyWhenEnabled() async throws {
        let fixture = Fixture(body: #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Нашёл"}]}]}"#)
        defer { fixture.close() }
        let configuration = fixture.configuration(apiStyle: .responses, systemPrompt: "Проверь факты", webSearchEnabled: true)
        let reply = try await fixture.client.reply(
            configuration: configuration,
            apiKey: "fake-key",
            messages: [AssistantMessage(role: .user, text: "Что нового?")]
        )
        XCTAssertEqual(reply.text, "Нашёл")
        let request = try XCTUnwrap(fixture.request)
        XCTAssertEqual(request.url?.path, "/prefix/responses")
        let body = try jsonBody(request)
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "tools", "store", "stream"])
        XCTAssertEqual(body["instructions"] as? String, "Проверь факты")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["tools"] as? [[String: String]], [["type": "web_search"]])
        XCTAssertEqual(body["input"] as? [[String: String]], [["role": "user", "content": "Что нового?"]])
    }

    func testResponsesWithoutSearchDoesNotSendTools() async throws {
        let fixture = Fixture(body: #"{"output_text":"Готов"}"#)
        defer { fixture.close() }
        _ = try await fixture.client.reply(
            configuration: fixture.configuration(apiStyle: .responses),
            apiKey: "",
            messages: [AssistantMessage(role: .user, text: "Привет")]
        )
        XCTAssertNil(try jsonBody(XCTUnwrap(fixture.request))["tools"])
    }

    func testEnabledSearchIsReportedAsUsedOnlyWhenTheResponseContainsAToolCall() async throws {
        for (body, expected) in [
            (#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Поиск не понадобился"}]}]}"#, false),
            (#"{"status":"completed","output":[{"type":"web_search_call","status":"completed"},{"type":"message","content":[{"type":"output_text","text":"Нашёл ответ"}]}]}"#, true)
        ] {
            let fixture = Fixture(body: body)
            defer { fixture.close() }
            let reply = try await fixture.client.reply(
                configuration: fixture.configuration(apiStyle: .responses, webSearchEnabled: true),
                apiKey: "",
                messages: [AssistantMessage(role: .user, text: "Ответь на вопрос")]
            )
            XCTAssertEqual(reply.usedWebSearch, expected)
        }
    }

    func testResponseCitationsAreReadDeduplicatedAndLimitedToSafeWebURLs() async throws {
        let fixture = Fixture(body: """
        {
          "status":"completed",
          "output":[
            {"type":"web_search_call","status":"completed"},
            {"type":"message","content":[
              {"type":"output_text","text":"Первый факт.","annotations":[
                {"type":"url_citation","url":"https://example.test/source","title":"Источник"},
                {"type":"url_citation","url":"javascript:alert(1)","title":"Плохой"},
                {"type":"url_citation","url":"file:///secret","title":"Плохой"}
              ]},
              {"type":"output_text","text":"Второй факт.","annotations":[
                {"type":"url_citation","url":"https://example.test/source","title":"Дубликат"},
                {"type":"url_citation","url":"https://other.test/article?q=one","title":""}
              ]}
            ]}
          ]
        }
        """)
        defer { fixture.close() }
        let reply = try await fixture.reply(style: .responses)
        XCTAssertEqual(reply.text, "Первый факт.\nВторой факт.")
        XCTAssertEqual(reply.sources.map(\.title), ["Источник", "other.test"])
        XCTAssertEqual(reply.sources.map { $0.url.absoluteString }, ["https://example.test/source", "https://other.test/article?q=one"])
    }

    func testChatSupportsTextPartsAndNestedCitations() async throws {
        let fixture = Fixture(body: """
        {"choices":[{"message":{"content":[
          {"type":"text","text":"Один"},
          {"type":"text","text":"Два"}
        ],"annotations":[
          {"type":"url_citation","url_citation":{"url":"https://example.test/fact","title":"Факт","start_index":0,"end_index":3}}
        ]},"finish_reason":"stop"}]}
        """)
        defer { fixture.close() }
        let reply = try await fixture.reply()
        XCTAssertEqual(reply.text, "Один\nДва")
        XCTAssertEqual(reply.sources, [AssistantSource(title: "Факт", url: URL(string: "https://example.test/fact")!)])
    }

    func testRefusalsBecomeAnExplicitSpokenAnswer() async throws {
        for (style, body) in [
            (AssistantAPIStyle.chatCompletions, #"{"choices":[{"message":{"content":null,"refusal":"Не могу выполнить запрос."}}]}"#),
            (.responses, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Не могу выполнить запрос."}]}]}"#)
        ] {
            let fixture = Fixture(body: body)
            defer { fixture.close() }
            let reply = try await fixture.reply(style: style)
            XCTAssertEqual(reply.text, "Не могу выполнить запрос.")
        }
    }

    func testMalformedEmptyAndIncompleteResponsesNeverPretendToBeSuccessful() async throws {
        let cases: [(AssistantAPIStyle, String, AssistantClientError)] = [
            (.chatCompletions, "not JSON", .invalidResponse),
            (.chatCompletions, "{}", .invalidResponse),
            (.chatCompletions, #"{"choices":[]}"#, .emptyResponse),
            (.chatCompletions, #"{"choices":[{"message":{"content":"   "}}]}"#, .emptyResponse),
            (.chatCompletions, #"{"choices":[{"message":{"content":"Обрезанный ответ"},"finish_reason":"length"}]}"#, .incompleteResponse),
            (.chatCompletions, #"{"error":{"message":"SECRET provider body"}}"#, .failedResponse),
            (.responses, "{}", .invalidResponse),
            (.responses, #"{"status":"completed","output":[]}"#, .emptyResponse),
            (.responses, #"{"status":"incomplete","output_text":"Частичный ответ"}"#, .incompleteResponse),
            (.responses, #"{"status":"failed","error":{"message":"SECRET provider body"}}"#, .failedResponse),
            (.responses, #"{"status":"queued","output":[]}"#, .incompleteResponse)
        ]
        for (style, body, expected) in cases {
            let fixture = Fixture(body: body)
            defer { fixture.close() }
            do {
                _ = try await fixture.reply(style: style)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testHTTPFailuresHideProviderPayloadsAndCredentials() async throws {
        for status in [301, 400, 401, 403, 404, 408, 429, 500, 503, 504] {
            let fixture = Fixture(status: status, body: #"{"error":{"message":"SECRET fake-key"}}}"#)
            defer { fixture.close() }
            do {
                _ = try await fixture.reply()
                XCTFail("Expected failure for \(status)")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, .httpStatus(status))
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
                XCTAssertFalse(error.localizedDescription.contains("fake-key"))
            }
        }
    }

    func testNetworkFailuresHideTheUnderlyingURLAndErrorBody() async throws {
        let url = URL(string: "https://example.test/?token=SECRET")!
        let error = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "SECRET"
        ])
        let fixture = Fixture(failure: error)
        defer { fixture.close() }
        do {
            _ = try await fixture.reply()
            XCTFail("Expected network failure")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }

        let timeout = Fixture(failure: URLError(.timedOut))
        defer { timeout.close() }
        do {
            _ = try await timeout.reply()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .requestTimedOut)
        }
    }

    func testCancellationIsPreservedForAnInFlightRequest() async throws {
        let started = expectation(description: "Request began")
        let fixture = Fixture(waiting: started)
        defer { fixture.close() }
        let task = Task { try await fixture.reply() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testInvalidKeyAndEmptyConversationFailBeforeMakingARequest() async throws {
        let fixture = Fixture(body: #"{"choices":[{"message":{"content":"unused"}}]}"#)
        defer { fixture.close() }
        do {
            _ = try await fixture.client.reply(
                configuration: fixture.configuration(),
                apiKey: "fake\nkey",
                messages: [AssistantMessage(role: .user, text: "Привет")]
            )
            XCTFail("Expected invalid key")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .invalidAPIKey)
        }
        do {
            _ = try await fixture.client.reply(configuration: fixture.configuration(), apiKey: "", messages: [])
            XCTFail("Expected empty conversation")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .emptyConversation)
        }
        XCTAssertNil(fixture.request)
    }

    func testSavedSourcesCannotDecodeExecutableOrLocalURLs() throws {
        for url in ["javascript:alert(1)", "file:///tmp/file", "data:text/plain,secret", "https://user:password@example.test"] {
            let data = try JSONSerialization.data(withJSONObject: ["title": "Источник", "url": url])
            XCTAssertThrowsError(try JSONDecoder().decode(AssistantSource.self, from: data))
        }
        let valid = Data(#"{"title":"Источник","url":"https://example.test/article?q=hello"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AssistantSource.self, from: valid).url.host, "example.test")
    }

    #if canImport(Network)
    func testAnActualHTTPRedirectIsNotFollowed() async throws {
        let server = try RedirectServer()
        defer { server.stop() }
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = AssistantClient(session: session)
        let config = AssistantConfiguration(endpoint: "http://127.0.0.1:\(port)/v1", model: "test-model")
        do {
            _ = try await client.reply(
                configuration: config,
                apiKey: "fake-test-key",
                messages: [AssistantMessage(role: .user, text: "Тест")]
            )
            XCTFail("Expected a rejected redirect")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .httpStatus(302))
        }
        XCTAssertEqual(server.receivedPaths, ["/v1/chat/completions"])
    }
    #endif

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

private final class Fixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: URLSession
    let client: AssistantClient

    init(status: Int = 200, body: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = AssistantClient(session: session)
        StubURLProtocol.store.set(id: id, result: .response(status, Data(body.utf8)))
    }

    init(failure: URLError) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = AssistantClient(session: session)
        StubURLProtocol.store.set(id: id, result: .failure(failure))
    }

    init(waiting expectation: XCTestExpectation) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = AssistantClient(session: session)
        StubURLProtocol.store.set(id: id, result: .waiting(expectation))
    }

    var request: URLRequest? { StubURLProtocol.store.request(id: id) }

    func configuration(
        apiStyle: AssistantAPIStyle = .chatCompletions,
        systemPrompt: String = "Отвечай кратко",
        webSearchEnabled: Bool = false
    ) -> AssistantConfiguration {
        AssistantConfiguration(
            endpoint: "https://\(id).test/prefix",
            model: "test-model",
            apiStyle: apiStyle,
            systemPrompt: systemPrompt,
            webSearchEnabled: webSearchEnabled
        )
    }

    func reply(style: AssistantAPIStyle = .chatCompletions) async throws -> AssistantReply {
        try await client.reply(
            configuration: configuration(apiStyle: style),
            apiKey: "fake-key",
            messages: [AssistantMessage(role: .user, text: "Привет")]
        )
    }

    func close() {
        session.invalidateAndCancel()
        StubURLProtocol.store.remove(id: id)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Result: @unchecked Sendable {
        case response(Int, Data)
        case failure(URLError)
        case waiting(XCTestExpectation)
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: Result] = [:]
        private var requests: [String: URLRequest] = [:]

        func set(id: String, result: Result) {
            lock.lock()
            defer { lock.unlock() }
            results[id] = result
        }

        func capture(_ request: URLRequest) -> Result? {
            guard let id = request.url?.host?.split(separator: ".").first.map(String.init) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(&bytes, maxLength: bytes.count)
                    if read <= 0 { break }
                    data.append(contentsOf: bytes.prefix(read))
                }
                request.httpBody = data
            }
            requests[id] = request
            return results[id]
        }

        func request(id: String) -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests[id]
        }

        func remove(id: String) {
            lock.lock()
            defer { lock.unlock() }
            results[id] = nil
            requests[id] = nil
        }
    }

    static let store = Store()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.store.capture(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch result {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .waiting(let expectation):
            expectation.fulfill()
        }
    }

    override func stopLoading() {}
}

#if canImport(Network)
/// A loopback-only HTTP server exercises URLSession's real redirect handling.
/// No provider, external network, or real credentials are involved.
final class RedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var paths: [String] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var receivedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock()
            self.paths.append(path)
            self.lock.unlock()
            let body = #"{"choices":[{"message":{"content":"Redirect followed"}}]}"#
            let response: String
            if path == "/redirected" {
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            } else {
                response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(self.listener.port!.rawValue)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
