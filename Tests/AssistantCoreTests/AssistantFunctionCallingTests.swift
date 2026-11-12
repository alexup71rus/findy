import Foundation
import XCTest
@testable import AssistantCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AssistantFunctionCallingTests: XCTestCase, @unchecked Sendable {
    private let tool = AssistantToolDefinition(
        name: "manage_memory", description: "Explicit personal memory actions",
        parameters: .init(properties: [
            "action": .init("Action", values: ["save", "search"], maxLength: 10),
            "text": .init("Fact", maxLength: 100)
        ], required: ["action"])
    )

    func testChatJSONUsesTheRealToolResultAndKeepsHistoryAuthAndOrigin() async throws {
        for key in ["", "fake-tool-key"] {
            let fixture = try ToolWireFixture(scripts: [
                .json(chat(calls: [call("call-1", arguments: #"{"action":"save","text":"Люблю чай"}"#)])),
                .json(chat(text: "Запомнил: ты любишь чай."))
            ])
            defer { fixture.close() }
            let recorder = ToolRecorder()
            let reply = try await fixture.reply(tools: [tool], apiKey: key, handler: { call in
                await recorder.execute(call, output: #"{"saved":true,"memory_id":"local-42"}"#)
            })
            XCTAssertEqual(reply.text, "Запомнил: ты любишь чай.")
            let calls = await recorder.calls
            XCTAssertEqual(calls, [.init(callID: "call-1", name: "manage_memory", arguments: #"{"action":"save","text":"Люблю чай"}"#)])
            let requests = fixture.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.url == requests.first?.url })
            XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/custom/chat/completions" })
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == (key.isEmpty ? nil : "Bearer \(key)") })
            let first = try fixture.body(0)
            XCTAssertEqual(first["stream"] as? Bool, false)
            let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.first?["type"] as? String, "function")
            let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "manage_memory")
            XCTAssertEqual(function["strict"] as? Bool, false)
            XCTAssertNil(first["include"])
            let messages = try XCTUnwrap(try fixture.body(1)["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user", "assistant", "tool"])
            let requestedCalls = try XCTUnwrap(messages[4]["tool_calls"] as? [[String: Any]])
            XCTAssertEqual(requestedCalls.count, 1)
            XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call-1")
            XCTAssertEqual(messages.last?["content"] as? String, #"{"saved":true,"memory_id":"local-42"}"#)
        }
    }

    func testResponsesReplaysAllReasoningAndCombinesHostedSearchWithFunctions() async throws {
        let reasoning: [String: Any] = [
            "id": "rs_1", "type": "reasoning", "summary": [],
            "encrypted_content": "OPAQUE_NOT_USER_VISIBLE", "vendor_future_field": ["retained": true]
        ]
        let function: [String: Any] = [
            "id": "fc_1", "type": "function_call", "call_id": "call-1",
            "name": "manage_memory", "arguments": #"{"action":"search"}"#, "status": "completed"
        ]
        let fixture = try ToolWireFixture(scripts: [
            .json(["status": "completed", "output": [reasoning, ["type": "web_search_call", "id": "ws_1"], function]]),
            .json(responses(text: "Нашёл сохранённое предпочтение.", citation: true))
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        let localSource = AssistantSource(title: "Local result", url: URL(string: "https://example.test/local")!)
        let reply = try await fixture.reply(style: .responses, tools: [tool], webSearch: true, handler: { call in
            _ = await recorder.execute(call, output: #"{"matches":["Люблю чай"]}"#)
            return AssistantToolResult(output: #"{"matches":["Люблю чай"]}"#, sources: [localSource])
        })
        XCTAssertTrue(reply.usedWebSearch)
        XCTAssertEqual(reply.sources.map(\.url.absoluteString), ["https://example.test/local", "https://nasa.gov/fact"])
        XCTAssertFalse(reply.text.contains("OPAQUE"))
        let body = try fixture.body(1)
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["store"] as? Bool, false)
        let definitions = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(definitions.compactMap { $0["type"] as? String }, ["web_search", "function"])
        XCTAssertEqual(definitions[1]["name"] as? String, "manage_memory")
        XCTAssertNil(definitions[1]["function"])
        XCTAssertEqual(definitions[1]["strict"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 7)
        XCTAssertEqual(input[3]["encrypted_content"] as? String, "OPAQUE_NOT_USER_VISIBLE")
        XCTAssertEqual((input[3]["vendor_future_field"] as? [String: Bool])?["retained"], true)
        XCTAssertEqual(input[5]["call_id"] as? String, "call-1")
        XCTAssertEqual(input[6]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[6]["call_id"] as? String, "call-1")
        XCTAssertEqual(input[6]["output"] as? String, #"{"matches":["Люблю чай"]}"#)
    }

    func testChatSSEAssemblesArgumentChunksAndBuffersPrematureConfirmation() async throws {
        let initial = expectation(description: "Partial function arguments delivered")
        let first = try sse([
            ["choices": [["index": 0, "delta": ["content": "Уже запомнил!", "tool_calls": [[
                "index": 0, "id": "call-1", "type": "function",
                "function": ["name": "manage_memory", "arguments": #"{"action":"sa"#]
            ]]]]]],
            ["choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "function": ["arguments": #"ve","text":"Чай"}"#]
            ]]]]]]
        ])
        let terminal = try sse([["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]]) + "data: [DONE]\n\n"
        let final = try sse([
            ["choices": [["index": 0, "delta": ["content": "Запомнил после сохранения."]]]],
            ["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]
        ]) + "data: [DONE]\n\n"
        let fixture = try ToolWireFixture(scripts: [
            .sse(first, tail: terminal, delivered: initial), .sse(final)
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        let task = Task {
            try await fixture.reply(tools: [tool], onUpdate: { await recorder.update($0) }) { call in
                await recorder.execute(call, output: #"{"saved":true}"#)
            }
        }
        await fulfillment(of: [initial], timeout: 2)
        let before = await recorder.calls
        let earlyUpdates = await recorder.updates
        XCTAssertEqual(before, [])
        XCTAssertEqual(earlyUpdates, [])
        fixture.releaseFirstTail()
        let result = try await task.value
        XCTAssertEqual(result.text, "Запомнил после сохранения.")
        let calls = await recorder.calls
        XCTAssertEqual(calls.first?.arguments, #"{"action":"save","text":"Чай"}"#)
        let updates = await recorder.updates
        XCTAssertEqual(updates, [result])
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "text/event-stream" })
        XCTAssertEqual(try fixture.body(1)["stream"] as? Bool, true)
        let messages = try XCTUnwrap(try fixture.body(1)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages[4]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual((assistant[0]["function"] as? [String: Any])?["arguments"] as? String, #"{"action":"save","text":"Чай"}"#)
    }

    func testResponsesSSEKeepsEncryptedOutputAndConfirmsChunkedArguments() async throws {
        let arguments = #"{"action":"save","text":"Чай"}"#
        let reasoning: [String: Any] = ["id": "rs_1", "type": "reasoning", "summary": [], "encrypted_content": "OPAQUE"]
        let added: [String: Any] = [
            "id": "fc_1", "type": "function_call", "call_id": "call-1", "name": "manage_memory",
            "arguments": "", "status": "in_progress"
        ]
        var done = added
        done["arguments"] = arguments
        done["status"] = "completed"
        let events = try sse([
            ["type": "response.output_item.done", "output_index": 0, "item": reasoning],
            ["type": "response.output_item.added", "output_index": 1, "item": added],
            ["type": "response.function_call_arguments.delta", "output_index": 1, "item_id": "fc_1", "delta": #"{"action":"save","#],
            ["type": "response.function_call_arguments.delta", "output_index": 1, "item_id": "fc_1", "delta": #""text":"Чай"}"#],
            ["type": "response.function_call_arguments.done", "output_index": 1, "item_id": "fc_1", "arguments": arguments],
            ["type": "response.output_item.done", "output_index": 1, "item": done],
            // Some compatible services omit opaque fields in the final event.
            ["type": "response.completed", "response": ["status": "completed", "output": [
                ["id": "rs_1", "type": "reasoning", "summary": []], done
            ]]]
        ])
        let final = try sse([["type": "response.completed", "response": responses(text: "Сохранено.")]])
        let fixture = try ToolWireFixture(scripts: [.sse(events), .sse(final)])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        let reply = try await fixture.reply(style: .responses, tools: [tool], onUpdate: { await recorder.update($0) }) { call in
            await recorder.execute(call, output: #"{"saved":true}"#)
        }
        XCTAssertEqual(reply.text, "Сохранено.")
        let calls = await recorder.calls
        XCTAssertEqual(calls.first?.arguments, arguments)
        let input = try XCTUnwrap(try fixture.body(1)["input"] as? [[String: Any]])
        XCTAssertEqual(input[3]["encrypted_content"] as? String, "OPAQUE")
        XCTAssertEqual(input[4]["arguments"] as? String, arguments)
        XCTAssertEqual(input[5]["type"] as? String, "function_call_output")
        let updates = await recorder.updates
        XCTAssertEqual(updates, [reply])
    }

    func testStreamingJSONFallbackStillUsesOneRequestPerToolRound() async throws {
        let fixture = try ToolWireFixture(scripts: [
            .json(chat(calls: [call("call-1", arguments: #"{"action":"save"}"#)])),
            .json(chat(text: "Готово."))
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        let reply = try await fixture.reply(tools: [tool], onUpdate: { await recorder.update($0) }) { call in
            await recorder.execute(call, output: #"{"saved":true}"#)
        }
        XCTAssertEqual(fixture.requests.count, 2)
        let updates = await recorder.updates
        XCTAssertEqual(updates, [reply])
    }

    func testThrownToolFailureNeverPublishesModelSuccessOrRepeatsTheRequest() async throws {
        let fixture = try ToolWireFixture(scripts: [
            .json(chat(text: "Я сохранил всё!", calls: [call("call-1", arguments: #"{"action":"save"}"#)])),
            .json(chat(text: "This must not be requested"))
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        do {
            _ = try await fixture.reply(tools: [tool], onUpdate: { await recorder.update($0) }) { _ in
                throw NSError(domain: "SECRET", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake-tool-key SECRET"])
            }
            XCTFail("Expected failed execution")
        } catch {
            XCTAssertEqual(error as? AssistantToolLoopError, .executionFailed)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            XCTAssertFalse(error.localizedDescription.contains("fake-tool-key"))
        }
        let updates = await recorder.updates
        XCTAssertEqual(updates, [])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testIdenticalCallIDExecutesOnceAndReusesActualResultAcrossRounds() async throws {
        let fixture = try ToolWireFixture(scripts: [
            .json(chat(calls: [call("same-id", arguments: #"{"action":"save","text":"Чай"}"#)])),
            .json(chat(calls: [call("same-id", arguments: #"{"text":"Чай", "action":"save"}"#)])),
            .json(chat(text: "Готово."))
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        _ = try await fixture.reply(tools: [tool], handler: { call in
            await recorder.execute(call, output: #"{"saved":true,"id":"local-42"}"#)
        })
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        let last = try XCTUnwrap(try fixture.body(2)["messages"] as? [[String: Any]])
        XCTAssertEqual(last.suffix(4).compactMap { $0["role"] as? String }, ["assistant", "tool", "assistant", "tool"])
        XCTAssertEqual(last.last?["content"] as? String, #"{"saved":true,"id":"local-42"}"#)
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testChangedCallIDCannotRepeatASideEffect() async throws {
        let fixture = try ToolWireFixture(scripts: [
            .json(chat(calls: [call("same-id", arguments: #"{"action":"save","text":"Чай"}"#)])),
            .json(chat(calls: [call("same-id", arguments: #"{"action":"save","text":"Кофе"}"#)]))
        ])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        do {
            _ = try await fixture.reply(tools: [tool], handler: { call in await recorder.execute(call, output: "saved") })
            XCTFail("Expected changed call protection")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .changedCall) }
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testInvalidWholeBatchIsRejectedBeforeAnySideEffect() async throws {
        let badCalls = [
            call("bad", arguments: #"{"action":"delete"}"#),
            call("bad", arguments: #"{"text":"Missing action"}"#),
            call("bad", arguments: #"{"action":"save","unexpected":"key"}"#),
            call("bad", arguments: #"{"action":"save","text":null}"#),
            call("bad", arguments: "{"),
            call("bad", arguments: #"{"action":"save"}"#, name: "undeclared")
        ]
        for bad in badCalls {
            let fixture = try ToolWireFixture(scripts: [.json(chat(calls: [
                call("valid", arguments: #"{"action":"save"}"#), bad
            ]))])
            defer { fixture.close() }
            let recorder = ToolRecorder()
            do {
                _ = try await fixture.reply(tools: [tool], handler: { call in await recorder.execute(call, output: "saved") })
                XCTFail("Expected invalid tool batch")
            } catch {
                XCTAssertTrue(error is AssistantToolLoopError)
            }
            let calls = await recorder.calls
            XCTAssertEqual(calls, [])
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testLimitsBoundBothModelRoundsAndNewCallsWithoutExecutingUnreportableActions() async throws {
        let fixture = try ToolWireFixture(scripts: (0..<3).map { index in
            .json(chat(calls: [call("round-\(index)", arguments: #"{"action":"save"}"#)]))
        })
        defer { fixture.close() }
        let recorder = ToolRecorder()
        do {
            _ = try await fixture.reply(tools: [tool], handler: { call in await recorder.execute(call, output: "saved") })
            XCTFail("Expected bounded rounds")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .limitExceeded) }
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.callID), ["round-0", "round-1"])
        XCTAssertEqual(fixture.requests.count, 3)

        let tooMany = try ToolWireFixture(scripts: [.json(chat(calls: (0..<7).map {
            call("call-\($0)", arguments: #"{"action":"save"}"#)
        }))])
        defer { tooMany.close() }
        let noSideEffects = ToolRecorder()
        do {
            _ = try await tooMany.reply(tools: [tool], handler: { call in await noSideEffects.execute(call, output: "saved") })
            XCTFail("Expected bounded calls")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .limitExceeded) }
        let excessiveCalls = await noSideEffects.calls
        XCTAssertEqual(excessiveCalls, [])

        let acrossRounds = try ToolWireFixture(scripts: [
            .json(chat(calls: (0..<3).map { call("first-\($0)", arguments: #"{"action":"save"}"#) })),
            .json(chat(calls: (0..<4).map { call("second-\($0)", arguments: #"{"action":"save"}"#) }))
        ])
        defer { acrossRounds.close() }
        let boundedActions = ToolRecorder()
        do {
            _ = try await acrossRounds.reply(tools: [tool], handler: { call in await boundedActions.execute(call, output: "saved") })
            XCTFail("Expected cumulative call limit")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .limitExceeded) }
        let performed = await boundedActions.calls
        XCTAssertEqual(performed.map(\.callID), ["first-0", "first-1", "first-2"])
        XCTAssertEqual(acrossRounds.requests.count, 2)
    }

    func testIncompleteChatAndResponsesNeverExecutePartialCalls() async throws {
        let added: [String: Any] = [
            "id": "fc_1", "type": "function_call", "call_id": "call-1",
            "name": "manage_memory", "arguments": "", "status": "in_progress"
        ]
        let cases: [(AssistantAPIStyle, String)] = [
            (.chatCompletions, try sse([
                ["choices": [["index": 0, "delta": ["tool_calls": [[
                    "index": 0, "id": "call-1", "function": ["name": "manage_memory", "arguments": #"{"action":"save"}"#]
                ]]]]]],
                ["choices": [["index": 0, "delta": [:], "finish_reason": "length"]]]
            ])),
            (.responses, try sse([
                ["type": "response.output_item.added", "output_index": 0, "item": added],
                ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc_1", "delta": #"{"action":"save"}"#],
                ["type": "response.incomplete", "response": ["status": "incomplete", "output": []]]
            ]))
        ]
        for (style, events) in cases {
            let fixture = try ToolWireFixture(scripts: [.sse(events)])
            defer { fixture.close() }
            let recorder = ToolRecorder()
            do {
                _ = try await fixture.reply(style: style, tools: [tool], onUpdate: { await recorder.update($0) }) { call in
                    await recorder.execute(call, output: "saved")
                }
                XCTFail("Expected incomplete response")
            } catch { XCTAssertEqual(error as? AssistantClientError, .incompleteResponse) }
            let calls = await recorder.calls
            XCTAssertEqual(calls, [])
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testCancellationBeforeTerminalAndBetweenCallsPreventsFurtherActions() async throws {
        let delivered = expectation(description: "Partial call delivered")
        let events = try sse([["choices": [["index": 0, "delta": ["tool_calls": [[
            "index": 0, "id": "call-1", "function": ["name": "manage_memory", "arguments": #"{"action":"save"}"#]
        ]]]]]]])
        let fixture = try ToolWireFixture(scripts: [.sse(events, tail: "data: [DONE]\n\n", delivered: delivered)])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        let task = Task {
            try await fixture.reply(tools: [tool], onUpdate: { await recorder.update($0) }) { call in
                await recorder.execute(call, output: "saved")
            }
        }
        await fulfillment(of: [delivered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await recorder.calls
        XCTAssertEqual(calls, [])

        let second = try ToolWireFixture(scripts: [.json(chat(calls: [
            call("first", arguments: #"{"action":"save"}"#), call("second", arguments: #"{"action":"save"}"#)
        ]))])
        defer { second.close() }
        let actions = ToolRecorder()
        let actionTask = Task {
            try await second.reply(tools: [tool], handler: { call in
                _ = await actions.execute(call, output: "saved")
                withUnsafeCurrentTask { $0?.cancel() }
                return AssistantToolResult(output: "saved")
            })
        }
        do {
            _ = try await actionTask.value
            XCTFail("Expected canceled action chain")
        } catch { XCTAssertTrue(error is CancellationError) }
        let performed = await actions.calls
        XCTAssertEqual(performed.map(\.callID), ["first"])
        XCTAssertEqual(second.requests.count, 1)
    }

    func testUnsupportedProviderAndMissingHandlerFailClearlyWithoutRetries() async throws {
        let fixture = try ToolWireFixture(scripts: [.init(body: "SECRET provider body", status: 400)])
        defer { fixture.close() }
        do {
            _ = try await fixture.reply(tools: [tool], handler: { _ in .init(output: "must not run") })
            XCTFail("Expected unsupported tools HTTP failure")
        } catch {
            XCTAssertEqual(error as? AssistantClientError, .httpStatus(400))
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
        XCTAssertEqual(fixture.requests.count, 1)
        let missing = try ToolWireFixture(scripts: [.json(chat(text: "must not be requested"))])
        defer { missing.close() }
        do {
            _ = try await missing.reply(tools: [tool])
            XCTFail("Expected absent tool handler")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .handlerMissing) }
        XCTAssertEqual(missing.requests.count, 0)
    }

    func testMismatchedStreamArgumentsNeverReachTheHandler() async throws {
        let fixture = try ToolWireFixture(scripts: [.sse(try sse([
            ["type": "response.output_item.added", "output_index": 0, "item": [
                "type": "function_call", "id": "fc_1", "call_id": "call-1",
                "name": "manage_memory", "arguments": "", "status": "in_progress"
            ]],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc_1", "delta": #"{"action":"save"}"#],
            ["type": "response.function_call_arguments.done", "output_index": 0, "item_id": "fc_1", "arguments": #"{"action":"search"}"#]
        ]))])
        defer { fixture.close() }
        let recorder = ToolRecorder()
        do {
            _ = try await fixture.reply(style: .responses, tools: [tool], onUpdate: { await recorder.update($0) }) { call in
                await recorder.execute(call, output: "must not run")
            }
            XCTFail("Expected argument corruption rejection")
        } catch { XCTAssertEqual(error as? AssistantToolLoopError, .invalidCall) }
        let calls = await recorder.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private func call(_ id: String, arguments: String, name: String = "manage_memory") -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }

    private func chat(text: String? = nil, calls: [[String: Any]] = []) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text.map { $0 as Any } ?? NSNull()]
        if !calls.isEmpty { message["tool_calls"] = calls }
        return ["choices": [["index": 0, "message": message, "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]]]
    }

    private func responses(text: String, citation: Bool = false) -> [String: Any] {
        var part: [String: Any] = ["type": "output_text", "text": text]
        if citation { part["annotations"] = [["type": "url_citation", "url": "https://nasa.gov/fact", "title": "NASA"]] }
        return ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [part]]]]
    }

    private func sse(_ events: [[String: Any]]) throws -> String {
        try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    }
}

private actor ToolRecorder {
    var calls: [AssistantToolCall] = []
    var updates: [AssistantReply] = []
    func execute(_ call: AssistantToolCall, output: String) -> AssistantToolResult {
        calls.append(call)
        return AssistantToolResult(output: output)
    }
    func update(_ reply: AssistantReply) { updates.append(reply) }
}

private final class ToolWireFixture: @unchecked Sendable {
    private let id = UUID().uuidString.lowercased()
    private let session: URLSession
    private let client: AssistantClient

    init(scripts: [ToolWireProtocol.Script]) throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolWireProtocol.self]
        session = URLSession(configuration: config)
        client = AssistantClient(session: session)
        ToolWireProtocol.store.register(id, scripts: scripts)
    }

    var requests: [URLRequest] { ToolWireProtocol.store.requests(id) }
    func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[index].httpBody)) as? [String: Any])
    }

    func reply(
        style: AssistantAPIStyle = .chatCompletions,
        tools: [AssistantToolDefinition],
        apiKey: String = "fake-tool-key",
        webSearch: Bool = false,
        onUpdate: (@Sendable (AssistantReply) async -> Void)? = nil,
        handler: AssistantToolHandler? = nil
    ) async throws -> AssistantReply {
        try await client.reply(
            configuration: .init(endpoint: "http://\(id).test/custom", model: "test-model", apiStyle: style, systemPrompt: "Кратко", webSearchEnabled: webSearch),
            apiKey: apiKey,
            messages: [
                .init(role: .user, text: "Предыдущее сообщение"),
                .init(role: .assistant, text: "Предыдущий ответ"),
                .init(role: .user, text: "Запомни, что я люблю чай")
            ],
            tools: tools, toolHandler: handler, onUpdate: onUpdate
        )
    }

    func releaseFirstTail() { ToolWireProtocol.store.firstTransport(id)?.releaseTail() }
    func close() {
        session.invalidateAndCancel()
        ToolWireProtocol.store.remove(id)
    }
}

private final class ToolWireProtocol: URLProtocol, @unchecked Sendable {
    struct Script: @unchecked Sendable {
        let body: String
        var status = 200
        var contentType = "application/json"
        var tail: String?
        var delivered: XCTestExpectation?
        static func json(_ body: [String: Any]) -> Self {
            .init(body: String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
        static func sse(_ body: String, tail: String? = nil, delivered: XCTestExpectation? = nil) -> Self {
            .init(body: body, contentType: "text/event-stream", tail: tail, delivered: delivered)
        }
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [String: [Script]] = [:]
        private var recorded: [String: [URLRequest]] = [:]
        private var first: [String: ToolWireProtocol] = [:]
        func register(_ id: String, scripts: [Script]) { locked { self.scripts[id] = scripts } }
        func begin(_ request: URLRequest, transport: ToolWireProtocol) -> Script? {
            guard let id = request.url?.host?.split(separator: ".").first.map(String.init) else { return nil }
            return locked {
                var request = request
                if request.httpBody == nil, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    request.httpBody = data
                }
                let index = recorded[id, default: []].count
                recorded[id, default: []].append(request)
                if first[id] == nil { first[id] = transport }
                guard let scripts = scripts[id], scripts.indices.contains(index) else { return nil }
                return scripts[index]
            }
        }
        func requests(_ id: String) -> [URLRequest] { locked { recorded[id] ?? [] } }
        func firstTransport(_ id: String) -> ToolWireProtocol? { locked { first[id] } }
        func remove(_ id: String) { locked { scripts[id] = nil; recorded[id] = nil; first[id] = nil } }
        private func locked<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    static let store = Store()
    private let delivery = DispatchQueue(label: "Findy.ToolWireFixture")
    private let stopLock = NSLock()
    private var stopped = false
    private var script: Script?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        delivery.async { [self] in
            guard !isStopped else { return }
            guard let script = Self.store.begin(request, transport: self) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.script = script
            let response = HTTPURLResponse(
                url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": script.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Split the body across actual transport callbacks too.
            let data = Data(script.body.utf8)
            let middle = data.count / 2
            client?.urlProtocol(self, didLoad: Data(data[..<middle]))
            client?.urlProtocol(self, didLoad: Data(data[middle...]))
            script.delivered?.fulfill()
            if script.tail == nil { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    func releaseTail() {
        delivery.async { [self] in
            guard !isStopped, let tail = script?.tail else { return }
            client?.urlProtocol(self, didLoad: Data(tail.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }
    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }
}
