import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AssistantClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func reply(
        configuration: AssistantConfiguration,
        apiKey: String,
        messages: [AssistantMessage],
        tools: [AssistantToolDefinition] = [],
        toolHandler: AssistantToolHandler? = nil,
        onWebSearchStarted: (@Sendable () async -> Void)? = nil,
        onUpdate: (@Sendable (AssistantReply) async -> Void)? = nil
    ) async throws -> AssistantReply {
        try Task.checkCancellation()
        guard configuration.apiStyle != .realtime else { throw AssistantClientError.unsupportedAPIStyle }
        let endpoint = try configuration.validatedEndpoint()
        guard messages.contains(where: { $0.role == .user && $0.hasContent }) else {
            throw AssistantClientError.emptyConversation
        }

        let definitions = try AssistantFunctionTools.definitionsByName(tools)
        guard tools.isEmpty || toolHandler != nil else { throw AssistantToolLoopError.handlerMissing }
        let functionTools = try AssistantFunctionTools.wireDefinitions(tools, style: configuration.apiStyle)
        let selected = AssistantContext.recent(messages, limit: configuration.contextMessageCount)
        try AssistantAttachmentWire.validate(selected, supportsImages: configuration.supportsImageInput)
        let history = selected.map { message -> AssistantWireValue in
            guard !message.attachments.isEmpty else {
                return .object(["role": .string(message.role.rawValue), "content": .string(message.text)])
            }
            var parts: [AssistantWireValue] = []
            let textType = configuration.apiStyle == .responses ? "input_text" : "text"
            if !message.text.isEmpty { parts.append(.object(["type": .string(textType), "text": .string(message.text)])) }
            for attachment in message.attachments {
                if attachment.isImage {
                    let url = AssistantAttachmentWire.dataURL(attachment)
                    if configuration.apiStyle == .responses {
                        parts.append(.object(["type": .string("input_image"), "image_url": .string(url)]))
                    } else {
                        parts.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])]))
                    }
                } else {
                    parts.append(.object(["type": .string(textType), "text": .string(AssistantAttachmentWire.text(attachment))]))
                }
            }
            return .object(["role": .string(message.role.rawValue), "content": .array(parts)])
        }
        let system = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var chatInput = system.isEmpty ? history : [
            AssistantWireValue.object(["role": .string("system"), "content": .string(configuration.systemPrompt)])
        ] + history
        var responsesInput = history
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let isStreaming = onUpdate != nil || onWebSearchStarted != nil
        let progress = isStreaming ? AssistantReplyProgress(callback: onUpdate ?? { _ in }) : nil
        let searchNotification = onWebSearchStarted.map { SearchStartNotification(callback: $0) }
        var metadata = AssistantReplyMetadata()
        var executed: [String: AssistantExecutedTool] = [:]

        for round in 0..<AssistantFunctionTools.maximumRounds {
            try Task.checkCancellation()
            var request = try makeRequest(url: endpoint, method: "POST", apiKey: apiKey)
            switch configuration.apiStyle {
            case .chatCompletions:
                request.httpBody = try JSONEncoder().encode(ChatRequest(
                    model: model, messages: chatInput,
                    tools: functionTools.isEmpty ? nil : functionTools,
                    stream: isStreaming
                ))
            case .responses:
                let hostedTools: [AssistantWireValue] = configuration.webSearchEnabled
                    ? [.object(["type": .string("web_search")])] : []
                let allTools = hostedTools + functionTools
                request.httpBody = try JSONEncoder().encode(ResponsesRequest(
                    model: model,
                    instructions: configuration.systemPrompt,
                    input: responsesInput,
                    tools: allTools.isEmpty ? nil : allTools,
                    include: functionTools.isEmpty ? nil : ["reasoning.encrypted_content"],
                    stream: isStreaming
                ))
            case .realtime:
                throw AssistantClientError.unsupportedAPIStyle
            }

            let baseMetadata = metadata
            let hidesIntermediateText = !tools.isEmpty
            let turn: AssistantModelTurn
            if let progress {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                turn = try await stream(request, style: configuration.apiStyle, allowsToolCalls: !tools.isEmpty, onWebSearchStarted: {
                    await searchNotification?.notify()
                }) { partial in
                    await progress.publish(partial, base: baseMetadata, hidesText: hidesIntermediateText)
                }
            } else {
                turn = try decodeTurn(try await fetch(request), style: configuration.apiStyle)
            }
            try Task.checkCancellation()
            metadata.absorb(turn.reply)
            if turn.toolCalls.isEmpty {
                guard !turn.reply.text.isEmpty else { throw AssistantClientError.emptyResponse }
                let final = metadata.reply(text: turn.reply.text)
                await progress?.publish(final)
                try Task.checkCancellation()
                return final
            }
            guard let toolHandler, !definitions.isEmpty else { throw AssistantToolLoopError.unavailableTool }
            // Do not perform an action when no model round remains to report
            // its real result back to the user.
            guard round + 1 < AssistantFunctionTools.maximumRounds else { throw AssistantToolLoopError.limitExceeded }
            let prepared = try AssistantFunctionTools.prepare(turn.toolCalls, definitions: definitions, executed: executed)
            if configuration.apiStyle == .chatCompletions {
                guard let message = turn.chatMessage else { throw AssistantClientError.invalidResponse }
                chatInput.append(message)
            } else {
                // Keep the complete raw output, not just function calls:
                // stateless reasoning continuations need encrypted_content.
                responsesInput.append(contentsOf: turn.responsesOutput)
            }
            for item in prepared {
                try Task.checkCancellation()
                let result: AssistantToolResult
                if let previous = executed[item.call.callID] {
                    result = previous.result
                } else {
                    do { result = try await toolHandler(item.call) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        throw AssistantToolLoopError.executionFailed
                    }
                    try Task.checkCancellation()
                    guard result.output.utf8.count <= AssistantFunctionTools.maximumResultBytes else {
                        throw AssistantToolLoopError.executionFailed
                    }
                    executed[item.call.callID] = AssistantExecutedTool(name: item.call.name, arguments: item.arguments, result: result)
                }
                metadata.absorb(result)
                if configuration.apiStyle == .chatCompletions {
                    chatInput.append(.object([
                        "role": .string("tool"), "tool_call_id": .string(item.call.callID), "content": .string(result.output)
                    ]))
                } else {
                    responsesInput.append(.object([
                        "type": .string("function_call_output"), "call_id": .string(item.call.callID), "output": .string(result.output)
                    ]))
                }
            }
            await progress?.publish(metadata.reply(text: ""))
            try Task.checkCancellation()
        }
        throw AssistantToolLoopError.limitExceeded
    }

    private func decodeTurn(_ data: Data, style: AssistantAPIStyle) throws -> AssistantModelTurn {
        do {
            switch style {
            case .chatCompletions:
                return try JSONDecoder().decode(ChatResponse.self, from: data).turn()
            case .responses:
                return try JSONDecoder().decode(ResponsesResponse.self, from: data).turn()
            case .realtime:
                throw AssistantClientError.unsupportedAPIStyle
            }
        } catch let error as AssistantClientError {
            throw error
        } catch let error as AssistantToolLoopError {
            throw error
        } catch {
            throw AssistantClientError.invalidResponse
        }
    }

    private func stream(
        _ request: URLRequest,
        style: AssistantAPIStyle,
        allowsToolCalls: Bool,
        onWebSearchStarted: @Sendable () async -> Void,
        onUpdate: @Sendable (AssistantReply) async -> Void
    ) async throws -> AssistantModelTurn {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
            defer { bytes.task.cancel() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw AssistantClientError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else { throw AssistantClientError.httpStatus(response.statusCode) }
                let contentType = response.value(forHTTPHeaderField: "Content-Type")?
                    .split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard contentType == "text/event-stream" else {
                    // Some compatible services ignore stream=true. Decode this
                    // same HTTP response; never issue a second, billable POST.
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < AssistantStreamLimits.maximumResponseBytes else { throw AssistantClientError.invalidResponse }
                        data.append(byte)
                    }
                    let turn = try decodeTurn(data, style: style)
                    if !allowsToolCalls, !turn.toolCalls.isEmpty { throw AssistantClientError.failedResponse }
                    try Task.checkCancellation()
                    await onUpdate(turn.reply)
                    try Task.checkCancellation()
                    return turn
                }

                var parser = AssistantSSEParser()
                var accumulator = AssistantStreamAccumulator(style: style, allowsToolCalls: allowsToolCalls)
                var lastUpdate: AssistantReply?
                var searchEventDelivered = false
                var totalBytes = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    totalBytes += 1
                    guard totalBytes <= AssistantStreamLimits.maximumResponseBytes else { throw AssistantClientError.invalidResponse }
                    guard let event = try parser.append(byte) else { continue }
                    try accumulator.consume(event)
                    if accumulator.webSearchStarted, !searchEventDelivered {
                        searchEventDelivered = true
                        try Task.checkCancellation()
                        await onWebSearchStarted()
                        try Task.checkCancellation()
                    }
                    let snapshot = accumulator.snapshot
                    if snapshot != lastUpdate, !snapshot.text.isEmpty || !snapshot.sources.isEmpty || snapshot.usedWebSearch {
                        await onUpdate(snapshot)
                        try Task.checkCancellation()
                        lastUpdate = snapshot
                    }
                    if accumulator.isTerminal {
                        try Task.checkCancellation()
                        return try accumulator.finishTurn()
                    }
                }
                if let event = try parser.finish() {
                    try accumulator.consume(event)
                    if accumulator.webSearchStarted, !searchEventDelivered {
                        try Task.checkCancellation()
                        await onWebSearchStarted()
                        try Task.checkCancellation()
                    }
                }
                let turn = try accumulator.finishTurn()
                if turn.reply != lastUpdate {
                    try Task.checkCancellation()
                    await onUpdate(turn.reply)
                    try Task.checkCancellation()
                }
                return turn
            } onCancel: {
                bytes.task.cancel()
            }
        } catch let error as AssistantClientError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as AssistantToolLoopError {
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? AssistantClientError.requestTimedOut : AssistantClientError.networkUnavailable
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantClientError.networkUnavailable
        }
    }

    public func availableModels(
        endpoint: String,
        apiStyle: AssistantAPIStyle = .chatCompletions,
        apiKey: String
    ) async throws -> [String] {
        try Task.checkCancellation()
        // Both supported OpenAI formats discover models from the same resource.
        // Discovery intentionally does not require an already selected model.
        let url = try AssistantEndpoint.resolve(endpoint, route: "/models")
        let request = try makeRequest(url: url, method: "GET", apiKey: apiKey)
        let data = try await fetch(request)
        do {
            let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
            guard response.error == nil else { throw AssistantClientError.failedResponse }
            guard let models = response.data else { throw AssistantClientError.invalidResponse }
            // IDs are case-sensitive. Unicode lexical sorting is stable across
            // the phone's UI locale and never changes the provider's IDs.
            return Set(models.compactMap { nonempty($0.id) }).sorted()
        } catch let error as AssistantClientError {
            throw error
        } catch {
            throw AssistantClientError.invalidResponse
        }
    }

    private func makeRequest(url: URL, method: String, apiKey: String) throws -> URLRequest {
        guard apiKey.rangeOfCharacter(from: .controlCharacters) == nil else { throw AssistantClientError.invalidAPIKey }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = method
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            // Reject every redirect, including cross-origin redirects, before
            // URLSession can forward a request carrying the user's credentials.
            (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? AssistantClientError.requestTimedOut : AssistantClientError.networkUnavailable
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantClientError.networkUnavailable
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AssistantClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AssistantClientError.httpStatus(response.statusCode) }

        return data
    }
}

