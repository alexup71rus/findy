import Foundation
import UIKit

@MainActor
enum AssistantToolExecutor {
    private static var intents: [String: PersonalIntentTracker] = [:]

    static func registerUserMessage(_ message: AssistantMessage, scope: String) throws {
        guard message.role == .user, !message.text.isEmpty else { return }
        var tracker = try intent(scope: scope)
        tracker.accept(id: message.id, text: message.text)
        intents[scope] = tracker
        try save(tracker, scope: scope)
    }

    static func hasPendingRequest(scope: String) throws -> Bool { try intent(scope: scope).hasPendingRequest() }

    static func clearIntent(scope: String) throws {
        intents[scope] = nil
        try PersonalData.shared.requireStore().setLocalState(nil, for: "intent." + scope)
    }

    static func clearAllIntents() { intents = [:] }
    private struct Arguments: Decodable {
        let action: String
        let text: String?
        let memory_id: String?
        let source_quote: String?
        let merge_with_id: String?
        let query: String?
        let title: String?
        let due_at: String?
        let reminder_id: String?
        let advance: String?
    }

    private struct MemorySnapshot: Encodable {
        let id: UUID
        let text: String
        init(_ fact: MemoryFact, clipped: Bool = false) {
            id = fact.id
            text = clipped ? AssistantLimits.clipped(fact.text, to: AssistantLimits.memoryNoteCharacters) : fact.text
        }
    }

    private struct Output: Encodable {
        var ok: Bool
        var message: String?
        var memory: MemorySnapshot?
        var memories: [MemorySnapshot]?
        var reminder: LocalReminder?
        var reminders: [LocalReminder]?
        var localTime: String?
        var timeZone: String?
        var deviceModel: String?
        var systemVersion: String?
        var weekday: String?
        var memoryTotal: Int?
        var hasMore: Bool?
        var advanceReminderEnabled: Bool?
    }

