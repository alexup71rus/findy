import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias RealtimeFunctionCall = AssistantToolCall

public struct RealtimeUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let inputAudioTokens: Int
    public let outputAudioTokens: Int
}

public struct RealtimeResponseCompletion: Equatable, Sendable {
    public enum Status: String, Sendable { case completed, cancelled, failed, incomplete, unknown }
    public let id: String
    public let status: Status
    public let hasFunctionCalls: Bool
    public let usage: RealtimeUsage?
    public let error: RealtimeClientError?
}

public enum RealtimeEvent: Equatable, Sendable {
    case ready
    case speechStarted(itemID: String)
    case speechStopped(itemID: String)
    /// Text is cumulative for this item, including for partial events.
    case inputTranscript(itemID: String, text: String, isFinal: Bool)
    case responseStarted(id: String)
    /// Emitted before audio/transcript deltas so an interruption can identify
    /// an assistant message even before its first audio buffer arrives.
    case outputItemStarted(responseID: String, itemID: String)
    case audioDelta(itemID: String, contentIndex: Int, pcm16: Data)
    case audioDone(itemID: String, contentIndex: Int)
    /// Includes both audio transcripts and text-only model responses.
    case outputTranscript(itemID: String, text: String, isFinal: Bool)
    case functionCall(RealtimeFunctionCall)
    case responseDone(RealtimeResponseCompletion)
    case contextPruned(removed: Int, retainedMessages: Int)
    case failure(RealtimeClientError)
}

public enum RealtimeClientError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case connectionFailed
    case connectionTimedOut
    case invalidAudio
    case invalidEvent
    case eventTooLarge
    case authenticationFailed
    case rateLimited
    case serverError
    case sessionRejected(code: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Голосовая сессия Realtime не подключена."
        case .connectionFailed: return "Не удалось подключиться к Realtime. Проверьте интернет, адрес API и доступ к модели."
        case .connectionTimedOut: return "Realtime не подтвердил подключение вовремя."
        case .invalidAudio: return "Не удалось подготовить звук для Realtime."
        case .invalidEvent: return "Realtime вернул событие неподдерживаемого формата."
        case .eventTooLarge: return "Realtime превысил допустимый размер ответа."
        case .authenticationFailed: return "Realtime отклонил ключ API или доступ к модели."
        case .rateLimited: return "Realtime сообщил об ограничении запросов или баланса."
        case .serverError: return "Ошибка на стороне сервиса Realtime."
        case .sessionRejected(let code): return "Realtime отклонил параметры сессии (\(code))."
        }
    }
}

