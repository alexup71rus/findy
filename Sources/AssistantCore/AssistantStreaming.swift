import Foundation

enum AssistantStreamLimits {
    static let maximumEventBytes = 256 * 1024
    static let maximumOutputBytes = 1024 * 1024
    static let maximumResponseBytes = 4 * 1024 * 1024
}

struct AssistantSSEEvent {
    let name: String?
    let data: String
}

/// Byte-based framing bounds a malicious or broken unterminated line before a
/// String is allocated. UTF-8 is decoded only after a complete line arrives.
struct AssistantSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventBytes = 0
    private var skipLineFeed = false
    private var firstLine = true

    mutating func append(_ byte: UInt8) throws -> AssistantSSEEvent? {
        if skipLineFeed, byte == 10 {
            skipLineFeed = false
            return nil
        }
        skipLineFeed = false
        eventBytes += 1
        guard eventBytes <= AssistantStreamLimits.maximumEventBytes else { throw AssistantClientError.invalidResponse }
        if byte == 13 {
            skipLineFeed = true
            return try consumeLine()
        }
        if byte == 10 { return try consumeLine() }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> AssistantSSEEvent? {
        if !line.isEmpty, let event = try consumeLine() { return event }
        return dispatch()
    }

    private mutating func consumeLine() throws -> AssistantSSEEvent? {
        guard var value = String(data: line, encoding: .utf8) else { throw AssistantClientError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.first == "\u{FEFF}" { value.removeFirst() }
        }
        guard !value.isEmpty else { return dispatch() }
        if value.hasPrefix(":") { return nil }
        let field: Substring
        var contents: Substring
        if let colon = value.firstIndex(of: ":") {
            field = value[..<colon]
            contents = value[value.index(after: colon)...]
            if contents.first == " " { contents.removeFirst() }
        } else {
            field = value[...]
            contents = ""
        }
        switch field {
        case "data": dataLines.append(String(contents))
        case "event": eventName = String(contents)
        default: break // id/retry and extensions do not change the response.
        }
        return nil
    }

    private mutating func dispatch() -> AssistantSSEEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            eventBytes = 0
        }
        guard !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        guard !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AssistantSSEEvent(name: eventName, data: data)
    }
}

