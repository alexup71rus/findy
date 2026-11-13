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

    public static func allowsMemoryRemoval(_ request: String) -> Bool {
        matches(request, positive: [
            #"^(?:пожалуйста[, ]+)?(?:да[, ]+)?(?:забудь|удали из памяти|убери из памяти)\b"#,
            #"^(?:please\s+)?(?:forget|remove .* from memory|delete .* from memory)\b"#
        ], negative: #"\b(?:не\s+(?:забывай|удаляй)|don't forget|do not forget)\b"#)
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
            description: "Долговременная память Findy на iPhone: до \(AssistantLimits.memorySlots) записей по \(AssistantLimits.memoryNoteCharacters) символов. При заполнении предложи изменить или удалить запись. Сохраняй или удаляй сведения только по явной просьбе пользователя: «запомни», «забудь». Обычный рассказ о себе не является такой просьбой. Не сохраняй секретные ключи и пароли. Для поиска сохранённых сведений используй search.",
            parameters: .init(properties: [
                "action": .init("Действие с памятью.", values: ["save", "remove", "search"]),
                "text": .init("Один краткий факт или предпочтение пользователя для save.", maxLength: AssistantLimits.memoryNoteCharacters),
                "memory_id": .init("Точный ID существующего воспоминания для remove либо замены при save."),
                "query": .init("Слова для поиска в памяти; пустая строка возвращает недавние сведения.", maxLength: 300)
            ], required: ["action"])
        ),
        AssistantToolDefinition(
            name: "manage_reminders",
            description: "Личные напоминания в приложении «Напоминания» на iPhone. Создавай, меняй и удаляй только по явной просьбе пользователя. Не обещай напоминание до успешного результата инструмента. Если время неоднозначно — сначала уточни. Повторяющиеся напоминания пока не поддерживаются.",
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