/// A single explicit Realtime session. Closing or cancelling never reconnects or
/// retries: every new connection can create a separately billable session.
public actor RealtimeClient {
    public typealias EventHandler = @Sendable (RealtimeEvent) async -> Void

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var onEvent: EventHandler?
    private var connectionID: UUID?
    private var decoder = RealtimeEventDecoder()
    private var responseIsActive = false
    private var ready = false
    private var contextWindow = RealtimeConversationWindow()
    private var contextMessageCount = AssistantLimits.contextMessageDefault

    public init() {}

    public func connect(
        configuration: AssistantConfiguration,
        apiKey: String,
        history: [AssistantMessage] = [],
        outputAudio: Bool,
        tools: [AssistantToolDefinition] = [],
        onEvent: @escaping EventHandler
    ) async throws {
        try Task.checkCancellation()
        guard socket == nil else { throw RealtimeClientError.sessionRejected(code: "already_connected") }
        let request = try RealtimeWire.request(configuration: configuration, apiKey: apiKey)
        let update = try RealtimeWire.sessionUpdate(configuration: configuration, outputAudio: outputAudio, tools: tools)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 3_600
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration, delegate: RealtimeRejectRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = RealtimeWire.maximumEventBytes
        let id = UUID()
        self.session = session
        self.socket = socket
        self.connectionID = id
        self.onEvent = onEvent
        self.decoder = RealtimeEventDecoder()
        self.contextMessageCount = AssistantLimits.normalizedContextMessageCount(configuration.contextMessageCount)
        socket.resume()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    readyContinuation = continuation
                    receiveTask = Task { [weak self] in await self?.receiveLoop(id: id, socket: socket) }
                    connectTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        await self?.fail(.connectionTimedOut, id: id)
                    }
                    Task { [weak self] in
                        do { try await self?.sendSetup(update, id: id) }
                        catch { await self?.fail(Self.sanitized(error), id: id) }
                    }
                }
                try Task.checkCancellation()
                guard connectionID == id else { throw CancellationError() }
                // Reconnects restore only bounded text history. Raw recordings
                // are never cached by this transport.
                for message in AssistantContext.recent(history, limit: contextMessageCount) {
                    try Task.checkCancellation()
                    guard connectionID == id else { throw CancellationError() }
                    try await send(RealtimeWire.message(message))
                }
                try Task.checkCancellation()
                guard connectionID == id else { throw CancellationError() }
                await onEvent(.ready)
            } onCancel: {
                Task { await self.cancelConnection(id: id) }
            }
        } catch {
            if connectionID == id { close() }
            throw error
        }
    }

    /// Await each append from one bounded microphone consumer. This method does
    /// not enqueue tasks or accumulate unsent microphone data.
    public func appendAudio(_ pcm16: Data) async throws {
        guard ready else { throw RealtimeClientError.notConnected }
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2), pcm16.count <= 192_000 else {
            throw RealtimeClientError.invalidAudio
        }
        try await send(RealtimeWire.json(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]))
    }

    public func sendText(_ text: String) async throws {
        guard ready else { throw RealtimeClientError.notConnected }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AssistantClientError.emptyConversation }
        try await send(RealtimeWire.message(AssistantMessage(role: .user, text: value)))
        try await requestResponse()
    }

    /// The application owns execution and tool permissions. A tool result does
    /// not itself trigger another response; call requestResponse afterwards.
    public func submitFunctionOutput(callID: String, output: String) async throws {
        guard ready else { throw RealtimeClientError.notConnected }
        try await send(RealtimeWire.functionOutput(callID: callID, output: output))
    }

    public func requestResponse() async throws {
        guard ready else { throw RealtimeClientError.notConnected }
        try await send(RealtimeWire.json(["type": "response.create"]))
    }

    public func updateInstructions(_ instructions: String) async throws {
        guard ready else { throw RealtimeClientError.notConnected }
        let update = try RealtimeWire.json(["type": "session.update", "session": ["type": "realtime", "instructions": Self.conversationInstructions(instructions)]])
        try await send(update)
    }

    public static func conversationInstructions(_ base: String) -> String {
        base + "\nГовори естественно, спокойно и без дикторской подачи. Не произноси URL, адреса сайтов, номера сносок и список источников; источники отображаются отдельно на экране. Для актуальных сведений используй web_search, если он доступен. Не утверждай, что выполнил поиск, без результата инструмента."
    }

    public func cancelResponse() async throws {
        guard ready, responseIsActive else { return }
        responseIsActive = false
        try await send(RealtimeWire.json(["type": "response.cancel"]))
    }

    public func truncate(itemID: String, contentIndex: Int = 0, audioEndMilliseconds: Int) async throws {
        guard ready else { return }
        try await send(RealtimeWire.truncate(itemID: itemID, contentIndex: contentIndex, audioEndMilliseconds: audioEndMilliseconds))
    }

    /// Idempotent immediate cleanup. No silence or keepalive audio is sent.
    public func close() {
        connectionID = nil
        ready = false
        responseIsActive = false
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        onEvent = nil
        decoder = RealtimeEventDecoder()
        contextWindow = RealtimeConversationWindow()
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let socket, connectionID != nil else { throw RealtimeClientError.notConnected }
        guard data.count <= RealtimeWire.maximumEventBytes,
              let text = String(data: data, encoding: .utf8) else { throw RealtimeClientError.eventTooLarge }
        do {
            try await socket.send(.string(text))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.sanitized(error, response: socket.response)
        }
    }

    private func sendSetup(_ data: Data, id: UUID) async throws {
        guard connectionID == id else { throw CancellationError() }
        try await send(data)
    }

    private func cancelConnection(id: UUID) {
        guard connectionID == id else { return }
        close()
    }

    private func receiveLoop(id: UUID, socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, connectionID == id {
                let message = try await socket.receive()
                guard connectionID == id else { return }
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: throw RealtimeClientError.invalidEvent
                }
                try contextWindow.observe(data)
                let events = try decoder.decode(data)
                for event in events {
                    guard connectionID == id else { return }
                    if event == .ready {
                        ready = true
                        connectTimeout?.cancel()
                        connectTimeout = nil
                        readyContinuation?.resume()
                        readyContinuation = nil
                        continue
                    }
                    if case .failure(let error) = event {
                        await fail(error, id: id)
                        return
                    }
                    if case .responseStarted = event { responseIsActive = true }
                    if case .responseDone = event { responseIsActive = false }
                    // Awaiting the consumer supplies backpressure for received
                    // audio; there is no unbounded AsyncStream buffer.
                    await onEvent?(event)
                }
                if events.contains(where: { if case .responseDone = $0 { return true }; return false }) {
                    let removed = contextWindow.removeOlderItems(limit: contextMessageCount)
                    for itemID in removed {
                        try await send(RealtimeWire.json(["type": "conversation.item.delete", "item_id": itemID]))
                    }
                    if !removed.isEmpty { await onEvent?(.contextPruned(removed: removed.count, retainedMessages: contextWindow.messageCount)) }
                }
            }
        } catch {
            guard connectionID == id, !Task.isCancelled else { return }
            await fail(Self.sanitized(error, response: socket.response), id: id)
        }
    }

    private func fail(_ error: RealtimeClientError, id: UUID) async {
        guard connectionID == id else { return }
        let callback = onEvent
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        close()
        await callback?(.failure(error))
    }

    private static func sanitized(_ error: any Error, response: URLResponse? = nil) -> RealtimeClientError {
        if let error = error as? RealtimeClientError { return error }
        if let response = response as? HTTPURLResponse {
            switch response.statusCode {
            case 401, 403: return .authenticationFailed
            case 429: return .rateLimited
            case 500...599: return .serverError
            default: break
            }
        }
        if (error as? URLError)?.code == .timedOut { return .connectionTimedOut }
        return .connectionFailed
    }
}

