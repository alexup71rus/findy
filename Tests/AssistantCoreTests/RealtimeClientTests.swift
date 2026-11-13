import Foundation
import XCTest
@testable import AssistantCore

final class RealtimeClientTests: XCTestCase {
    private func config(search: Bool = false) -> AssistantConfiguration {
        AssistantConfiguration(
            endpoint: "https://example.test/custom/v1/responses",
            model: "gpt-realtime-2.1-mini", apiStyle: .realtime,
            webSearchEnabled: search, realtimeVoice: "cedar"
        )
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func event(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testFarewellResponseKeepsSessionVoiceAndHasTurnMetadata() throws {
        let turn = UUID()
        let normal = try object(RealtimeWire.voiceResponse(turn: turn))
        let normalResponse = try XCTUnwrap(normal["response"] as? [String: Any])
        XCTAssertEqual((normalResponse["metadata"] as? [String: String])?["findy_voice_turn"], turn.uuidString)
        XCTAssertNil(normalResponse["instructions"])
        let root = try object(RealtimeWire.farewellResponse(phrase: "До свидания!", turn: turn))
        XCTAssertEqual(root["type"] as? String, "response.create")
        let response = try XCTUnwrap(root["response"] as? [String: Any])
        let cancel = try object(RealtimeWire.cancelResponse(id: "stale-response"))
        XCTAssertEqual(cancel["type"] as? String, "response.cancel")
        XCTAssertEqual(cancel["response_id"] as? String, "stale-response")
        XCTAssertNil(response["audio"])
        XCTAssertNil(response["model"])
        XCTAssertNil(response["output_modalities"])
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        XCTAssertEqual((response["input"] as? [Any])?.count, 0)
        XCTAssertNil(response["conversation"])
        XCTAssertEqual((response["metadata"] as? [String: String])?["findy_farewell_turn"], turn.uuidString)
        XCTAssertTrue((response["instructions"] as? String)?.contains("До свидания!") == true)
        var decoder = RealtimeEventDecoder()
        let payload = try JSONSerialization.data(withJSONObject: ["type": "response.created", "response": ["id": "farewell-id", "metadata": ["findy_farewell_turn": turn.uuidString]]])
        XCTAssertEqual(try decoder.decode(payload), [.farewellResponseStarted(id: "farewell-id", turn: turn.uuidString)])
        let regular = try JSONSerialization.data(withJSONObject: ["type": "response.created", "response": ["id": "voice-id", "metadata": ["findy_voice_turn": turn.uuidString]]])
        XCTAssertEqual(try decoder.decode(regular), [.voiceResponseStarted(id: "voice-id", turn: turn.uuidString)])
    }

    func testManualVoiceResponsesAreOptInForNativeVoiceOnly() throws {
        func vad(_ manual: Bool) throws -> [String: Any] {
            let root = try object(RealtimeWire.sessionUpdate(configuration: config(), outputAudio: true, manualVoiceResponses: manual))
            let session = try XCTUnwrap(root["session"] as? [String: Any])
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            return try XCTUnwrap(input["turn_detection"] as? [String: Any])
        }
        XCTAssertEqual(try vad(false)["create_response"] as? Bool, true)
        XCTAssertEqual(try vad(true)["create_response"] as? Bool, false)
        XCTAssertEqual(try vad(true)["interrupt_response"] as? Bool, true)
    }

    func testWebSocketRequestPreservesPrefixAndOmitsAuthorizationWhenEmpty() throws {
        let request = try RealtimeWire.request(configuration: config(), apiKey: "")
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "example.test")
        XCTAssertEqual(request.url?.path, "/custom/v1/realtime")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "model", value: "gpt-realtime-2.1-mini")])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testLocalConnectionAndModelQueryEncodingAndCredentialValidation() throws {
        var configuration = config()
        configuration.endpoint = "http://localhost:9000/v1/realtime/"
        configuration.model = " custom/model&query=value "
        let request = try RealtimeWire.request(configuration: configuration, apiKey: "  fake-test-key  ")
        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertEqual(request.url?.port, 9000)
        XCTAssertEqual(request.url?.path, "/v1/realtime")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "model", value: "custom/model&query=value")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-key")
        XCTAssertThrowsError(try RealtimeWire.request(configuration: configuration, apiKey: "fake\r\nX-Secret: value")) {
            XCTAssertEqual($0 as? AssistantClientError, .invalidAPIKey)
        }
        configuration.apiStyle = .responses
        XCTAssertThrowsError(try RealtimeWire.request(configuration: configuration, apiKey: ""))
    }

    func testVoiceSessionConfiguresNativeAudioVADAndTranscriptionSeparately() throws {
        let root = try object(RealtimeWire.sessionUpdate(configuration: config(), outputAudio: true, manualVoiceResponses: true))
        XCTAssertEqual(root["type"] as? String, "session.update")
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(session["max_output_tokens"] as? Int, 1_024)
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "cedar")
        for side in [input, output] {
            let format = try XCTUnwrap(side["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "audio/pcm")
            XCTAssertEqual(format["rate"] as? Int, 24_000)
        }
        let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 650)
        XCTAssertEqual(vad["create_response"] as? Bool, false)
        XCTAssertEqual(vad["interrupt_response"] as? Bool, true)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["ru"])
        XCTAssertEqual((session["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(session["tool_choice"] as? String, "none")
    }

    func testTextOnlySessionHasNoAutomaticAudioTurnsOrTranscription() throws {
        let root = try object(RealtimeWire.sessionUpdate(configuration: config(), outputAudio: false))
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertNil(input["transcription"])
    }

    func testVoicePreviewIsPlaybackOnlyAndIgnoresConversationPromptAndSearch() throws {
        var configuration = config(search: true)
        configuration.systemPrompt = "PRIVATE_CONVERSATION_PROMPT"
        let data = try RealtimeWire.voicePreviewSessionUpdate(configuration: configuration)
        let root = try object(data)
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(configuration.systemPrompt))
        XCTAssertEqual(session["model"] as? String, configuration.model)
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual((session["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(session["tool_choice"] as? String, "none")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertNil(input["transcription"])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "cedar")
        XCTAssertEqual((output["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    }

    func testVoicePreviewRequestsOnlyAnExactPhraseOutsideConversation() throws {
        let phrase = "Привет! Я Cedar. Чем займёмся?"
        let root = try object(RealtimeWire.voicePreviewResponse(phrase: phrase))
        XCTAssertEqual(root["type"] as? String, "response.create")
        let response = try XCTUnwrap(root["response"] as? [String: Any])
        XCTAssertEqual(response["conversation"] as? String, "none")
        XCTAssertEqual((response["input"] as? [Any])?.count, 0)
        XCTAssertEqual(response["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        XCTAssertEqual((response["tools"] as? [Any])?.count, 0)
        XCTAssertTrue((response["instructions"] as? String)?.contains(phrase) == true)
        XCTAssertEqual(response["max_output_tokens"] as? Int, 512)
        XCTAssertThrowsError(try RealtimeWire.voicePreviewResponse(phrase: ""))
        XCTAssertThrowsError(try RealtimeWire.voicePreviewResponse(phrase: String(repeating: "я", count: 301)))
    }

    func testVoicePreviewRequiresServerConfirmationOfExactVoice() throws {
        func confirmation(_ voice: String) throws -> Data {
            try event(["type": "session.updated", "session": ["audio": ["output": ["voice": voice]]]])
        }
        XCTAssertNoThrow(try RealtimeWire.validatePreviewVoice(confirmation("cedar"), expected: "cedar"))
        XCTAssertThrowsError(try RealtimeWire.validatePreviewVoice(confirmation("alloy"), expected: "cedar")) {
            XCTAssertEqual($0 as? RealtimeClientError, .sessionRejected(code: "voice_not_confirmed"))
        }
        XCTAssertThrowsError(try RealtimeWire.validatePreviewVoice(event(["type": "session.updated"]), expected: "cedar"))
        XCTAssertNoThrow(try RealtimeWire.validatePreviewVoice(event(["type": "session.created"]), expected: "cedar"))
    }

    func testCancelledPreviewDoesNotConnectAndClosedClientCannotRequestSample() async throws {
        let client = RealtimeClient()
        let configuration = config()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.connect(configuration: configuration, apiKey: "", outputAudio: true, voicePreview: true) { _ in }
        }
        do { try await task.value; XCTFail("Cancelled preview connected") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.close()
        await client.close()
        do { try await client.requestVoicePreview("Привет! Я Cedar. Чем займёмся?"); XCTFail("Closed preview requested audio") }
        catch { XCTAssertEqual(error as? RealtimeClientError, .notConnected) }
    }

    func testSearchIsAnExplicitFunctionWithBoundedJSONArguments() throws {
        let root = try object(RealtimeWire.sessionUpdate(configuration: config(search: true), outputAudio: true))
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "web_search")
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        let parameters = try XCTUnwrap(tools[0]["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["query"])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["query"])
    }

    func testHistoryAndFunctionOutputUseCorrectConversationItemTypes() throws {
        for role in [AssistantMessage.Role.user, .assistant] {
            let root = try object(RealtimeWire.message(AssistantMessage(role: role, text: "Привет!")))
            XCTAssertEqual(root["type"] as? String, "conversation.item.create")
            let item = try XCTUnwrap(root["item"] as? [String: Any])
            XCTAssertEqual(item["role"] as? String, role.rawValue)
            let content = try XCTUnwrap(item["content"] as? [[String: Any]])
            XCTAssertEqual(content[0]["type"] as? String, role == .user ? "input_text" : "output_text")
            XCTAssertEqual(content[0]["text"] as? String, "Привет!")
        }
        let root = try object(RealtimeWire.functionOutput(callID: "call_one", output: #"{"answer":"found"}"#))
        XCTAssertEqual(root["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(root["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_one")
        XCTAssertEqual(item["output"] as? String, #"{"answer":"found"}"#)
    }

    func testInterruptionTruncatesOnlyPlayedAudioAndRejectsNegativeDuration() throws {
        let root = try object(RealtimeWire.truncate(itemID: "assistant_one", contentIndex: 0, audioEndMilliseconds: 1_250))
        XCTAssertEqual(root["type"] as? String, "conversation.item.truncate")
        XCTAssertEqual(root["item_id"] as? String, "assistant_one")
        XCTAssertEqual(root["content_index"] as? Int, 0)
        XCTAssertEqual(root["audio_end_ms"] as? Int, 1_250)
        XCTAssertThrowsError(try RealtimeWire.truncate(itemID: "assistant_one", contentIndex: 0, audioEndMilliseconds: -1))
    }

    func testTranscriptDeltasAreCumulativeAndFinalTextCorrectsPartialText() throws {
        var decoder = RealtimeEventDecoder()
        XCTAssertEqual(try decoder.decode(event([
            "type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "Как "
        ])), [.inputTranscript(itemID: "u1", text: "Как ", isFinal: false)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "дела"
        ])), [.inputTranscript(itemID: "u1", text: "Как дела", isFinal: false)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "Как дела?"
        ])), [.inputTranscript(itemID: "u1", text: "Как дела?", isFinal: true)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Хорошо"
        ])), [.outputTranscript(itemID: "a1", text: "Хорошо", isFinal: false)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Хорошо!"
        ])), [.outputTranscript(itemID: "a1", text: "Хорошо!", isFinal: true)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_text.delta", "item_id": "a2", "delta": "Текст"
        ])), [.outputTranscript(itemID: "a2", text: "Текст", isFinal: false)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_text.done", "item_id": "a2", "text": "Текст."
        ])), [.outputTranscript(itemID: "a2", text: "Текст.", isFinal: true)])
    }

    func testNativePCMAndVADEventsAreDecodedWithoutAudioConversion() throws {
        var decoder = RealtimeEventDecoder()
        XCTAssertEqual(try decoder.decode(event(["type": "session.updated"])), [.ready])
        XCTAssertEqual(try decoder.decode(event(["type": "input_audio_buffer.speech_started", "item_id": "u1"])), [.speechStarted(itemID: "u1")])
        XCTAssertEqual(try decoder.decode(event(["type": "input_audio_buffer.speech_stopped", "item_id": "u1"])), [.speechStopped(itemID: "u1")])
        XCTAssertEqual(try decoder.decode(event(["type": "response.created", "response": ["id": "r1"]])), [.responseStarted(id: "r1")])
        let pcm = Data([0x00, 0x00, 0xff, 0x7f, 0x00, 0x80])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_audio.delta", "item_id": "a1", "content_index": 0, "delta": pcm.base64EncodedString()
        ])), [.audioDelta(itemID: "a1", contentIndex: 0, pcm16: pcm)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_audio.done", "item_id": "a1", "content_index": 0
        ])), [.audioDone(itemID: "a1", contentIndex: 0)])
        for value in ["bad base64!", Data([1]).base64EncodedString()] {
            XCTAssertThrowsError(try decoder.decode(event([
                "type": "response.output_audio.delta", "item_id": "a1", "delta": value
            ]))) { XCTAssertEqual($0 as? RealtimeClientError, .invalidAudio) }
        }
    }

    func testAssistantItemIsIdentifiedBeforeAudioButFunctionItemsAreNotMessages() throws {
        var decoder = RealtimeEventDecoder()
        XCTAssertEqual(try decoder.decode(event([
            "type": "response.output_item.added", "response_id": "r1",
            "item": ["id": "a1", "type": "message", "role": "assistant", "content": []]
        ])), [.outputItemStarted(responseID: "r1", itemID: "a1")])
        XCTAssertTrue(try decoder.decode(event([
            "type": "response.output_item.added", "response_id": "r1",
            "item": ["id": "fc1", "type": "function_call", "call_id": "call1", "name": "web_search"]
        ])).isEmpty)
        XCTAssertThrowsError(try decoder.decode(event([
            "type": "response.output_item.added", "response_id": "r1",
            "item": ["type": "message", "role": "assistant"]
        ]))) { XCTAssertEqual($0 as? RealtimeClientError, .invalidEvent) }
    }

    func testCompletedFunctionsExecuteOnceAndCancelledPartialCallsNeverExecute() throws {
        var decoder = RealtimeEventDecoder()
        let call: [String: Any] = [
            "type": "function_call", "call_id": "call_1", "name": "web_search", "arguments": #"{"query":"новости"}"#
        ]
        XCTAssertTrue(try decoder.decode(event([
            "type": "response.function_call_arguments.done", "call_id": "call_1", "name": "web_search", "arguments": #"{"query":"новости"}"#
        ])).isEmpty)
        let cancelled = try decoder.decode(event([
            "type": "response.done", "response": ["id": "r0", "status": "cancelled", "output": [call]]
        ]))
        XCTAssertEqual(cancelled.count, 1)
        guard case .responseDone(let completion) = cancelled[0] else { return XCTFail("Missing completion") }
        XCTAssertEqual(completion.status, .cancelled)
        let complete = try event([
            "type": "response.done", "response": ["id": "r1", "status": "completed", "output": [call]]
        ])
        let first = try decoder.decode(complete)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0], .functionCall(responseID: "r1", call: RealtimeFunctionCall(callID: "call_1", name: "web_search", arguments: #"{"query":"новости"}"#)))
        XCTAssertEqual(try decoder.decode(complete).count, 1)
    }

    func testResponseDoneSuppliesFinalTextUsageAndFailureStatus() throws {
        var decoder = RealtimeEventDecoder()
        let events = try decoder.decode(event([
            "type": "response.done", "response": [
                "id": "r1", "status": "incomplete", "output": [[
                    "type": "message", "id": "a1", "content": [["type": "output_text", "text": "Начало"]]
                ]],
                "status_details": ["error": ["code": "context_length_exceeded", "message": "never expose me"]],
                "usage": ["input_tokens": 10, "output_tokens": 20,
                          "input_token_details": ["cached_tokens": 3, "audio_tokens": 5],
                          "output_token_details": ["audio_tokens": 12]]
            ]
        ]))
        XCTAssertEqual(events.first, .outputTranscript(itemID: "a1", text: "Начало", isFinal: true))
        guard case .responseDone(let completion) = events.last else { return XCTFail("Missing completion") }
        XCTAssertEqual(completion.id, "r1")
        XCTAssertEqual(completion.status, .incomplete)
        XCTAssertFalse(completion.hasFunctionCalls)
        XCTAssertEqual(completion.error, .sessionRejected(code: "context_length_exceeded"))
        XCTAssertEqual(completion.usage, RealtimeUsage(inputTokens: 10, outputTokens: 20, cachedInputTokens: 3, inputAudioTokens: 5, outputAudioTokens: 12))
    }

    func testCompletedMalformedFunctionCallFailsInsteadOfContinuingWithoutItsOutput() throws {
        var decoder = RealtimeEventDecoder()
        let calls: [[String: Any]] = [
            ["type": "function_call", "name": "web_search", "arguments": "{}"],
            ["type": "function_call", "call_id": "one", "name": "", "arguments": "{}"],
            ["type": "function_call", "call_id": "one", "name": "web_search"]
        ]
        for call in calls {
            XCTAssertThrowsError(try decoder.decode(event([
                "type": "response.done", "response": ["id": "r1", "status": "completed", "output": [call]]
            ]))) { XCTAssertEqual($0 as? RealtimeClientError, .invalidEvent) }
        }
    }

    func testServiceErrorsNeverEchoServerMessagesOrArbitraryCodes() throws {
        var decoder = RealtimeEventDecoder()
        for code in ["sk-private-key", "https://secret.example/api?key=hidden"] {
            let result = try decoder.decode(event([
                "type": "error", "error": ["code": code, "message": "secret body with credentials"]
            ]))
            XCTAssertEqual(result, [.failure(.sessionRejected(code: "unknown_error"))])
        }
        XCTAssertEqual(try decoder.decode(event([
            "type": "error", "error": ["code": "invalid_api_key", "message": "secret"]
        ])), [.failure(.authenticationFailed)])
        XCTAssertEqual(try decoder.decode(event([
            "type": "error", "error": ["code": "rate_limit_exceeded", "message": "secret"]
        ])), [.failure(.rateLimited)])
        XCTAssertTrue(try decoder.decode(event([
            "type": "error", "error": ["code": "response_cancel_not_active"]
        ])).isEmpty)
    }

    func testConfigurationDiagnosticsPreserveSafeCodesAndOnlyExactKnownParameters() throws {
        var decoder = RealtimeEventDecoder()
        XCTAssertEqual(try decoder.decode(event([
            "type": "error", "error": [
                "code": "unsupported_transcription_model",
                "param": "session.audio.input.transcription.model",
                "message": "secret server message"
            ]
        ])), [.failure(.sessionRejected(code: "unsupported_transcription_model; session.audio.input.transcription.model"))])
        XCTAssertEqual(try decoder.decode(event([
            "type": "error", "error": ["code": "transcription_model_not_supported", "param": "audio.input.transcription.languages"]
        ])), [.failure(.sessionRejected(code: "transcription_model_not_supported; audio.input.transcription.languages"))])
        for code in ["unsupported_API_SECRET", "invalid_key-secret", "session_echo\nsecret", "private_credentials", "invalid_" + String(repeating: "x", count: 100)] {
            XCTAssertEqual(try decoder.decode(event([
                "type": "error", "error": ["code": code, "param": "session.audio.input.transcription.model?secret"]
            ])), [.failure(.sessionRejected(code: "unknown_error"))])
        }
        for parameter in ["session.audio.output.voice.secret", "session.api_key", "https://secret.example", "audio.input.turn_detection.threshold=secret"] {
            XCTAssertEqual(try decoder.decode(event([
                "type": "error", "error": ["code": "invalid_session_update", "param": parameter]
            ])), [.failure(.sessionRejected(code: "invalid_session_update"))])
        }
    }

    func testMalformedAndOversizedEventsFailAndUnknownLifecycleEventsAreIgnored() throws {
        var decoder = RealtimeEventDecoder()
        XCTAssertThrowsError(try decoder.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? RealtimeClientError, .invalidEvent)
        }
        XCTAssertThrowsError(try decoder.decode(Data(repeating: 0x20, count: RealtimeWire.maximumEventBytes + 1))) {
            XCTAssertEqual($0 as? RealtimeClientError, .eventTooLarge)
        }
        XCTAssertThrowsError(try decoder.decode(event([
            "type": "response.output_text.delta", "item_id": "a1",
            "delta": String(repeating: "x", count: RealtimeWire.maximumTranscriptBytes + 1)
        ]))) { XCTAssertEqual($0 as? RealtimeClientError, .eventTooLarge) }
        XCTAssertTrue(try decoder.decode(event(["type": "rate_limits.updated", "rate_limits": []])).isEmpty)
        XCTAssertEqual(try decoder.decode(event([
            "type": "conversation.item.input_audio_transcription.failed", "item_id": "u1"
        ])), [.inputTranscriptionFailed(itemID: "u1")])
    }
}

final class ImageSettingsTests: XCTestCase {
    func testImageModelPersistsAndOpenAIOriginIsStrict() throws {
        var provider = AssistantProvider(name: "OpenAI", endpoint: "https://api.openai.com/v1", models: ["chat"])
        provider.imageModel = "gpt-image-2"
        let restored = try JSONDecoder().decode(AssistantProvider.self, from: JSONEncoder().encode(provider))
        XCTAssertEqual(restored.configuration(for: "chat").imageModel, "gpt-image-2")
        XCTAssertTrue(restored.configuration(for: "chat").supportsImageGeneration)
        for endpoint in ["http://api.openai.com/v1", "https://api.openai.com.evil.test/v1", "https://api.openai.com:444/v1", "https://user@api.openai.com/v1"] {
            provider.endpoint = endpoint
            XCTAssertFalse(provider.configuration(for: "chat").supportsImageGeneration)
        }
    }
    func testLegacyProviderGetsDefaultImageModel() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"OpenAI","endpoint":"https://api.openai.com/v1","apiStyle":"responses","models":["chat"]}"#
        let provider = try JSONDecoder().decode(AssistantProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.imageModel, "gpt-image-2.5-flare")
    }
}