    static func execute(_ call: AssistantToolCall, userRequest: String,
                        scope: String, configuration: AssistantConfiguration, apiKey: String) async throws -> AssistantToolResult {
        try Task.checkCancellation()
        do {
            if call.name == "web_search" {
                let reply = try await RealtimeSearchTool.execute(call, configuration: configuration, apiKey: apiKey)
                return AssistantToolResult(output: try RealtimeSearchTool.output(reply), sources: reply.sources, usedWebSearch: true)
            }
            if call.name == "generate_image" {
                return try await GeneratedImages.generate(call: call, configuration: configuration, apiKey: apiKey, scope: scope)
            }
            if call.name == "get_current_context" {
                let formatter = ISO8601DateFormatter()
                formatter.timeZone = .autoupdatingCurrent
                let now = Date()
                let weekday = DateFormatter()
                weekday.locale = Locale(identifier: "ru_RU")
                weekday.timeZone = .autoupdatingCurrent
                weekday.dateFormat = "EEEE"
                var machine = utsname()
                uname(&machine)
                let model = withUnsafeBytes(of: &machine.machine) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                return try encode(Output(ok: true, localTime: formatter.string(from: now), timeZone: TimeZone.autoupdatingCurrent.identifier,
                    deviceModel: model, systemVersion: UIDevice.current.systemVersion, weekday: weekday.string(from: now)))
            }
            guard call.arguments.utf8.count <= 16_384,
                  let data = call.arguments.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
                throw PersonalDataError.invalidArguments
            }
            let result: Output
            switch call.name {
            case "manage_memory": result = try memory(arguments, userRequest: userRequest, scope: scope)
            case "manage_reminders": result = try await reminder(arguments, userRequest: userRequest, scope: scope)
            default: throw PersonalDataError.unknownTool
            }
            return try encode(result)
        } catch is CancellationError { throw CancellationError() }
        catch {
            SessionLog.shared.record("personal.tool.failed", "tool=\(knownName(call.name)) \(SessionLog.describe(error))")
            return try encode(Output(ok: false, message: error.localizedDescription))
        }
    }

    private static func memory(_ arguments: Arguments, userRequest: String, scope: String) throws -> Output {
        let personal = PersonalData.shared
        let store = try personal.requireStore()
        switch arguments.action {
        case "save":
            _ = try authorized(.saveMemory, request: userRequest, scope: scope)
            guard let text = arguments.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonalDataError.invalidArguments }
            let id = try optionalID(arguments.memory_id)
            let result: (memory: MemoryFact, evicted: Bool)
            if let id { result = (try personal.saveMemory(text: text, replacing: id), false) }
            else { result = try personal.saveNewMemoryEvictingOldestIfFull(text: text) }
            try completed(.saveMemory, scope: scope)
            SessionLog.shared.record("personal.memory.saved", "count=\(personal.memoryCount)")
            return Output(ok: true, message: result.evicted ? "Новый факт сохранён; для него заменена самая давно обновлённая запись памяти." : nil, memory: MemorySnapshot(result.memory))
        case "update":
            guard let id = try optionalID(arguments.memory_id), try store.getMemory(id: id) != nil else { throw PersonalDataError.notFound }
            guard let text = arguments.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let quote = arguments.source_quote, try intent(scope: scope).isCurrentUserRequest(userRequest),
                  PersonalRequestPolicy.supportsMemoryUpdate(quote: quote, currentRequest: userRequest) else { throw PersonalDataError.memoryEvidenceRequired }
            let fact = try personal.saveMemory(text: text, replacing: id)
            SessionLog.shared.record("personal.memory.updated", "count=\(personal.memoryCount)")
            return Output(ok: true, memory: MemorySnapshot(fact))
        case "merge":
            guard try intent(scope: scope).isCurrentUserRequest(userRequest), PersonalRequestPolicy.allowsMemoryMaintenance(userRequest),
                  !PersonalRequestPolicy.rejectsMemoryRemoval(userRequest) else { throw PersonalDataError.memoryEvidenceRequired }
            guard let id = try optionalID(arguments.memory_id), let otherID = try optionalID(arguments.merge_with_id), let text = arguments.text else { throw PersonalDataError.invalidArguments }
            let fact = try personal.mergeMemories(keeping: id, removing: otherID, text: text)
            SessionLog.shared.record("personal.memory.merged", "count=\(personal.memoryCount)")
            return Output(ok: true, message: "Связанные записи объединены.", memory: MemorySnapshot(fact))
        case "remove":
            _ = try authorized(.removeMemory, request: userRequest, scope: scope)
            guard let id = try optionalID(arguments.memory_id), try store.getMemory(id: id) != nil else { throw PersonalDataError.notFound }
            try personal.deleteMemory(id: id)
            try completed(.removeMemory, scope: scope)
            SessionLog.shared.record("personal.memory.removed", "count=\(personal.memoryCount)")
            return Output(ok: true, message: "Сведение удалено из долговременной памяти.")
        case "search", "list":
            let found = arguments.action == "search"
                ? try store.searchMemories(arguments.query ?? "", limit: 6)
                : try store.memories(limit: AssistantLimits.memorySlots)
            let matches = arguments.action == "search" ? Array(found.prefix(5)) : found
            let clipped = matches.contains { $0.text.count > AssistantLimits.memoryNoteCharacters }
            let count = try store.memoryCount()
            let snapshots = matches.map { MemorySnapshot($0, clipped: true) }
            var notices: [String] = []
            if clipped { notices.append("Некоторые старые записи сокращены; вызови get с memory_id для полного текста.") }
            if arguments.action == "list" && count > matches.count { notices.append("Показаны \(matches.count) из \(count) записей; остальные сохранены и доступны через поиск.") }
            return Output(ok: true, message: notices.isEmpty ? nil : notices.joined(separator: " "), memories: snapshots,
                memoryTotal: count, hasMore: arguments.action == "search" ? found.count > matches.count : count > matches.count)
        case "get":
            guard let id = try optionalID(arguments.memory_id), let fact = try store.getMemory(id: id) else { throw PersonalDataError.notFound }
            return Output(ok: true, memory: MemorySnapshot(fact))
        default: throw PersonalDataError.invalidArguments
        }
    }

    private static func reminder(_ arguments: Arguments, userRequest: String, scope: String) async throws -> Output {
        let personal = PersonalData.shared
        let store = try personal.requireStore()
        guard let scheduler = personal.reminders else { throw PersonalDataError.unavailable }
        let saved: LocalReminder
        let advance: Bool?
        switch arguments.advance {
        case nil, "default": advance = nil
        case "on": advance = true
        case "off": advance = false
        default: throw PersonalDataError.invalidArguments
        }
        switch arguments.action {
        case "create":
            let request = try authorized(.createReminder, request: userRequest, scope: scope)
            guard !PersonalRequestPolicy.requestsRepeatingReminder(request) else { throw PersonalDataError.repeatingReminder }
            guard let title = arguments.title, let dueAt = arguments.due_at else { throw PersonalDataError.invalidArguments }
            saved = try await scheduler.create(title: title, dueAt: ReminderScheduleRules.date(fromISO8601: dueAt), advance: advance)
            try completed(.createReminder, scope: scope)
        case "update":
            let request = try authorized(.changeReminder, request: userRequest, scope: scope)
            guard !PersonalRequestPolicy.requestsRepeatingReminder(request) else { throw PersonalDataError.repeatingReminder }
            guard let id = try optionalID(arguments.reminder_id), let existing = try store.getReminder(id: id) else { throw PersonalDataError.notFound }
            let date = try arguments.due_at.map { try ReminderScheduleRules.date(fromISO8601: $0) } ?? existing.dueAt
            saved = try await scheduler.update(id: id, title: arguments.title ?? existing.title, dueAt: date, advance: advance)
            try completed(.changeReminder, scope: scope)
        case "complete", "delete":
            _ = try authorized(.changeReminder, request: userRequest, scope: scope)
            guard let id = try optionalID(arguments.reminder_id) else { throw PersonalDataError.invalidArguments }
            if arguments.action == "complete" { try await scheduler.complete(id: id) }
            else { try await scheduler.delete(id: id) }
            try completed(.changeReminder, scope: scope)
            return Output(ok: true, message: arguments.action == "complete" ? "Напоминание выполнено." : "Напоминание удалено.")
        case "list":
            try await scheduler.refresh()
            let records = try store.reminders(limit: 10_000)
                .filter { $0.status != .completed }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .autoupdatingCurrent
            return Output(ok: true, message: "Показаны незавершённые напоминания, созданные через Findy, включая прошедшие; другие записи Apple Reminders сюда не входят.", reminders: Array(records.prefix(40)), localTime: formatter.string(from: Date()), timeZone: TimeZone.autoupdatingCurrent.identifier, hasMore: records.count > 40)
        default: throw PersonalDataError.invalidArguments
        }
        SessionLog.shared.record("personal.reminder.saved", "action=\(arguments.action)")
        let hasAdvance = scheduler.advanceAlarmEnabled(for: saved)
        let notice = arguments.advance == "on" && hasAdvance == false
            ? "Напоминание сохранено на указанное время. Сигнал за час не добавлен: до события осталось не больше часа."
            : nil
        return Output(ok: true, message: notice, reminder: saved, advanceReminderEnabled: hasAdvance)
    }

    private static func optionalID(_ value: String?) throws -> UUID? {
        guard let value, !value.isEmpty else { return nil }
        guard let id = UUID(uuidString: value) else { throw PersonalDataError.invalidArguments }
        return id
    }

    private static func encode(_ value: Output) throws -> AssistantToolResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return AssistantToolResult(output: String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func knownName(_ name: String) -> String {
        ["web_search", "manage_memory", "manage_reminders", "get_current_context", "generate_image"].contains(name) ? name : "unknown"
    }

    private static func intent(scope: String) throws -> PersonalIntentTracker {
        if let tracker = intents[scope] { return tracker }
        let saved = try PersonalData.shared.requireStore().localState(for: "intent." + scope)
        let tracker = saved.flatMap { try? JSONDecoder().decode(PersonalIntentTracker.self, from: $0) } ?? PersonalIntentTracker()
        intents[scope] = tracker
        return tracker
    }

    private static func authorized(_ action: PersonalMutation, request: String, scope: String) throws -> String {
        guard let value = try intent(scope: scope).request(for: action, currentRequest: request) else { throw PersonalDataError.explicitRequestRequired }
        return value
    }

    private static func completed(_ action: PersonalMutation, scope: String) throws {
        var tracker = try intent(scope: scope)
        tracker.didComplete(action)
        intents[scope] = tracker
        do { try save(tracker, scope: scope) }
        catch { SessionLog.shared.record("personal.intent.saveFailed") }
    }

    private static func save(_ tracker: PersonalIntentTracker, scope: String) throws {
        try PersonalData.shared.requireStore().setLocalState(JSONEncoder().encode(tracker), for: "intent." + scope)
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
extension AssistantToolExecutor {
    static func runMemorySmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["FINDY_MEMORY_SMOKE"] == "1" else { return }
        let resultURL = URL.documentsDirectory.appending(path: "memory-tool-smoke.txt")
        var inserted: UUID?
        var insertedReminder: UUID?
        do {
            let personal = PersonalData.shared
            let unique = "Памятьsmoke\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let fact = try personal.saveMemory(text: unique + " любит кофе")
            inserted = fact.id
            let prompt = try personal.instructions(base: "base")
            guard !prompt.contains(unique), prompt.contains("action=search"),
                  personal.tools(for: "Как дела?", realtime: false).contains(where: { $0.name == "manage_memory" }),
                  personal.tools(for: "Что запланировано?", realtime: true).contains(where: { $0.name == "manage_reminders" }) else { throw PersonalDataError.invalidArguments }
            func invoke(_ args: String) async throws -> [String: Any] {
                let result = try await execute(AssistantToolCall(callID: UUID().uuidString, name: "manage_memory", arguments: args), userRequest: "", scope: "smoke", configuration: AssistantConfiguration(), apiKey: "")
                guard let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], object["ok"] as? Bool == true else { throw PersonalDataError.invalidArguments }
                return object
            }
            let query = String(data: try JSONSerialization.data(withJSONObject: ["action": "search", "query": unique]), encoding: .utf8)!
            let search = try await invoke(query)
            let list = try await invoke("{\"action\":\"list\"}")
            let get = try await invoke("{\"action\":\"get\",\"memory_id\":\"\(fact.id.uuidString)\"}")
            let past = try personal.requireStore().upsertReminder(LocalReminder(title: "Smoke overdue", dueAt: Date().addingTimeInterval(-3600)))
            insertedReminder = past.id
            let reminderResult = try await execute(AssistantToolCall(callID: UUID().uuidString, name: "manage_reminders", arguments: "{\"action\":\"list\"}"), userRequest: "", scope: "smoke", configuration: AssistantConfiguration(), apiKey: "")
            let reminders = try JSONSerialization.jsonObject(with: Data(reminderResult.output.utf8)) as? [String: Any]
            guard (reminders?["reminders"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == past.id.uuidString }) == true,
                  (reminders?["message"] as? String)?.contains("другие записи Apple Reminders сюда не входят") == true else { throw PersonalDataError.notFound }
            guard (search["memories"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == fact.id.uuidString }) == true,
                  (list["memories"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == fact.id.uuidString }) == true,
                  (get["memory"] as? [String: Any])?["text"] as? String == fact.text else { throw PersonalDataError.notFound }
            try personal.deleteMemory(id: fact.id)
            inserted = nil
            try personal.requireStore().deleteReminder(id: past.id)
            insertedReminder = nil
            try "PASS prompt excludes fact; tools available; search, list, get; overdue reminder list scope".write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            if let inserted { try? PersonalData.shared.deleteMemory(id: inserted) }
            if let insertedReminder { try? PersonalData.shared.requireStore().deleteReminder(id: insertedReminder) }
            try? "FAIL \(error)".write(to: resultURL, atomically: true, encoding: .utf8)
        }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
@MainActor
extension AssistantToolExecutor {
    static func runMemoryUpdateSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["FINDY_MEMORY_UPDATE_SMOKE"] == "1" else { return }
        let resultURL = URL.documentsDirectory.appending(path: "memory-update-smoke.txt")
        let personal = PersonalData.shared
        var inserted: [UUID] = []
        do {
            for i in 0..<AssistantLimits.memorySlots {
                inserted.append(try personal.saveMemory(text: "Изолированный факт \(i)").id)
            }
            guard inserted.count == 30, personal.memoryCount == 30 else { throw PersonalDataError.invalidArguments }
            let unchanged = try personal.requireStore().getMemory(id: inserted[1])
            let current = "Теперь Москва — мой город."
            try registerUserMessage(AssistantMessage(role: .user, text: current), scope: "update-smoke")
            func invoke(_ fields: [String: String], request: String) async throws -> Bool {
                let data = try JSONSerialization.data(withJSONObject: fields)
                let call = AssistantToolCall(callID: UUID().uuidString, name: "manage_memory", arguments: String(decoding: data, as: UTF8.self))
                let result = try await execute(call, userRequest: request, scope: "update-smoke", configuration: AssistantConfiguration(), apiKey: "")
                return (try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])?["ok"] as? Bool == true
            }
            let base = ["action": "update", "memory_id": inserted[0].uuidString, "text": "Живёт в Москве"]
            var withoutQuote = base
            guard try await !invoke(withoutQuote, request: current) else { throw PersonalDataError.invalidArguments }
            withoutQuote["source_quote"] = "Совсем другое"
            guard try await !invoke(withoutQuote, request: current) else { throw PersonalDataError.invalidArguments }
            withoutQuote["source_quote"] = "Теперь Москва"
            guard try await !invoke(withoutQuote, request: ""),
                  try await !invoke(withoutQuote, request: "Уже другой запрос") else { throw PersonalDataError.invalidArguments }
            var missing = withoutQuote
            missing["memory_id"] = UUID().uuidString
            guard try await !invoke(missing, request: current) else { throw PersonalDataError.invalidArguments }
            guard try await !invoke(["action": "save", "text": "Неавторизованная запись"], request: current) else { throw PersonalDataError.invalidArguments }
            guard try await invoke(withoutQuote, request: current),
                  try personal.requireStore().getMemory(id: inserted[0])?.text == "Живёт в Москве",
                  try personal.requireStore().getMemory(id: inserted[1]) == unchanged,
                  personal.memoryCount == 30 else { throw PersonalDataError.invalidArguments }
            let refusal = "Теперь Москва, но не сохраняй это."
            try registerUserMessage(AssistantMessage(role: .user, text: refusal), scope: "update-smoke")
            guard try await !invoke(withoutQuote, request: refusal) else { throw PersonalDataError.invalidArguments }
            let merge = ["action": "merge", "memory_id": inserted[0].uuidString, "merge_with_id": inserted[1].uuidString, "text": "Живёт в Москве; сохранён факт 1."]
            guard try await !invoke(merge, request: refusal), personal.memoryCount == 30 else { throw PersonalDataError.invalidArguments }
            let removalRefusal = "Не удаляй ничего из памяти."
            try registerUserMessage(AssistantMessage(role: .user, text: removalRefusal), scope: "update-smoke")
            guard try await !invoke(merge, request: removalRefusal), personal.memoryCount == 30 else { throw PersonalDataError.invalidArguments }
            try registerUserMessage(AssistantMessage(role: .user, text: current), scope: "update-smoke")
            guard try await invoke(merge, request: current), personal.memoryCount == 29,
                  try personal.requireStore().getMemory(id: inserted[1]) == nil else { throw PersonalDataError.invalidArguments }
            inserted.remove(at: 1)
            let fill = try personal.saveMemory(text: "Заполненный слот")
            inserted.append(fill.id)
            let explicit = "Запомни, что я люблю велоспорт."
            try registerUserMessage(AssistantMessage(role: .user, text: explicit), scope: "update-smoke")
            guard try await invoke(["action": "save", "text": "Любит велоспорт"], request: explicit),
                  personal.memoryCount == 30, try personal.requireStore().getMemory(id: inserted[1]) == nil else { throw PersonalDataError.invalidArguments }
            if let created = try personal.requireStore().searchMemories("Любит велоспорт", limit: 1).first { inserted.append(created.id) }
            for id in inserted { try personal.deleteMemory(id: id) }
            inserted = []
            try "PASS full capacity grounded update; atomic merge and eviction; invalid, absent, stale, refused evidence and unrequested create rejected".write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            for id in inserted { try? personal.deleteMemory(id: id) }
            try? "FAIL \(error)".write(to: resultURL, atomically: true, encoding: .utf8)
        }
    }
}
#endif