/// Aggregates only public answer text. Reasoning/tool argument deltas are never
/// surfaced as user-visible or spoken text.
struct AssistantStreamAccumulator {
    private struct PartKey: Hashable, Comparable {
        let output: Int
        let content: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.output == rhs.output ? lhs.content < rhs.content : lhs.output < rhs.output
        }
    }

    private struct Part {
        var text = ""
        var refusal = ""
    }

    private struct ChatCall {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private struct ResponseCall {
        var itemID: String?
        var arguments = ""
        var receivedArguments = false
        var confirmedArguments: String?
    }

    let style: AssistantAPIStyle
    let allowsToolCalls: Bool
    private var chatText = ""
    private var chatRefusal = ""
    private var chatReasoning = ""
    private var chatCalls: [Int: ChatCall] = [:]
    private var chatCallsFinished = false
    private var chatFinished = false
    private var receivedDone = false
    private var responseParts: [PartKey: Part] = [:]
    private var responseCalls: [Int: ResponseCall] = [:]
    private var completedOutput: [Int: AssistantWireValue] = [:]
    private var sources: [AssistantSource] = []
    private var sourceURLs = Set<URL>()
    private var usedWebSearch = false
    private(set) var webSearchStarted = false
    private var completedTurn: AssistantModelTurn?

    init(style: AssistantAPIStyle, allowsToolCalls: Bool = false) {
        self.style = style
        self.allowsToolCalls = allowsToolCalls
    }

    var isTerminal: Bool { receivedDone || completedTurn != nil }

    var snapshot: AssistantReply {
        if let completedTurn { return completedTurn.reply }
        let text: String
        switch style {
        case .chatCompletions:
            text = nonempty(chatText) ?? nonempty(chatRefusal) ?? ""
        case .responses:
            let ordered = responseParts.keys.sorted().compactMap { responseParts[$0] }
            text = nonempty(ordered.compactMap { nonempty($0.text) }.joined(separator: "\n"))
                ?? nonempty(ordered.compactMap { nonempty($0.refusal) }.joined(separator: "\n")) ?? ""
        case .realtime:
            text = ""
        }
        return AssistantReply(text: text, sources: sources, usedWebSearch: usedWebSearch)
    }

    mutating func consume(_ event: AssistantSSEEvent) throws {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["ping", "heartbeat", "keepalive"].contains(event.name ?? "") { return }
        if event.name == "error" || event.name == "response.failed" { throw AssistantClientError.failedResponse }
        if event.name == "response.incomplete" { throw AssistantClientError.incompleteResponse }
        if data == "[DONE]" {
            guard style == .chatCompletions else { throw AssistantClientError.incompleteResponse }
            receivedDone = true
            return
        }
        do {
            switch style {
            case .chatCompletions:
                try consumeChat(JSONDecoder().decode(ChatStreamChunk.self, from: Data(data.utf8)))
            case .responses:
                let payload = Data(data.utf8)
                let type = try JSONDecoder().decode(ResponseStreamType.self, from: payload).type ?? event.name ?? ""
                guard !type.isEmpty else { throw AssistantClientError.invalidResponse }
                if type == "response.web_search_call.in_progress" || type == "response.web_search_call.searching" {
                    webSearchStarted = true
                }
                if type.hasPrefix("response.web_search_call.") { usedWebSearch = true }
                switch type {
                case "error", "response.failed":
                    throw AssistantClientError.failedResponse
                case "response.incomplete", "response.cancelled":
                    throw AssistantClientError.incompleteResponse
                case "response.output_text.delta", "response.refusal.delta",
                     "response.output_text.done", "response.refusal.done",
                     "response.output_text.annotation.added",
                     "response.content_part.added", "response.content_part.done",
                     "response.output_item.added", "response.output_item.done",
                     "response.function_call_arguments.delta", "response.function_call_arguments.done",
                     "response.completed":
                    try consumeResponse(JSONDecoder().decode(ResponseStreamEvent.self, from: payload), eventName: event.name)
                default:
                    break // New event schemas and private reasoning stay opaque.
                }
            case .realtime:
                throw AssistantClientError.unsupportedAPIStyle
            }
            guard snapshot.text.utf8.count <= AssistantStreamLimits.maximumOutputBytes else { throw AssistantClientError.invalidResponse }
        } catch let error as AssistantClientError {
            throw error
        } catch let error as AssistantToolLoopError {
            throw error
        } catch {
            throw AssistantClientError.invalidResponse
        }
    }

    func finish() throws -> AssistantReply {
        let reply = try finishTurn().reply
        guard !reply.text.isEmpty else { throw AssistantClientError.emptyResponse }
        return reply
    }

    func finishTurn() throws -> AssistantModelTurn {
        if let completedTurn { return completedTurn }
        // [DONE] closes the transport, but does not describe why generation
        // stopped. Accept only a choice with a successful finish reason.
        guard style == .chatCompletions, chatFinished else { throw AssistantClientError.incompleteResponse }
        let reply = snapshot
        let calls = try chatCalls.keys.sorted().map { index -> AssistantToolCall in
            guard let call = chatCalls[index], let id = call.id, !call.name.isEmpty, chatCallsFinished else {
                throw AssistantToolLoopError.invalidCall
            }
            return AssistantToolCall(callID: id, name: call.name, arguments: call.arguments)
        }
        if chatCallsFinished, calls.isEmpty { throw AssistantToolLoopError.invalidCall }
        guard !reply.text.isEmpty || !calls.isEmpty else { throw AssistantClientError.emptyResponse }
        var message: [String: AssistantWireValue] = [
            "role": .string("assistant"), "content": chatText.isEmpty ? .null : .string(chatText)
        ]
        if !chatRefusal.isEmpty { message["refusal"] = .string(chatRefusal) }
        if !chatReasoning.isEmpty { message["reasoning_content"] = .string(chatReasoning) }
        if !calls.isEmpty { message["tool_calls"] = try .array(calls.map { try .encoded(AssistantChatToolCall($0)) }) }
        return AssistantModelTurn(reply: reply, toolCalls: calls, chatMessage: .object(message))
    }

    private mutating func consumeChat(_ chunk: ChatStreamChunk) throws {
        guard chunk.error == nil else { throw AssistantClientError.failedResponse }
        guard let choices = chunk.choices else { throw AssistantClientError.invalidResponse }
        // An empty choices list is a valid final usage-only chunk.
        guard let choice = choices.first(where: { ($0.index ?? 0) == 0 }) else { return }
        if let content = choice.delta?.content {
            chatText += content.text
            addSources(content.citations)
        }
        if let refusal = choice.delta?.refusal { chatRefusal += refusal }
        if let reasoning = choice.delta?.reasoning_content {
            chatReasoning += reasoning
            guard chatReasoning.utf8.count <= AssistantStreamLimits.maximumOutputBytes else { throw AssistantClientError.invalidResponse }
        }
        addSources(choice.delta?.annotations ?? [])
        for delta in choice.delta?.tool_calls ?? [] {
            guard allowsToolCalls else { throw AssistantClientError.failedResponse }
            guard delta.index >= 0, delta.index < AssistantFunctionTools.maximumCalls,
                  delta.type == nil || delta.type == "function" else { throw AssistantToolLoopError.invalidCall }
            var call = chatCalls[delta.index, default: ChatCall()]
            if let id = delta.id {
                guard call.id == nil || call.id == id else { throw AssistantToolLoopError.changedCall }
                call.id = id
            }
            if let name = delta.function?.name {
                if call.name != name { call.name += name }
                guard call.name.utf8.count <= 64 else { throw AssistantToolLoopError.invalidCall }
            }
            if let arguments = delta.function?.arguments { call.arguments += arguments }
            guard call.arguments.utf8.count <= AssistantFunctionTools.maximumArgumentBytes else { throw AssistantToolLoopError.invalidCall }
            chatCalls[delta.index] = call
        }
        switch choice.finish_reason {
        case nil: break
        case "stop":
            guard chatCalls.isEmpty else { throw AssistantToolLoopError.invalidCall }
            chatFinished = true
        case "tool_calls":
            guard allowsToolCalls else { throw AssistantClientError.failedResponse }
            chatCallsFinished = true
            chatFinished = true
        case "length": throw AssistantClientError.incompleteResponse
        case "error", "content_filter", "function_call": throw AssistantClientError.failedResponse
        default: throw AssistantClientError.invalidResponse
        }
    }

    private mutating func consumeResponse(_ event: ResponseStreamEvent, eventName: String?) throws {
        let type = event.type ?? eventName ?? ""
        guard event.error == nil, type != "error", type != "response.failed" else { throw AssistantClientError.failedResponse }
        if type == "response.incomplete" || type == "response.cancelled" { throw AssistantClientError.incompleteResponse }
        if type.hasPrefix("response.web_search_call.") { usedWebSearch = true }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event.delta else { throw AssistantClientError.invalidResponse }
            let key = try partKey(event)
            if type == "response.output_text.delta" {
                responseParts[key, default: Part()].text += delta
            } else {
                responseParts[key, default: Part()].refusal += delta
            }
        case "response.output_text.done", "response.refusal.done":
            let key = try partKey(event)
            if type == "response.output_text.done" {
                guard let text = event.text else { throw AssistantClientError.invalidResponse }
                responseParts[key, default: Part()].text = text
            } else {
                guard let refusal = event.refusal else { throw AssistantClientError.invalidResponse }
                responseParts[key, default: Part()].refusal = refusal
            }
        case "response.output_text.annotation.added":
            if let annotation = event.annotation { addSources([annotation]) }
        case "response.content_part.added", "response.content_part.done":
            guard let part = event.part else { throw AssistantClientError.invalidResponse }
            try apply(part, at: partKey(event))
        case "response.output_item.added", "response.output_item.done":
            guard let item = event.item else { throw AssistantClientError.invalidResponse }
            let index = try outputIndex(event)
            if item.type == "web_search_call" { usedWebSearch = true }
            if item.type == "function_call" {
                guard allowsToolCalls else { throw AssistantClientError.failedResponse }
                try checkCallIdentity(item.raw, at: index)
                if type == "response.output_item.done", let arguments = item.arguments {
                    try confirmArguments(arguments, at: index)
                }
            }
            if type == "response.output_item.done" { completedOutput[index] = item.raw }
            if item.type == "message" {
                for (index, part) in (item.content ?? []).enumerated() {
                    try apply(part, at: PartKey(output: event.output_index ?? 0, content: index))
                }
            }
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            guard allowsToolCalls else { throw AssistantClientError.failedResponse }
            let index = try outputIndex(event)
            var call = responseCalls[index, default: ResponseCall()]
            if let itemID = event.item_id {
                guard call.itemID == nil || call.itemID == itemID else { throw AssistantToolLoopError.changedCall }
                call.itemID = itemID
            }
            if type == "response.function_call_arguments.delta" {
                guard let delta = event.delta, call.confirmedArguments == nil else { throw AssistantToolLoopError.invalidCall }
                call.arguments += delta
                call.receivedArguments = true
                guard call.arguments.utf8.count <= AssistantFunctionTools.maximumArgumentBytes else {
                    throw AssistantToolLoopError.invalidCall
                }
                responseCalls[index] = call
            } else {
                responseCalls[index] = call
                guard let arguments = event.arguments else { throw AssistantToolLoopError.invalidCall }
                try confirmArguments(arguments, at: index)
            }
            guard responseCalls.count <= AssistantFunctionTools.maximumCalls else { throw AssistantToolLoopError.limitExceeded }
        case "response.completed":
            guard let response = event.response else { throw AssistantClientError.invalidResponse }
            guard response.output != nil || response.output_text != nil || !completedOutput.isEmpty else {
                throw AssistantClientError.invalidResponse
            }
            let output = try mergeCompletedOutput(response.output ?? [])
            let final = try response.turn(outputOverride: output)
            guard allowsToolCalls || final.toolCalls.isEmpty else { throw AssistantClientError.failedResponse }
            for source in final.reply.sources where sourceURLs.insert(source.url).inserted { sources.append(source) }
            usedWebSearch = usedWebSearch || final.reply.usedWebSearch
            completedTurn = AssistantModelTurn(
                reply: AssistantReply(text: final.reply.text, sources: sources, usedWebSearch: usedWebSearch),
                toolCalls: final.toolCalls, responsesOutput: final.responsesOutput
            )
        default:
            break
        }
    }

    private func outputIndex(_ event: ResponseStreamEvent) throws -> Int {
        guard let index = event.output_index, index >= 0, index < 1024 else { throw AssistantClientError.invalidResponse }
        return index
    }

    private mutating func checkCallIdentity(_ item: AssistantWireValue, at index: Int) throws {
        var call = responseCalls[index, default: ResponseCall()]
        if let id = item.object?["id"]?.string {
            guard call.itemID == nil || call.itemID == id else { throw AssistantToolLoopError.changedCall }
            call.itemID = id
        }
        responseCalls[index] = call
        guard responseCalls.count <= AssistantFunctionTools.maximumCalls else { throw AssistantToolLoopError.limitExceeded }
    }

    private mutating func confirmArguments(_ arguments: String, at index: Int) throws {
        var call = responseCalls[index, default: ResponseCall()]
        guard arguments.utf8.count <= AssistantFunctionTools.maximumArgumentBytes,
              !call.receivedArguments || call.arguments == arguments,
              call.confirmedArguments == nil || call.confirmedArguments == arguments else {
            throw AssistantToolLoopError.invalidCall
        }
        call.confirmedArguments = arguments
        responseCalls[index] = call
    }

    private mutating func mergeCompletedOutput(_ output: [ResponsesResponse.Output]) throws -> [AssistantWireValue] {
        var values = completedOutput
        for (index, item) in output.enumerated() {
            if let previous = values[index] {
                guard previous.object?["type"] == item.raw.object?["type"],
                      previous.object?["id"] == nil || item.raw.object?["id"] == nil || previous.object?["id"] == item.raw.object?["id"] else {
                    throw AssistantClientError.invalidResponse
                }
                values[index] = try previous.merging(item.raw)
            } else { values[index] = item.raw }
        }
        let indices = values.keys.sorted()
        guard indices == Array(0..<values.count) else { throw AssistantClientError.invalidResponse }
        for index in indices {
            guard let raw = values[index] else { throw AssistantClientError.invalidResponse }
            if raw.object?["type"]?.string == "function_call" {
                try checkCallIdentity(raw, at: index)
                guard let arguments = raw.object?["arguments"]?.string else { throw AssistantToolLoopError.invalidCall }
                try confirmArguments(arguments, at: index)
            }
        }
        // An arguments delta without a corresponding completed function call
        // is never safe to execute, even if the enclosing response completed.
        for index in responseCalls.keys {
            guard values[index]?.object?["type"]?.string == "function_call" else { throw AssistantToolLoopError.invalidCall }
        }
        return indices.compactMap { values[$0] }
    }

    private func partKey(_ event: ResponseStreamEvent) throws -> PartKey {
        let output = event.output_index ?? 0
        let content = event.content_index ?? 0
        guard output >= 0, content >= 0 else { throw AssistantClientError.invalidResponse }
        return PartKey(output: output, content: content)
    }

    private mutating func apply(_ part: ContentPart, at key: PartKey) throws {
        guard key.output >= 0, key.content >= 0 else { throw AssistantClientError.invalidResponse }
        if part.type == "output_text" || part.type == "text" {
            responseParts[key, default: Part()].text = part.text ?? ""
        } else if part.type == "refusal" {
            responseParts[key, default: Part()].refusal = part.refusal ?? ""
        } else {
            return
        }
        addSources(part.annotations ?? [])
    }

    private mutating func addSources(_ citations: [Citation]) {
        for source in uniqueSources(citations) where sourceURLs.insert(source.url).inserted { sources.append(source) }
    }
}

private struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct Tool: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int
                let id: String?
                let type: String?
                let function: Function?
            }
            let content: MessageContent?
            let refusal: String?
            let reasoning_content: String?
            let annotations: [Citation]?
            let tool_calls: [Tool]?
        }
        let index: Int?
        let delta: Delta?
        let finish_reason: String?
    }
    let choices: [Choice]?
    let error: WireError?
}

private struct ResponseStreamEvent: Decodable {
    let type: String?
    let delta: String?
    let text: String?
    let refusal: String?
    let arguments: String?
    let item_id: String?
    let output_index: Int?
    let content_index: Int?
    let annotation: Citation?
    let part: ContentPart?
    let item: ResponsesResponse.Output?
    let response: ResponsesResponse?
    let error: WireError?
}

private struct ResponseStreamType: Decodable {
    let type: String?
}