private actor SearchStartNotification {
    private let callback: @Sendable () async -> Void
    private var notified = false

    init(callback: @escaping @Sendable () async -> Void) { self.callback = callback }

    func notify() async {
        guard !notified else { return }
        notified = true
        await callback()
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

private struct ChatRequest: Encodable {
    let model: String
    let messages: [AssistantWireValue]
    let tools: [AssistantWireValue]?
    let stream: Bool
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [AssistantWireValue]
    let tools: [AssistantWireValue]?
    let include: [String]?
    let store = false
    let stream: Bool
}

struct WireError: Decodable {
    let message: String?
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }
    let data: [Model]?
    let error: WireError?
}

struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: MessageContent?
            let refusal: String?
            let annotations: [Citation]?
            let tool_calls: [AssistantChatToolCall]?
            let raw: AssistantWireValue

            private enum CodingKeys: String, CodingKey { case content, refusal, annotations, tool_calls }

            init(from decoder: Decoder) throws {
                raw = try AssistantWireValue(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = try container.decodeIfPresent(MessageContent.self, forKey: .content)
                refusal = try container.decodeIfPresent(String.self, forKey: .refusal)
                annotations = try container.decodeIfPresent([Citation].self, forKey: .annotations)
                tool_calls = try container.decodeIfPresent([AssistantChatToolCall].self, forKey: .tool_calls)
            }
        }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]?
    let error: WireError?

    func reply() throws -> AssistantReply {
        let turn = try turn()
        guard !turn.reply.text.isEmpty else { throw AssistantClientError.emptyResponse }
        return turn.reply
    }

    func turn() throws -> AssistantModelTurn {
        guard error == nil else { throw AssistantClientError.failedResponse }
        guard let choices else { throw AssistantClientError.invalidResponse }
        guard let choice = choices.first else { throw AssistantClientError.emptyResponse }
        if choice.finish_reason == "length" { throw AssistantClientError.incompleteResponse }
        if ["error", "content_filter", "function_call"].contains(choice.finish_reason ?? "") { throw AssistantClientError.failedResponse }
        let calls = try (choice.message.tool_calls ?? []).map { try $0.call() }
        if choice.finish_reason == "tool_calls", calls.isEmpty { throw AssistantToolLoopError.invalidCall }
        if !calls.isEmpty, let reason = choice.finish_reason, reason != "tool_calls" { throw AssistantToolLoopError.invalidCall }
        let text = nonempty(choice.message.content?.text) ?? nonempty(choice.message.refusal) ?? ""
        let citations = (choice.message.annotations ?? []) + (choice.message.content?.citations ?? [])
        return AssistantModelTurn(
            reply: AssistantReply(text: text, sources: uniqueSources(citations)),
            toolCalls: calls,
            chatMessage: choice.message.raw.setting("role", to: .string("assistant"))
        )
    }
}

struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        let type: String
        let content: [ContentPart]?
        let call_id: String?
        let name: String?
        let arguments: String?
        let status: String?
        let raw: AssistantWireValue

        private enum CodingKeys: String, CodingKey { case type, content, call_id, name, arguments, status }

        init(from decoder: Decoder) throws {
            raw = try AssistantWireValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            content = type == "message" ? try container.decodeIfPresent([ContentPart].self, forKey: .content) : nil
            call_id = type == "function_call" ? try container.decodeIfPresent(String.self, forKey: .call_id) : nil
            name = type == "function_call" ? try container.decodeIfPresent(String.self, forKey: .name) : nil
            arguments = type == "function_call" ? try container.decodeIfPresent(String.self, forKey: .arguments) : nil
            status = type == "function_call" ? try container.decodeIfPresent(String.self, forKey: .status) : nil
        }

        func call() throws -> AssistantToolCall? {
            guard type == "function_call" else { return nil }
            if let status, status != "completed" { throw AssistantClientError.incompleteResponse }
            guard let call_id, let name, let arguments else { throw AssistantToolLoopError.invalidCall }
            return AssistantToolCall(callID: call_id, name: name, arguments: arguments)
        }
    }
    let status: String?
    let output: [Output]?
    let output_text: String?
    let error: WireError?

    func reply() throws -> AssistantReply {
        let turn = try turn()
        guard !turn.reply.text.isEmpty else { throw AssistantClientError.emptyResponse }
        return turn.reply
    }

    func turn(outputOverride: [AssistantWireValue]? = nil) throws -> AssistantModelTurn {
        guard status != "failed", error == nil else { throw AssistantClientError.failedResponse }
        if let status, ["incomplete", "in_progress", "queued", "cancelled"].contains(status) {
            throw AssistantClientError.incompleteResponse
        }
        let effectiveOutput = try outputOverride.map { values in
            try values.map { try JSONDecoder().decode(Output.self, from: JSONEncoder().encode($0)) }
        } ?? output ?? []
        let parts = effectiveOutput.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        let textParts = parts.filter { $0.type == "output_text" || $0.type == "text" }.compactMap { nonempty($0.text) }
        let refusalParts = parts.filter { $0.type == "refusal" }.compactMap { nonempty($0.refusal) }
        let text = nonempty(textParts.joined(separator: "\n"))
            ?? nonempty(output_text)
            ?? nonempty(refusalParts.joined(separator: "\n")) ?? ""
        if output == nil, output_text == nil, outputOverride == nil { throw AssistantClientError.invalidResponse }
        let calls = try effectiveOutput.compactMap { try $0.call() }
        return AssistantModelTurn(
            reply: AssistantReply(
                text: text,
                sources: uniqueSources(parts.flatMap { $0.annotations ?? [] }),
                usedWebSearch: effectiveOutput.contains { $0.type == "web_search_call" }
            ),
            toolCalls: calls,
            responsesOutput: effectiveOutput.map(\.raw)
        )
    }
}

