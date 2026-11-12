import Foundation

public enum AssistantToolLoopError: Error, LocalizedError, Equatable, Sendable {
    case invalidDefinitions
    case handlerMissing
    case invalidCall
    case unavailableTool
    case changedCall
    case limitExceeded
    case executionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDefinitions:
            return "Некорректно настроены функции помощника."
        case .handlerMissing:
            return "Обработчик функций помощника недоступен."
        case .invalidCall:
            return "Модель вернула незавершённый или некорректный запрос действия."
        case .unavailableTool:
            return "Модель запросила недоступную функцию. Действие не выполнено."
        case .changedCall:
            return "Модель изменила уже обработанный запрос действия. Повторное выполнение остановлено."
        case .limitExceeded:
            return "Не удалось завершить цепочку действий в пределах лимита. Проверьте сохранённые данные перед повтором."
        case .executionFailed:
            return "Не удалось выполнить действие. Успешное сохранение или напоминание не подтверждено."
        }
    }
}

/// Retains every returned output field, including opaque encrypted reasoning,
/// without converting model payloads into non-Sendable Foundation dictionaries.
enum AssistantWireValue: Codable, Equatable, Sendable {
    case object([String: AssistantWireValue])
    case array([AssistantWireValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AssistantWireValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AssistantWireValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func encoded<Value: Encodable>(_ value: Value) throws -> AssistantWireValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    var object: [String: AssistantWireValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var string: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    func setting(_ key: String, to value: AssistantWireValue) -> AssistantWireValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }

    func merging(_ newer: AssistantWireValue) throws -> AssistantWireValue {
        guard case .object(var object) = self, case .object(let fields) = newer else {
            throw AssistantClientError.invalidResponse
        }
        for (key, value) in fields { object[key] = value }
        return .object(object)
    }
}

struct AssistantModelTurn: Sendable {
    let reply: AssistantReply
    let toolCalls: [AssistantToolCall]
    let chatMessage: AssistantWireValue?
    let responsesOutput: [AssistantWireValue]

    init(
        reply: AssistantReply,
        toolCalls: [AssistantToolCall] = [],
        chatMessage: AssistantWireValue? = nil,
        responsesOutput: [AssistantWireValue] = []
    ) {
        self.reply = reply
        self.toolCalls = toolCalls
        self.chatMessage = chatMessage
        self.responsesOutput = responsesOutput
    }
}

struct AssistantChatToolCall: Codable, Sendable {
    struct Function: Codable, Sendable {
        let name: String
        let arguments: String
    }
    let id: String
    let type: String?
    let function: Function

    init(_ call: AssistantToolCall) {
        id = call.callID
        type = "function"
        function = Function(name: call.name, arguments: call.arguments)
    }

    func call() throws -> AssistantToolCall {
        guard type == nil || type == "function" else { throw AssistantToolLoopError.unavailableTool }
        return AssistantToolCall(callID: id, name: function.name, arguments: function.arguments)
    }
}

struct AssistantReplyMetadata: Sendable {
    private(set) var sources: [AssistantSource] = []
    private var sourceURLs = Set<URL>()
    private(set) var usedWebSearch = false

    mutating func absorb(_ reply: AssistantReply) {
        absorb(sources: reply.sources, usedWebSearch: reply.usedWebSearch)
    }

    mutating func absorb(_ result: AssistantToolResult) {
        absorb(sources: result.sources, usedWebSearch: result.usedWebSearch)
    }

    private mutating func absorb(sources incoming: [AssistantSource], usedWebSearch: Bool) {
        for source in incoming where AssistantSource.isSafe(source.url) && sourceURLs.insert(source.url).inserted {
            sources.append(source)
        }
        self.usedWebSearch = self.usedWebSearch || usedWebSearch
    }

    func reply(text: String) -> AssistantReply {
        AssistantReply(text: text, sources: sources, usedWebSearch: usedWebSearch)
    }
}

actor AssistantReplyProgress {
    private let callback: @Sendable (AssistantReply) async -> Void
    private var lastReply: AssistantReply?

    init(callback: @escaping @Sendable (AssistantReply) async -> Void) {
        self.callback = callback
    }

    func publish(_ partial: AssistantReply, base: AssistantReplyMetadata, hidesText: Bool) async {
        var metadata = base
        metadata.absorb(partial)
        await publish(metadata.reply(text: hidesText ? "" : partial.text))
    }

    func publish(_ reply: AssistantReply) async {
        guard reply != lastReply, !reply.text.isEmpty || !reply.sources.isEmpty || reply.usedWebSearch else { return }
        lastReply = reply
        await callback(reply)
    }
}

struct AssistantExecutedTool: Sendable {
    let name: String
    let arguments: AssistantWireValue
    let result: AssistantToolResult
}

struct AssistantPreparedToolCall: Sendable {
    let call: AssistantToolCall
    let arguments: AssistantWireValue
}

enum AssistantFunctionTools {
    static let maximumRounds = 3
    static let maximumCalls = 6
    static let maximumArgumentBytes = 64 * 1024
    static let maximumResultBytes = 256 * 1024

    static func definitionsByName(_ definitions: [AssistantToolDefinition]) throws -> [String: AssistantToolDefinition] {
        var result: [String: AssistantToolDefinition] = [:]
        for definition in definitions {
            guard definition.name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  result[definition.name] == nil,
                  Set(definition.parameters.required).isSubset(of: Set(definition.parameters.properties.keys)),
                  definition.parameters.properties.values.allSatisfy({ ($0.maxLength ?? 0) >= 0 }) else {
                throw AssistantToolLoopError.invalidDefinitions
            }
            result[definition.name] = definition
        }
        return result
    }

    static func wireDefinitions(_ definitions: [AssistantToolDefinition], style: AssistantAPIStyle) throws -> [AssistantWireValue] {
        try definitions.map { definition in
            guard var fields = try AssistantWireValue.encoded(definition).object else {
                throw AssistantToolLoopError.invalidDefinitions
            }
            // Optional string parameters must remain optional. Responses may
            // otherwise normalize a supplied schema into strict mode.
            fields["strict"] = .bool(false)
            switch style {
            case .chatCompletions:
                fields["type"] = nil
                return .object(["type": .string("function"), "function": .object(fields)])
            case .responses:
                return .object(fields)
            case .realtime:
                throw AssistantClientError.unsupportedAPIStyle
            }
        }
    }

    static func prepare(
        _ calls: [AssistantToolCall],
        definitions: [String: AssistantToolDefinition],
        executed: [String: AssistantExecutedTool]
    ) throws -> [AssistantPreparedToolCall] {
        var result: [AssistantPreparedToolCall] = []
        var seen: [String: AssistantPreparedToolCall] = [:]
        for call in calls {
            guard !call.callID.isEmpty, call.callID.utf8.count <= 256,
                  call.callID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  call.arguments.utf8.count <= maximumArgumentBytes else { throw AssistantToolLoopError.invalidCall }
            guard let definition = definitions[call.name] else { throw AssistantToolLoopError.unavailableTool }
            let arguments: AssistantWireValue
            do { arguments = try JSONDecoder().decode(AssistantWireValue.self, from: Data(call.arguments.utf8)) }
            catch { throw AssistantToolLoopError.invalidCall }
            guard case .object(let values) = arguments,
                  Set(values.keys).isSubset(of: Set(definition.parameters.properties.keys)),
                  Set(definition.parameters.required).isSubset(of: Set(values.keys)) else { throw AssistantToolLoopError.invalidCall }
            for (key, value) in values {
                guard let parameter = definition.parameters.properties[key], case .string(let string) = value,
                      parameter.values?.contains(string) ?? true,
                      string.count <= (parameter.maxLength ?? Int.max) else { throw AssistantToolLoopError.invalidCall }
            }
            if let previous = executed[call.callID] {
                guard previous.name == call.name, previous.arguments == arguments else { throw AssistantToolLoopError.changedCall }
            }
            if let previous = seen[call.callID] {
                guard previous.call.name == call.name, previous.arguments == arguments else { throw AssistantToolLoopError.changedCall }
                continue
            }
            let prepared = AssistantPreparedToolCall(call: call, arguments: arguments)
            seen[call.callID] = prepared
            result.append(prepared)
        }
        guard executed.count + result.filter({ executed[$0.call.callID] == nil }).count <= maximumCalls else {
            throw AssistantToolLoopError.limitExceeded
        }
        return result
    }
}
