import Combine
import Foundation

@MainActor
final class PersonalData: ObservableObject {
    static let shared = PersonalData()

    let store: LocalDataStore?
    let reminders: ReminderScheduler?
    @Published private(set) var memories: [MemoryFact] = []
    @Published private(set) var memoryCount: Int = 0
    @Published private(set) var lastError: String?

    private init() {
        do {
            var directory = URL.applicationSupportDirectory.appending(path: "Findy", directoryHint: .isDirectory)
            var legacyURL = URL.applicationSupportDirectory.appending(path: "Findy-legacy-history.json")
            #if DEBUG && targetEnvironment(simulator)
            if let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"], let id = UUID(uuidString: value) {
                directory = directory.appending(path: "UITests/" + id.uuidString, directoryHint: .isDirectory)
                legacyURL = directory.appending(path: "Findy-legacy-history.json")
            }
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let databaseURL = directory.appending(path: "findy.sqlite")
            let storage = try LocalDataStore(databaseURL: databaseURL)
            for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
                where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                let messages = try JSONDecoder().decode([AssistantMessage].self, from: Data(contentsOf: legacyURL))
                let settings = AssistantSettings.shared
                let scope = Self.contextScope(settings: settings)
                for message in messages { try storage.upsertMessage(message, scope: scope) }
                try FileManager.default.removeItem(at: legacyURL)
            }
            let savedMemories = try storage.allMemories()
            let savedMemoryCount = try storage.memoryCount()
            store = storage
            reminders = ReminderScheduler(store: storage)
            memories = savedMemories
            memoryCount = savedMemoryCount
        } catch {
            store = nil
            reminders = nil
            lastError = "Не удалось открыть данные Findy. \(error.localizedDescription)"
        }
    }

    static func contextScope(settings: AssistantSettings) -> String {
        "conversation"
    }

    func requireStore() throws -> LocalDataStore {
        guard let store else { throw PersonalDataError.unavailable }
        return store
    }

    func refresh() async {
        do {
            try refreshMemories()
            try await reminders?.refresh()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    @discardableResult
    func saveMemory(text: String, replacing id: UUID? = nil) throws -> MemoryFact {
        let storage = try requireStore()
        let fact: MemoryFact
        if let id {
            guard var existing = try storage.getMemory(id: id) else { throw PersonalDataError.notFound }
            existing.text = text
            existing.updatedAt = Date()
            fact = existing
        } else { fact = MemoryFact(text: text) }
        let saved = try storage.upsertMemory(fact)
        try refreshMemories()
        return saved
    }

    func deleteMemory(id: UUID) throws {
        try requireStore().deleteMemory(id: id)
        try refreshMemories()
    }

    private func refreshMemories() throws {
        let storage = try requireStore()
        let records = try storage.allMemories()
        let count = try storage.memoryCount()
        memories = records
        memoryCount = count
    }

    func instructions(base: String, now: Date = Date()) throws -> String {
        let storage = try requireStore()
        let facts = try storage.memories(limit: AssistantLimits.memorySlots)
        let hasLegacyOmissions = try storage.memoryCount() > facts.count || facts.contains { $0.text.count > AssistantLimits.memoryNoteCharacters }
        let memoryNotice = hasLegacyOmissions ? "В контексте только первые \(AssistantLimits.memoryNoteCharacters) символов каждой из \(facts.count) недавних записей; полные старые записи сохранены в приложении. Для поиска остальных сведений используй manage_memory action=search." : ""
        let selected = Self.promptFacts(from: facts)
        let memoryJSON = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        let instant = formatter.string(from: now)
        return base + """


        У Findy есть локальная история, долговременная память и напоминания на iPhone.
        Отвечай обычно двумя-тремя короткими предложениями, не более трёх предложений в ответе.
        В контексте только недавние сообщения. Не выдумывай содержание более старого разговора.
        Память сохраняй только по прямой просьбе пользователя («запомни»), удаляй по просьбе «забудь». Для этого обязательно вызови manage_memory; до успешного результата не говори «запомнил» или «забыл». Не сохраняй автоматически обычный рассказ о себе. Если нужного личного факта нет ниже, поищи его через manage_memory action=search, если инструмент доступен.
        Память вмещает \(AssistantLimits.memorySlots) записей, каждая до \(AssistantLimits.memoryNoteCharacters) символов. При заполнении предложи изменить или удалить существующую запись. Не обещай сохранение при ошибке инструмента.
        Напоминания создавай/меняй через manage_reminders только по явной просьбе. Обещай напомнить только после успешного результата инструмента; при ошибке разрешений объясни, что нужно включить уведомления Findy. Не подменяй напоминание обещанием в тексте. Если дата или время неоднозначны, уточни. Идентификаторы инструментов, UUID и технические поля не зачитывай.
        Сохранённые пользователем сведения (данные и предпочтения): \(memoryJSON)
        \(memoryNotice)
        Текущее местное время: \(instant). Часовой пояс iPhone: \(TimeZone.autoupdatingCurrent.identifier). Для «завтра» и «вечером» используй этот местный календарный день, вечерние 8 часов = 20:00. due_at передавай с явным UTC-смещением.
        """
    }

    private struct PromptFact: Encodable { let id: UUID; let text: String }

    private static func promptFacts(from facts: [MemoryFact]) -> [PromptFact] {
        facts.prefix(AssistantLimits.memorySlots).map { fact in
            // Bound only the request copy of legacy notes. Stored user data
            // remains intact and can still be viewed, searched and edited.
            PromptFact(id: fact.id, text: AssistantLimits.clipped(fact.text, to: AssistantLimits.memoryNoteCharacters))
        }
    }

    func tools(for request: String, realtime: Bool) -> [AssistantToolDefinition] {
        let value = request.lowercased()
        let keywords = ["запом", "памят", "забуд", "напом", "перенес", "перенёс", "перенеси", "отмени", "удали", "заверши", "отметь", "remember", "memory", "remind", "forget", "schedule", "cancel"]
        let hasOmittedMemory = memoryCount > AssistantLimits.memorySlots || memories.prefix(AssistantLimits.memorySlots).contains { $0.text.count > AssistantLimits.memoryNoteCharacters }
        return keywords.contains(where: value.contains) || hasOmittedMemory ? PersonalTools.definitions : []
    }
}

enum PersonalDataError: Error, LocalizedError {
    case unavailable, notFound, explicitRequestRequired, invalidArguments, unknownTool, repeatingReminder
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Не удалось открыть локальную историю Findy. Перезапустите приложение."
        case .notFound: return "Запись больше не найдена. Обновите список."
        case .explicitRequestRequired: return "Для изменения памяти или напоминаний нужна явная просьба пользователя."
        case .invalidArguments: return "Не удалось определить данные для этого действия. Уточните просьбу."
        case .unknownTool: return "Этот инструмент не поддерживается Findy."
        case .repeatingReminder: return "Пока доступны разовые напоминания. Укажите конкретную дату и время."
        }
    }
}