enum MessageContent: Decodable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([ContentPart].self))
        }
    }

    var text: String {
        switch self {
        case .text(let text): return text
        case .parts(let parts):
            return parts.filter { $0.type == "text" || $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n")
        }
    }

    var citations: [Citation] {
        switch self {
        case .text: return []
        case .parts(let parts): return parts.flatMap { $0.annotations ?? [] }
        }
    }
}

struct ContentPart: Decodable {
    let type: String
    let text: String?
    let refusal: String?
    let annotations: [Citation]?
}

struct Citation: Decodable {
    struct Details: Decodable {
        let url: String?
        let title: String?
    }
    let type: String?
    let url: String?
    let title: String?
    let url_citation: Details?

    var source: AssistantSource? {
        guard type == "url_citation",
              let value = url ?? url_citation?.url,
              let url = URL(string: value), AssistantSource.isSafe(url) else { return nil }
        let title = nonempty(title ?? url_citation?.title) ?? url.host ?? "Источник"
        return AssistantSource(title: title, url: url)
    }
}

func uniqueSources(_ citations: [Citation]) -> [AssistantSource] {
    var seen = Set<URL>()
    return citations.compactMap(\.source).filter { seen.insert($0.url).inserted }
}

func nonempty(_ value: String?) -> String? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}
