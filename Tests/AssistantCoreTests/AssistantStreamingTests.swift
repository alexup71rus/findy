import Foundation
import XCTest
@testable import AssistantCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AssistantStreamingTests: XCTestCase, @unchecked Sendable {
    func testChatPublishesUTF8DeltasBeforeTheHTTPResponseFinishes() async throws {
        let firstDelta = expectation(description: "First delta arrived before terminal data was released")
        let recorder = StreamingRecorder(firstText: firstDelta)
        let initial = """
        : keepalive\r
        id: 1\r
        data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}\r
        \r
        data: {"choices":[{"index":0,"delta":{"content":"При"}}]}\r
        \r
        """
        let initialBytes = Data(initial.utf8)
        let split = try XCTUnwrap(initialBytes.range(of: Data("При".utf8))).lowerBound + 1
        let tail = """
        data: {"choices":[{"index":1,"delta":{"content":"IGNORE OTHER CHOICE"}}]}

        data: {"choices":[{"index":0,"delta":{"content":"вет!"}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"total_tokens":10}}

        data: [DONE]


        """
        let fixture = StreamingFixture(
            initial: [Data(initialBytes[..<split]), Data(initialBytes[split...])],
            tail: [Data(tail.utf8)],
            finishImmediately: false
        )
        defer { fixture.close() }
        let task = Task {
            try await fixture.reply { await recorder.record($0) }
        }
        await fulfillment(of: [firstDelta], timeout: 2)
        XCTAssertFalse(fixture.didFinishSending)
        let early = await recorder.updates
        XCTAssertEqual(early.map(\.text), ["При"])
        fixture.releaseTail()
        let reply = try await task.value
        XCTAssertEqual(reply, AssistantReply(text: "Привет!"))
        let updates = await recorder.updates
        XCTAssertEqual(updates.map(\.text), ["При", "Привет!"])
        let request = try XCTUnwrap(fixture.request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-stream-key")
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testResponsesAggregateTypedEventsCitationsAndActualSearchWithoutExposingReasoning() async throws {
        let events = """
        event: response.created
        data: {"type":"response.created","response":{"status":"in_progress","output":[]}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call","status":"in_progress"}}

        data: {"type":"response.reasoning_summary_text.delta","delta":{"private":"SECRET REASONING"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta",
        data: "output_index":1,"content_index":0,"delta":"Факт "}

        data: {"type":"response.output_text.annotation.added","output_index":1,"content_index":0,"annotation":{"type":"url_citation","url":"https://nasa.gov/fact","title":"NASA"}}

        data: {"type":"response.output_text.annotation.added","output_index":1,"content_index":0,"annotation":{"type":"url_citation","url":"javascript:alert(1)","title":"Unsafe"}}

        data: {"type":"response.output_text.delta","output_index":1,"content_index":0,"delta":"подтверждён."}

        data: {"type":"response.output_text.done","output_index":1,"content_index":0,"text":"Факт подтверждён."}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"Факт подтверждён.","annotations":[{"type":"url_citation","url":"https://nasa.gov/fact","title":"NASA"},{"type":"url_citation","url":"https://example.org/other","title":"Другой источник"}]}]}]}}


        """
        let fixture = StreamingFixture(body: events)
        defer { fixture.close() }
        let recorder = StreamingRecorder()
        let reply = try await fixture.reply(style: .responses) { await recorder.record($0) }
        XCTAssertEqual(reply.text, "Факт подтверждён.")
        XCTAssertTrue(reply.usedWebSearch)
        XCTAssertEqual(reply.sources.map(\.url.absoluteString), ["https://nasa.gov/fact", "https://example.org/other"])
        let updates = await recorder.updates
        XCTAssertTrue(updates.contains { $0.usedWebSearch && $0.text.isEmpty })
        XCTAssertTrue(updates.contains { $0.text == "Факт" && $0.sources.count == 1 })
        XCTAssertEqual(updates.last, reply)
        XCTAssertFalse(updates.contains { $0.text.contains("SECRET") || $0.sources.contains { $0.title == "Unsafe" } })
    }

    func testResponsesDonePartsAndItemSnapshotsDoNotDuplicateText() async throws {
        let events = """
        data: {"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}

        data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Первая."}

        data: {"type":"response.content_part.done","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Первая.","annotations":[]}}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Первая."}]}}

        data: {"type":"response.output_text.delta","output_index":0,"content_index":1,"delta":"Вторая."}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Первая."},{"type":"output_text","text":"Вторая."}]}]}}


        """
        let fixture = StreamingFixture(body: events)
        defer { fixture.close() }
        let recorder = StreamingRecorder()
        let reply = try await fixture.reply(style: .responses) { await recorder.record($0) }
        XCTAssertEqual(reply.text, "Первая.\nВторая.")
        XCTAssertFalse(reply.usedWebSearch)
        let updates = await recorder.updates
        XCTAssertEqual(updates.map(\.text), ["Первая.", "Первая.\nВторая."])
    }

    func testSearchStartCallbackRequiresActualSearchEventAndFiresOnce() async throws {
        let started = expectation(description: "search began")
        started.expectedFulfillmentCount = 1
        started.assertForOverFulfill = true
        let fixture = StreamingFixture(body: """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call","status":"in_progress"}}

        data: {"type":"response.web_search_call.in_progress","output_index":0}

        data: {"type":"response.web_search_call.searching","output_index":0}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Готово"}]}]}}

        """)
        defer { fixture.close() }
        _ = try await fixture.reply(style: .responses, onWebSearchStarted: { started.fulfill() }) { _ in }
        await fulfillment(of: [started], timeout: 1)

        let notStarted = expectation(description: "an announced item is not a search start")
        notStarted.isInverted = true
        let announcedOnly = StreamingFixture(body: """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"web_search_call","status":"in_progress"}}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Готово"}]}]}}

        """)
        defer { announcedOnly.close() }
        _ = try await announcedOnly.reply(style: .responses, onWebSearchStarted: { notStarted.fulfill() }) { _ in }
        await fulfillment(of: [notStarted], timeout: 0.1)
    }

    func testJSONFallbackUsesTheSameResponseAndNeverRepeatsThePOST() async throws {
        for (style, body) in [
            (AssistantAPIStyle.chatCompletions, #"{"choices":[{"message":{"content":"Обычный JSON"}}]}"#),
            (.responses, #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Обычный JSON"}]}]}"#)
        ] {
            let fixture = StreamingFixture(body: body, contentType: "application/json; charset=utf-8")
            defer { fixture.close() }
            let recorder = StreamingRecorder()
            let reply = try await fixture.reply(style: style) { await recorder.record($0) }
            XCTAssertEqual(reply.text, "Обычный JSON")
            let updates = await recorder.updates
            XCTAssertEqual(updates, [reply])
            XCTAssertEqual(fixture.requestCount, 1)
        }
        let fixture = StreamingFixture(body: #"{"choices":[{"message":{"content":"Not SSE"}}]}"#)
        defer { fixture.close() }
        do {
            _ = try await fixture.reply { _ in }
            XCTFail("SSE content type must not invoke the JSON fallback")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .incompleteResponse)
        }
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testTerminalStreamErrorsRejectPartialAnswersAndHideProviderDetails() async throws {
        let cases: [(AssistantAPIStyle, String, AssistantClientError)] = [
            (.chatCompletions, #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#, .incompleteResponse),
            (.chatCompletions, #"data: {"error":{"message":"SECRET provider error"}}"#, .failedResponse),
            (.responses, #"data: {"type":"response.failed","response":{"status":"failed","error":{"message":"SECRET provider error"},"output":[]}}"#, .failedResponse),
            (.responses, #"data: {"type":"response.incomplete","response":{"status":"incomplete","output":[]}}"#, .incompleteResponse),
            (.responses, "event: error\ndata: SECRET provider error", .failedResponse),
            (.responses, #"data: {"type":"error","message":"SECRET provider error"}"#, .failedResponse)
        ]
        for (style, terminal, expected) in cases {
            let prelude = style == .chatCompletions
                ? #"data: {"choices":[{"index":0,"delta":{"content":"Частичный ответ."}}]}"#
                : #"data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Частичный ответ."}"#
            let fixture = StreamingFixture(body: prelude + "\n\n" + terminal + "\n\n")
            defer { fixture.close() }
            let recorder = StreamingRecorder()
            do {
                _ = try await fixture.reply(style: style) { await recorder.record($0) }
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
            let updates = await recorder.updates
            XCTAssertEqual(updates.first?.text, "Частичный ответ.")
            XCTAssertEqual(fixture.requestCount, 1)
        }
    }

    func testEOFRequiresASuccessfulTerminalEvent() async throws {
        for (style, body) in [
            (AssistantAPIStyle.chatCompletions, #"data: {"choices":[{"index":0,"delta":{"content":"Не завершено"}}]}"#),
            (.chatCompletions, #"data: {"choices":[{"index":0,"delta":{"content":"Не завершено"}}]}"# + "\n\ndata: [DONE]"),
            (.responses, #"data: {"type":"response.output_text.done","output_index":0,"content_index":0,"text":"Не завершено"}"#)
        ] {
            let fixture = StreamingFixture(body: body + "\n\n")
            defer { fixture.close() }
            do {
                _ = try await fixture.reply(style: style) { _ in }
                XCTFail("Expected incomplete stream")
            } catch {
                XCTAssertEqual(error as? AssistantClientError, .incompleteResponse)
            }
        }
        let complete = StreamingFixture(body: """
        data: {"choices":[{"index":0,"delta":{"content":"Готово"},"finish_reason":"stop"}]}
        """)
        defer { complete.close() }
        let reply = try await complete.reply { _ in }
        XCTAssertEqual(reply.text, "Готово")
    }

    func testCancellationAfterADeltaCancelsTheUnderlyingNetworkTask() async throws {
        let firstDelta = expectation(description: "First delta")
        let stopped = expectation(description: "URLSession stopped its transport")
        let fixture = StreamingFixture(
            initial: [Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Начало\"}}]}\n\n".utf8)],
            tail: [],
            finishImmediately: false,
            stopped: stopped
        )
        defer { fixture.close() }
        let recorder = StreamingRecorder(firstText: firstDelta)
        let task = Task { try await fixture.reply { await recorder.record($0) } }
        await fulfillment(of: [firstDelta], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testSSEFramingAcceptsBOMCRLFAndRejectsOversizedEventsAndInvalidUTF8() throws {
        var parser = AssistantSSEParser()
        var events: [AssistantSSEEvent] = []
        let input = "\u{FEFF}: heartbeat\r\nevent: custom\r\ndata: one\r\ndata: two\r\n\r\n"
        for byte in input.utf8 {
            if let event = try parser.append(byte) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, "custom")
        XCTAssertEqual(events.first?.data, "one\ntwo")

        var oversized = AssistantSSEParser()
        XCTAssertThrowsError(try (0...AssistantStreamLimits.maximumEventBytes).forEach { _ in _ = try oversized.append(65) }) {
            XCTAssertEqual($0 as? AssistantClientError, .invalidResponse)
        }
        var invalid = AssistantSSEParser()
        XCTAssertThrowsError(try [UInt8](arrayLiteral: 100, 97, 116, 97, 58, 255, 10).forEach { _ = try invalid.append($0) }) {
            XCTAssertEqual($0 as? AssistantClientError, .invalidResponse)
        }
    }

    func testStreamingHTTPFailuresAndRealtimeAreRejectedWithoutExtraRequests() async throws {
        let fixture = StreamingFixture(body: "SECRET provider body", status: 401)
        defer { fixture.close() }
        let recorder = StreamingRecorder()
        do {
            _ = try await fixture.reply { await recorder.record($0) }
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        let updates = await recorder.updates
        XCTAssertEqual(updates, [])
        XCTAssertEqual(fixture.requestCount, 1)

        let realtime = StreamingFixture(body: "")
        defer { realtime.close() }
        do {
            _ = try await realtime.reply(style: .realtime) { _ in }
            XCTFail("HTTP text client must reject Realtime explicitly")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .unsupportedAPIStyle)
        }
        XCTAssertEqual(realtime.requestCount, 0)
    }

    #if canImport(Network)
    func testStreamingAlsoRejectsRealCrossOriginRedirects() async throws {
        let server = try RedirectServer()
        defer { server.stop() }
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AssistantClient(session: session).reply(
                configuration: AssistantConfiguration(endpoint: "http://127.0.0.1:\(port)/v1", model: "test-model"),
                apiKey: "fake-stream-key",
                messages: [AssistantMessage(role: .user, text: "Тест")],
                onUpdate: { _ in }
            )
            XCTFail("Expected rejected redirect")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .httpStatus(302))
        }
        XCTAssertEqual(server.receivedPaths, ["/v1/chat/completions"])
    }
    #endif
}

private actor StreamingRecorder {
    private(set) var updates: [AssistantReply] = []
    private let firstText: XCTestExpectation?
    private var fulfilled = false

    init(firstText: XCTestExpectation? = nil) {
        self.firstText = firstText
    }

    func record(_ reply: AssistantReply) {
        updates.append(reply)
        if !fulfilled, !reply.text.isEmpty {
            fulfilled = true
            firstText?.fulfill()
        }
    }
}

private final class StreamingFixture: @unchecked Sendable {
    private let id = UUID().uuidString.lowercased()
    private let session: URLSession
    private let client: AssistantClient

    convenience init(body: String, contentType: String = "text/event-stream; charset=utf-8", status: Int = 200) {
        self.init(initial: [Data(body.utf8)], tail: [], finishImmediately: true, contentType: contentType, status: status)
    }

    init(
        initial: [Data],
        tail: [Data],
        finishImmediately: Bool,
        contentType: String = "text/event-stream; charset=utf-8",
        status: Int = 200,
        stopped: XCTestExpectation? = nil
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingURLProtocol.self]
        session = URLSession(configuration: config)
        client = AssistantClient(session: session)
        StreamingURLProtocol.store.register(id: id, script: .init(
            initial: initial, tail: tail, finishImmediately: finishImmediately,
            contentType: contentType, status: status, stopped: stopped
        ))
    }

    var request: URLRequest? { StreamingURLProtocol.store.request(id: id) }
    var requestCount: Int { StreamingURLProtocol.store.count(id: id) }
    var didFinishSending: Bool { StreamingURLProtocol.store.finished(id: id) }

    func reply(
        style: AssistantAPIStyle = .chatCompletions,
        onWebSearchStarted: (@Sendable () async -> Void)? = nil,
        onUpdate: @escaping @Sendable (AssistantReply) async -> Void
    ) async throws -> AssistantReply {
        try await client.reply(
            configuration: AssistantConfiguration(endpoint: "https://\(id).test/v1", model: "test-model", apiStyle: style),
            apiKey: "fake-stream-key",
            messages: [AssistantMessage(role: .user, text: "Тест")],
            onWebSearchStarted: onWebSearchStarted,
            onUpdate: onUpdate
        )
    }

    func releaseTail() { StreamingURLProtocol.store.transport(id: id)?.releaseTail() }

    func close() {
        session.invalidateAndCancel()
        StreamingURLProtocol.store.remove(id: id)
    }
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: @unchecked Sendable {
        let initial: [Data]
        let tail: [Data]
        let finishImmediately: Bool
        let contentType: String
        let status: Int
        let stopped: XCTestExpectation?
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [String: Script] = [:]
        private var requests: [String: URLRequest] = [:]
        private var counts: [String: Int] = [:]
        private var finishedIDs = Set<String>()
        private var stoppedIDs = Set<String>()
        private var transports: [String: StreamingURLProtocol] = [:]

        func register(id: String, script: Script) {
            lock.lock()
            defer { lock.unlock() }
            scripts[id] = script
        }

        func begin(_ request: URLRequest, transport: StreamingURLProtocol) -> Script? {
            guard let id = request.url?.host?.split(separator: ".").first.map(String.init) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            var copy = request
            if copy.httpBody == nil, let stream = copy.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                copy.httpBody = data
            }
            requests[id] = copy
            counts[id, default: 0] += 1
            transports[id] = transport
            return scripts[id]
        }

        func request(id: String) -> URLRequest? { withLock { requests[id] } }
        func count(id: String) -> Int { withLock { counts[id] ?? 0 } }
        func finished(id: String) -> Bool { withLock { finishedIDs.contains(id) } }
        func transport(id: String) -> StreamingURLProtocol? { withLock { transports[id] } }
        func markFinished(id: String) { _ = withLock { finishedIDs.insert(id) } }

        func markStopped(id: String) {
            let expectation: XCTestExpectation? = withLock {
                stoppedIDs.insert(id).inserted ? scripts[id]?.stopped : nil
            }
            expectation?.fulfill()
        }

        func remove(id: String) {
            withLock {
                scripts[id] = nil
                requests[id] = nil
                counts[id] = nil
                transports[id] = nil
                finishedIDs.remove(id)
                stoppedIDs.remove(id)
            }
        }

        private func withLock<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    static let store = Store()
    private let delivery = DispatchQueue(label: "Findy.StreamingFixture")
    private let stopLock = NSLock()
    private var stopped = false
    private var script: Script?
    private var id: String { request.url?.host?.split(separator: ".").first.map(String.init) ?? "" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        delivery.async { [self] in
            guard !isStopped, let script = Self.store.begin(request, transport: self) else { return }
            self.script = script
            let response = HTTPURLResponse(
                url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": script.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in script.initial where !isStopped { client?.urlProtocol(self, didLoad: chunk) }
            if script.finishImmediately { complete() }
        }
    }

    func releaseTail() {
        delivery.async { [self] in
            guard !isStopped, let script else { return }
            for chunk in script.tail where !isStopped { client?.urlProtocol(self, didLoad: chunk) }
            complete()
        }
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
        Self.store.markStopped(id: id)
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func complete() {
        guard !isStopped else { return }
        Self.store.markFinished(id: id)
        client?.urlProtocolDidFinishLoading(self)
    }
}
