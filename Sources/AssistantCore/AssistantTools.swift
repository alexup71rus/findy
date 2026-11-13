import Foundation

public struct AssistantToolDefinition: Encodable, Equatable, Sendable {
    public struct Parameter: Encodable, Equatable, Sendable {
        public let type = "string"
        public var description: String
        public var values: [String]?
        public var maxLength: Int?

        public init(_ description: String, values: [String]? = nil, maxLength: Int? = nil) {
            self.description = description
            self.values = values
            self.maxLength = maxLength
        }

        private enum CodingKeys: String, CodingKey { case type, description, values = "enum", maxLength }
    }

    public struct Parameters: Encodable, Equatable, Sendable {
        public let type = "object"
        public let additionalProperties = false
        public var properties: [String: Parameter]
        public var required: [String]

        public init(properties: [String: Parameter], required: [String]) {
            self.properties = properties
            self.required = required
        }
    }

    public let type = "function"
    public var name: String
    public var description: String
    public var parameters: Parameters

    public init(name: String, description: String, parameters: Parameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AssistantToolCall: Codable, Equatable, Sendable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct AssistantToolResult: Equatable, Sendable {
    public let output: String
    public let sources: [AssistantSource]
    public let usedWebSearch: Bool

    public init(output: String, sources: [AssistantSource] = [], usedWebSearch: Bool = false) {
        self.output = output
        self.sources = sources
        self.usedWebSearch = usedWebSearch
    }
}

public typealias AssistantToolHandler = @Sendable (AssistantToolCall) async throws -> AssistantToolResult

/// Deliberate user requests authorize durable personal changes. Merely
/// mentioning a fact or quoting a command must not silently create a memory.
public enum PersonalRequestPolicy {
    public static func allowsMemorySave(_ request: String) -> Bool {
        if request.lowercased().range(of: #"^(?:можешь\s+)?запомни(?:ть)?\s+что[- ]?(?:нибудь|то)\s*[?.!]*$"#, options: .regularExpression) != nil { return false }
        return matches(request, positive: [
            #"^(?:пожалуйста[, ]+)?(?:да[, ]+)?(?:запомни|запоминай|сохрани в памяти|сохрани это в памяти|помни,? что)\b"#,
            #"[,;.!]\s*(?:пожалуйста[, ]+)?(?:запомни|сохрани в памяти)(?: это)?[.!\s]*$"#,
            #"^(?:please\s+)?(?:remember|save (?:this|that) (?:to|in) memory)\b"#,
            #"^(?:можешь\s+запомнить|хочу,?\s+чтобы\s+ты\s+запомнил|не\s+забудь,?\s+что)\b"#,
            #"(?:,\s*|\bи\s+)запомни\b"#
        ], negative: #"\b(?:не\s+(?:запоминай|запомни|сохраняй)|don't remember|do not remember)\b"#)
    }

    public static func supportsMemoryUpdate(quote: String, currentRequest: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let request = normalized(currentRequest)
        let evidence = normalized(quote)
        guard !request.isEmpty, evidence.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2,
              request.contains(evidence) else { return false }
        return allowsMemoryMaintenance(currentRequest)
    }

    public static func allowsMemoryMaintenance(_ request: String) -> Bool {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return request.lowercased().range(of: #"\b(?:не\s+(?:(?:надо|нужно)\s+)?(?:запоминай|запомни|запоминать|сохраняй|сохрани|сохранять|меняй|менять|изменяй|изменять|обновляй|обновлять)\b|don't\s+(?:remember|save|update)|do not\s+(?:remember|save|update))"#, options: .regularExpression) == nil
    }

    public static func rejectsMemoryRemoval(_ request: String) -> Bool {
        request.lowercased().range(of: #"\b(?:не\s+(?:(?:надо|нужно)\s+)?(?:забывай|забудь|удаляй|удалять|удалить)\b|don't\s+(?:forget|delete)|do not\s+(?:forget|delete))"#, options: .regularExpression) != nil
    }

    public static func allowsMemoryRemoval(_ request: String) -> Bool {
        matches(request, positive: [
            #"^(?:пожалуйста[, ]+)?(?:да[, ]+)?(?:забудь|удали из памяти|убери из памяти)\b"#,
            #"^(?:please\s+)?(?:forget|remove .* from memory|delete .* from memory)\b"#
        ], negative: #"\b(?:не\s+(?:забывай|удаляй)|don't forget|do not forget)\b"#)
    }

    public static func rejectsReminderCreation(_ request: String) -> Bool {
        request.lowercased().range(of: #"\b(?:не\s+(?:напоминай|напомни|создавай|добавляй|ставь|создавать|создать|добавлять|добавить|ставить|поставить)\b|don't\s+remind|do not\s+remind)"#, options: .regularExpression) != nil
    }

    public static func rejectsReminderChange(_ request: String) -> Bool {
        request.lowercased().range(of: #"\b(?:не\s+(?:удаляй|отменяй|меняй|переноси|удалять|отменять|менять|переносить)\b|don't\s+(?:delete|cancel|change|reschedule)|do not\s+(?:delete|cancel|change|reschedule))"#, options: .regularExpression) != nil
    }

    public static func allowsReminderCreation(_ request: String) -> Bool {
        if request.lowercased().range(of: #"\b(?:если|предположим)\b[^.!?\n]*\b(?:напоминани[еия]|напомни)\b"#, options: .regularExpression) != nil { return false }
        if request.lowercased().range(of: #"^напомни[, ]+(?:(?:о\s+чем|как|чем)\b|что\s+(?:мы|я|ты|вы)\s+(?:обсуждали|говорили|писали|делали)\b)"#, options: .regularExpression) != nil { return false }
        return matches(request, positive: [
            #"^(?:пожалуйста[, ]+)?(?:да[, ]+)?(?:напомни|напоминай|создай напоминание|поставь напоминание|добавь напоминание|запланируй напоминание)\b"#,
            #"[,;.!]\s*(?:пожалуйста[, ]+)?напомни\b"#,
            #"^(?:please\s+)?(?:remind me|set a reminder|create a reminder|add a reminder)\b"#,
            #"^(?:не\s+забудь\s+напомнить|можешь\s+напомнить)\b"#,
            #"(?:,\s*|\bи\s+)напомни\b"#,
            #"\b(?:попробую|давай|хочу|нужно|надо|можешь|можно)\b[^.!?\n]{0,80}\bнапоминани[еия]\b[^.!?\n]{0,40}\b(?:добавить|создать|поставить|сделать|запланировать)\b"#,
            #"\b(?:давай|хочу|нужно|надо|можешь|можно)\b[^.!?\n]{0,40}\b(?:добавим|создадим|поставим|сделаем|добавить|создать|поставить|сделать|запланировать)\b[^.!?\n]{0,40}\bнапоминани[еия]\b"#
        ], negative: #"\b(?:не\s+(?:напоминай|напомни|создавай|добавляй|ставь|создавать|создать|добавлять|добавить|ставить|поставить|делать|сделать|планировать|запланировать|хочу|надо|нужно)|don't remind|do not remind)\b"#)
    }

    public static func allowsReminderChange(_ request: String) -> Bool {
        // A generic editing command (for example, deleting a chat message or
        // changing an answer) does not authorize touching personal reminders.
        // Ambiguous pronouns can be clarified by the assistant before mutation.
        matches(request, positive: [
            #"^(?:пожалуйста[, ]+)?(?:да[, ]+)?(?:перенеси|измени|удали|отмени|убери|заверши|отметь|поменяй)\b[^\n.!?]*\bнапоминани[а-я]*\b"#,
            #"^(?:please\s+)?(?:reschedule|change|delete|cancel|remove|complete|mark)\b[^\n.!?]*\breminders?\b"#
        ], negative: #"\b(?:не\s+(?:удаляй|отменяй|меняй|переноси)|don't|do not)\b"#)
    }

    public static func requestsRepeatingReminder(_ request: String) -> Bool {
        request.lowercased().range(of: #"\b(?:кажд(?:ый|ую|ое|ые|ого)|ежедневно|еженедельно|ежемесячно|по\s+(?:понедельникам|вторникам|средам|четвергам|пятницам|субботам|воскресеньям)|раз\s+в\s+(?:день|неделю|месяц)|every\s+(?:other\s+)?(?:day|week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|daily|weekly|monthly)\b"#, options: .regularExpression) != nil
    }

    private static func matches(_ request: String, positive: [String], negative: String) -> Bool {
        let value = request.replacingOccurrences(of: #"«[^»]*»|“[^”]*”|‘[^’]*’|\"[^\"]*\"|`[^`]*`"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
        guard value.range(of: negative, options: .regularExpression) == nil else { return false }
        return positive.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}

public enum PersonalTools {
    public static let definitions: [AssistantToolDefinition] = [
        AssistantToolDefinition(
            name: "manage_memory",
            description: "Долговременная память Findy на iPhone: до \(AssistantLimits.memorySlots) записей по \(AssistantLimits.memoryNoteCharacters) символов. Новую запись создавай только по явной просьбе «запомни», удаляй только по просьбе «забудь». Если пользователь сообщил новое или исправил старое о себе, найди связанные записи через search и обнови существующую с update, передав точную цитату из текущей реплики в source_quote. Не обновляй по догадкам, цитатам других людей, гипотетическим примерам или при запрете сохранять; сохраняй непротиворечивые подробности. Если память полна, сначала компактно объедини только действительно связанные записи через merge, сохраняя непротиворечивые сведения в одной записи (до двух предложений), либо обнови устаревшее; если связанной записи нет, сохраняй новый факт через save: система заменит самую давно обновлённую запись и сообщит об этом. Не сохраняй секретные ключи и пароли. Для вопросов, где могут пригодиться сохранённые личные факты и предпочтения, сначала вызывай search с ключевыми словами. Для явного запроса перечислить память используй list; get возвращает полный текст записи по ID. Поиск возвращает до пяти наиболее подходящих записей; при отсутствии результата попробуй другие или более короткие ключевые слова либо list, прежде чем считать факт отсутствующим.",
            parameters: .init(properties: [
                "action": .init("Действие с памятью.", values: ["save", "update", "merge", "remove", "search", "list", "get"]),
                "text": .init("Полный объединённый текст для merge, обновлённый текст для update или краткий факт для save.", maxLength: AssistantLimits.memoryNoteCharacters),
                "memory_id": .init("Точный ID существующей записи для get, update, remove либо замены при save."),
                "query": .init("Ключевые слова для поиска: используй основные слова о нужном факте, без полного вопроса.", maxLength: 300),
                "merge_with_id": .init("Точный ID второй связанной записи для merge. Она объединяется в memory_id и удаляется после успешного слияния."),
                "source_quote": .init("Для update: точная содержательная цитата из последней реплики пользователя, подтверждающая обновление; не цитируй слова ассистента.", maxLength: 500)
            ], required: ["action"])
        ),
        AssistantToolDefinition(
            name: "manage_reminders",
            description: "Напоминания, созданные через Findy: новые в приложении «Напоминания» на iPhone и старые локальные. list не показывает все записи системного приложения. Создавай, меняй и удаляй только по явной просьбе пользователя. Не обещай напоминание до успешного результата инструмента. Если время неоднозначно — сначала уточни. Повторяющиеся напоминания пока не поддерживаются.",
            parameters: .init(properties: [
                "action": .init("Действие с напоминаниями.", values: ["create", "list", "update", "complete", "delete"]),
                "title": .init("Кратко, о чём напомнить.", maxLength: 300),
                "due_at": .init("Точный момент ISO 8601 с часовым поясом, например 2026-11-13T20:00:00+03:00. Используй текущие местные дату и часовой пояс из инструкций."),
                "reminder_id": .init("Точный ID существующего напоминания для update, complete или delete."),
                "advance": .init("Дополнительный сигнал за час: on — если пользователь попросил за час, off — только в указанное время, default — настройка по умолчанию при создании или сохранение прежнего выбора при изменении. Для on до события должно оставаться больше часа.", values: ["on", "off", "default"])
            ], required: ["action"])
        )
    ]
}

public enum ContextTools {
    public static let definitions: [AssistantToolDefinition] = [
        AssistantToolDefinition(name: "get_current_context",
            description: "Получи актуальные местные дату, время, часовой пояс и техническую модель iPhone. Используй для вопросов о текущем времени и относительных датах; время в начальных инструкциях может устареть.",
            parameters: .init(properties: [:], required: []))
    ]
}

/// Ground voice-only ending in the latest finalized utterance, not history
/// or tool data; reject common ambiguous uses before the semantic decision.
public enum VoiceConversationEnd {
    public static let definition = AssistantToolDefinition(
        name: "end_voice_conversation",
        description: "Заверши только голосовой разговор после короткого прощания, только при очень высокой уверенности (не менее 90%), что последняя реплика явно означает, что пользователь закончил разговор или просит отключиться. В source_quote дословно приведи всю последнюю реплику пользователя. Не вызывай при одной лишь благодарности, тишине, вопросе с прощанием, цитате, переводе, фразе «пока не надо» или любом сомнении. Сначала ответь на вопрос; если пользователь продолжает говорить, разговор продолжается.",
        parameters: .init(properties: ["source_quote": .init("Вся последняя реплика пользователя дословно.", maxLength: 500)], required: ["source_quote"])
    )
    public static func isStandaloneFarewell(_ request: String) -> Bool {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.range(of: #"^(?:пока|до свидания|спокойной ночи|прощай|всего доброго|до встречи|выключись|goodbye|bye|good night)[.!…\s]*$"#, options: .regularExpression) != nil
    }
    public static func farewell(for request: String) -> String {
        request.lowercased().contains("ночи") || request.lowercased().contains("night") ? "Спокойной ночи!" : "До свидания!"
    }
    public static func containsFarewell(_ text: String) -> Bool {
        let value = text.lowercased()
        guard value.rangeOfCharacter(from: CharacterSet(charactersIn: "?？«»\"“”‘’`")) == nil,
              value.range(of: #"(?:пока\s+не|не\s+прощай|сказал|сказала|перевод|translate|quote)"#, options: .regularExpression) == nil else { return false }
        return value.range(of: #"(?:^|[\s,;.!…])(?:пока|до свидания|спокойной ночи|прощай|всего доброго|до встречи|goodbye|good night|bye)(?:$|[\s,;.!…])"#, options: .regularExpression) != nil
    }
    public static func allowsCall(arguments: String, latestUtterance: String) -> Bool {
        struct Arguments: Decodable { let source_quote: String }
        guard arguments.utf8.count <= 4096, let data = arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(Arguments.self, from: data) else { return false }
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
        let request = normalized(latestUtterance)
        guard !request.isEmpty, request.count <= 500, normalized(args.source_quote) == request else { return false }
        guard request.rangeOfCharacter(from: CharacterSet(charactersIn: "?？«»\"“”‘’`")) == nil else { return false }
        if isStandaloneFarewell(request) { return true }
        guard request.range(of: #"^(?:спасибо|благодарю|thanks|thank you)[.!…\s]*$"#, options: .regularExpression) == nil,
              request.range(of: #"(?:^|\s)(?:пока\s+не|не\s+(?:(?:надо|нужно)\s+)?(?:завершай|завершать|выключай(?:ся)?|выключать(?:ся)?|отключай(?:ся)?|отключать(?:ся)?|заканчивай|заканчивать)|не\s+прощайся|переведи|перевод|цитат|произнеси|скажи\s+слово|don't\s+(?:stop|end|disconnect)|do not\s+(?:stop|end|disconnect)|translate|quote)"#, options: .regularExpression) == nil,
              request.range(of: #"(?:^|[,;.!…]\s*)(?:кто|что|где|когда|как|почему|зачем|сколько|какой|какая|можешь|расскажи|объясни|подскажи|напомни|who|what|where|when|why|how|can you|tell me)(?:\s|$)"#, options: .regularExpression) == nil,
              request.range(of: #"(?:^|[\s,])(?:напомни|расскажи|объясни|подскажи|покажи|вопрос|перевести|перевод|сказал|сказала|сказали|said|question|remind|explain)(?:[\s,.!…]|$)"#, options: .regularExpression) == nil else { return false }
        return request.range(of: #"(?:на сегодня\s+(?:всё|все)|(?:это|на этом)\s+(?:всё|все)|мне\s+пора|я\s+(?:пойду|иду)\s+(?:спать|отдыхать)|(?:давай|пора)\s+(?:закончим|заканчивать|завершим|завершать)|(?:закончи|заверши|закончить|завершить)\s+(?:разговор|беседу|сеанс)|(?:отключись|выключись|прощай|до завтра|до встречи)|(?:that's all|i(?:'| a)m done|i have to go|end (?:the )?(?:conversation|session)|goodbye))"#, options: .regularExpression) != nil
    }
}

/// The tool acknowledges intent before a separate response and playback. A new
/// utterance invalidates all three pieces of evidence for the old turn.
public struct VoiceEndState: Sendable {
    public private(set) var pending = false
    private var finishedResponse = false
    public init() {}
    public mutating func reset() { pending = false; finishedResponse = false }
    public mutating func request(preservingCurrentResponse: Bool = false) {
        pending = true
        if !preservingCurrentResponse { finishedResponse = false }
    }
    public mutating func responseCompleted(success: Bool, hasToolCalls: Bool) {
        if hasToolCalls { finishedResponse = false; return }
        if success { finishedResponse = true } else { reset() }
    }
    public func shouldEnd(isPlaying: Bool, userSpeaking: Bool, responseActive: Bool) -> Bool {
        pending && finishedResponse && !isPlaying && !userSpeaking && !responseActive
    }
}

/// Native Realtime VAD detects turns; the app starts exactly one response only
/// after both speech end and the final transcript for the same item arrive.
public struct VoiceResponseGate: Sendable {
    public enum Decision: Equatable, Sendable { case respond, farewell(String) }
    private var itemID: String?
    private var stopped = false
    private var finalText: String?
    private var requested = false
    public init() {}
    public mutating func begin(itemID: String) { self.itemID = itemID; stopped = false; finalText = nil; requested = false }
    public func isCurrent(itemID: String) -> Bool { self.itemID == itemID }
    public mutating func speechStopped(itemID: String) -> Decision? {
        guard self.itemID == itemID else { return nil }
        stopped = true
        return decision()
    }
    public mutating func transcript(itemID: String, text: String) -> Decision? {
        guard self.itemID == itemID else { return nil }
        finalText = text
        return decision()
    }
    private mutating func decision() -> Decision? {
        guard stopped, let text = finalText, !requested else { return nil }
        requested = true
        return VoiceConversationEnd.isStandaloneFarewell(text) ? .farewell(text) : .respond
    }
}