private final class RealtimeRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum RealtimeWire {
    static let maximumEventBytes = 4 * 1_024 * 1_024
    static let maximumTranscriptBytes = 512 * 1_024

    static func request(configuration: AssistantConfiguration, apiKey: String) throws -> URLRequest {
        guard configuration.apiStyle == .realtime else { throw RealtimeClientError.sessionRejected(code: "select_realtime_api") }
        guard apiKey.rangeOfCharacter(from: .controlCharacters) == nil else { throw AssistantClientError.invalidAPIKey }
        let endpoint = try configuration.validatedEndpoint()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AssistantClientError.invalidEndpoint
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines))]
        guard let url = components.url else { throw AssistantClientError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func sessionUpdate(configuration: AssistantConfiguration, outputAudio: Bool, tools: [AssistantToolDefinition] = []) throws -> Data {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "turn_detection": outputAudio ? [
                "type": "server_vad",
                "prefix_padding_ms": 300, "silence_duration_ms": 650,
                "create_response": true, "interrupt_response": true
            ] as [String: Any] : NSNull()
        ]
        if outputAudio {
            // Transcription is for display only. The Realtime model reasons
            // directly over the incoming audio, not this separate transcript.
            input["transcription"] = ["model": "gpt-transcribe", "languages": ["ru"]]
        }
        var session: [String: Any] = [
            "type": "realtime",
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "output_modalities": outputAudio ? ["audio"] : ["text"],
            "instructions": RealtimeClient.conversationInstructions(configuration.systemPrompt),
            "max_output_tokens": 1_024,
            "audio": [
                "input": input,
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": configuration.realtimeVoice
                ]
            ]
        ]
        var wireTools: [[String: Any]] = try tools.map {
            guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? [String: Any] else {
                throw RealtimeClientError.invalidEvent
            }
            return value
        }
        if configuration.webSearchEnabled {
            wireTools.append([
                "type": "function",
                "name": "web_search",
                "description": "Найти актуальные сведения в интернете. Возвращает краткий результат и ссылки на источники. Используй для свежих фактов и когда пользователь просит поискать или проверить информацию.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "Самодостаточный поисковый запрос на языке пользователя."]],
                    "required": ["query"], "additionalProperties": false
                ]
            ])
        }
        session["tools"] = wireTools
        session["tool_choice"] = wireTools.isEmpty ? "none" : "auto"
        return try json(["type": "session.update", "session": session])
    }

    static func message(_ message: AssistantMessage) throws -> Data {
        guard message.text.utf8.count <= maximumTranscriptBytes else { throw RealtimeClientError.eventTooLarge }
        return try json([
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": message.role.rawValue,
                "content": [["type": message.role == .user ? "input_text" : "output_text", "text": message.text]]
            ]
        ])
    }

    static func functionOutput(callID: String, output: String) throws -> Data {
        guard !callID.isEmpty, output.utf8.count <= maximumTranscriptBytes else { throw RealtimeClientError.eventTooLarge }
        return try json([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output]
        ])
    }

    static func truncate(itemID: String, contentIndex: Int, audioEndMilliseconds: Int) throws -> Data {
        guard !itemID.isEmpty, contentIndex >= 0, audioEndMilliseconds >= 0 else { throw RealtimeClientError.invalidEvent }
        return try json([
            "type": "conversation.item.truncate", "item_id": itemID,
            "content_index": contentIndex, "audio_end_ms": audioEndMilliseconds
        ])
    }

    static func json(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumEventBytes else { throw RealtimeClientError.eventTooLarge }
        return data
    }

    static func serviceError(_ object: [String: Any]?) -> RealtimeClientError {
        let code = object?["code"] as? String ?? object?["type"] as? String ?? "unknown_error"
        switch code {
        case "invalid_api_key", "authentication_error", "permission_denied", "model_not_found": return .authenticationFailed
        case "rate_limit_exceeded", "insufficient_quota", "rate_limit_error": return .rateLimited
        case "server_error", "internal_error": return .serverError
        default:
            // Never surface arbitrary server messages: a compatible endpoint
            // might echo the key, URL or user's conversation in its error body.
            let knownCodes: Set<String> = [
                "invalid_value", "invalid_request_error", "invalid_parameter", "unknown_parameter",
                "missing_required_parameter", "unsupported_parameter", "unsupported_value", "invalid_type",
                "unsupported_model", "context_length_exceeded", "audio_unintelligible",
                "conversation_already_has_active_response", "input_audio_buffer_commit_empty"
            ]
            let diagnosticPrefixes = [
                "invalid_", "unsupported_", "transcription_", "audio_", "session_",
                "model_", "input_", "output_", "voice_"
            ]
            let isDiagnosticCode = diagnosticPrefixes.contains(where: code.hasPrefix)
                && code.range(of: "^[a-z][a-z0-9_]{0,95}$", options: .regularExpression) != nil
            let safeCode = knownCodes.contains(code) || isDiagnosticCode ? code : "unknown_error"
            let fields = [
                "type", "model", "output_modalities", "max_output_tokens",
                "audio.input.format", "audio.input.format.type", "audio.input.format.rate",
                "audio.input.transcription", "audio.input.transcription.model",
                "audio.input.transcription.language", "audio.input.transcription.languages",
                "audio.input.transcription.prompt", "audio.input.transcription.keywords", "audio.input.transcription.delay",
                "audio.input.noise_reduction", "audio.input.noise_reduction.type",
                "audio.input.turn_detection", "audio.input.turn_detection.type",
                "audio.input.turn_detection.threshold", "audio.input.turn_detection.prefix_padding_ms",
                "audio.input.turn_detection.silence_duration_ms", "audio.input.turn_detection.create_response",
                "audio.input.turn_detection.interrupt_response",
                "audio.output.voice", "audio.output.format", "audio.output.format.type", "audio.output.format.rate"
            ]
            let knownParameters = Set(fields + fields.map { "session." + $0 })
            if let parameter = object?["param"] as? String, knownParameters.contains(parameter) {
                return .sessionRejected(code: safeCode + "; " + parameter)
            }
            return .sessionRejected(code: safeCode)
        }
    }
}

struct RealtimeEventDecoder {
    private var transcripts: [String: String] = [:]
    private var finalTranscripts = Set<String>()
    private var seenCalls = Set<String>()

    mutating func decode(_ data: Data) throws -> [RealtimeEvent] {
        guard data.count <= RealtimeWire.maximumEventBytes else { throw RealtimeClientError.eventTooLarge }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw RealtimeClientError.invalidEvent }
        let itemID = event["item_id"] as? String ?? ""
        let contentIndex = event["content_index"] as? Int ?? 0
        switch type {
        case "session.updated": return [.ready]
        case "input_audio_buffer.speech_started": return [.speechStarted(itemID: try required(itemID))]
        case "input_audio_buffer.speech_stopped": return [.speechStopped(itemID: try required(itemID))]
        case "conversation.item.input_audio_transcription.delta":
            return [try transcript(event, itemID: itemID, input: true, final: false)]
        case "conversation.item.input_audio_transcription.completed":
            return [try transcript(event, itemID: itemID, input: true, final: true)]
        case "conversation.item.input_audio_transcription.failed":
            // Display transcription failure does not invalidate native audio.
            return []
        case "response.created":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String else {
                throw RealtimeClientError.invalidEvent
            }
            return [.responseStarted(id: id)]
        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String else {
                throw RealtimeClientError.invalidEvent
            }
            guard itemType == "message" else { return [] }
            guard let responseID = event["response_id"] as? String,
                  let id = item["id"] as? String else { throw RealtimeClientError.invalidEvent }
            return [.outputItemStarted(responseID: try required(responseID), itemID: try required(id))]
        case "response.output_audio.delta":
            guard let value = event["delta"] as? String, let audio = Data(base64Encoded: value),
                  !audio.isEmpty, audio.count.isMultiple(of: 2), contentIndex >= 0 else { throw RealtimeClientError.invalidAudio }
            return [.audioDelta(itemID: try required(itemID), contentIndex: contentIndex, pcm16: audio)]
        case "response.output_audio.done": return [.audioDone(itemID: try required(itemID), contentIndex: contentIndex)]
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            return [try transcript(event, itemID: itemID, input: false, final: false)]
        case "response.output_audio_transcript.done", "response.output_text.done":
            return [try transcript(event, itemID: itemID, input: false, final: true)]
        case "response.done": return try responseDone(event)
        case "error":
            let error = event["error"] as? [String: Any]
            // server_vad may have already cancelled the same response.
            if error?["code"] as? String == "response_cancel_not_active" { return [] }
            return [.failure(RealtimeWire.serviceError(error))]
        default: return []
        }
    }

    private mutating func transcript(_ event: [String: Any], itemID: String, input: Bool, final: Bool) throws -> RealtimeEvent {
        _ = try required(itemID)
        let key = (input ? "input:" : "output:") + itemID
        let text: String
        if final {
            guard let value = event["transcript"] as? String ?? event["text"] as? String else { throw RealtimeClientError.invalidEvent }
            text = value
            finalTranscripts.insert(key)
        } else {
            guard let delta = event["delta"] as? String else { throw RealtimeClientError.invalidEvent }
            text = (transcripts[key] ?? "") + delta
        }
        guard text.utf8.count <= RealtimeWire.maximumTranscriptBytes else { throw RealtimeClientError.eventTooLarge }
        transcripts[key] = text
        // A one-hour session has bounded transport bookkeeping even if the UI
        // chooses to retain more history of its own.
        if transcripts.count > 256 {
            transcripts = [key: text]
            finalTranscripts = final ? [key] : []
        }
        return input ? .inputTranscript(itemID: itemID, text: text, isFinal: final) : .outputTranscript(itemID: itemID, text: text, isFinal: final)
    }

    private mutating func responseDone(_ event: [String: Any]) throws -> [RealtimeEvent] {
        guard let response = event["response"] as? [String: Any], let statusValue = response["status"] as? String else {
            throw RealtimeClientError.invalidEvent
        }
        let status = RealtimeResponseCompletion.Status(rawValue: statusValue) ?? .unknown
        let output = response["output"] as? [[String: Any]] ?? []
        var events: [RealtimeEvent] = []
        for item in output {
            if item["type"] as? String == "message", let id = item["id"] as? String,
               !finalTranscripts.contains("output:" + id), let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["transcript"] as? String ?? $0["text"] as? String }.joined()
                if !text.isEmpty {
                    events.append(try transcript(["text": text], itemID: id, input: false, final: true))
                }
            }
            // Arguments-done is also emitted for interrupted responses. Only
            // execute calls from a successfully completed response, once.
            if status == .completed, item["type"] as? String == "function_call" {
                guard let callID = item["call_id"] as? String, !callID.isEmpty,
                      let name = item["name"] as? String, !name.isEmpty,
                      let arguments = item["arguments"] as? String else { throw RealtimeClientError.invalidEvent }
                guard arguments.utf8.count <= 64 * 1_024 else { throw RealtimeClientError.eventTooLarge }
                if seenCalls.insert(callID).inserted {
                    events.append(.functionCall(RealtimeFunctionCall(callID: callID, name: name, arguments: arguments)))
                }
            }
        }
        if seenCalls.count > 512 { seenCalls.removeAll() }
        let usageObject = response["usage"] as? [String: Any]
        let usage: RealtimeUsage? = usageObject.map {
            let input = $0["input_token_details"] as? [String: Any]
            let output = $0["output_token_details"] as? [String: Any]
            return RealtimeUsage(
                inputTokens: $0["input_tokens"] as? Int ?? 0,
                outputTokens: $0["output_tokens"] as? Int ?? 0,
                cachedInputTokens: input?["cached_tokens"] as? Int ?? 0,
                inputAudioTokens: input?["audio_tokens"] as? Int ?? 0,
                outputAudioTokens: output?["audio_tokens"] as? Int ?? 0
            )
        }
        let details = response["status_details"] as? [String: Any]
        let error = (details?["error"] as? [String: Any]).map(RealtimeWire.serviceError)
        events.append(.responseDone(RealtimeResponseCompletion(
            id: response["id"] as? String ?? "", status: status,
            hasFunctionCalls: output.contains { $0["type"] as? String == "function_call" },
            usage: usage, error: error
        )))
        return events
    }

    private func required(_ value: String) throws -> String {
        guard !value.isEmpty else { throw RealtimeClientError.invalidEvent }
        return value
    }
}
