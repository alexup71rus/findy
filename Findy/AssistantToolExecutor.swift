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
        let query: String?
        let title: String?
        let due_at: String?
        let reminder_id: String?
        let advance: String?
    }

    private struct Output: Encodable {
        var ok: Bool
        var message: String?
        var memory: MemoryFact?
        var memories: [MemoryFact]?
        var reminder: LocalReminder?
        var reminders: [LocalReminder]?
        var localTime: String?
        var timeZone: String?
        var deviceModel: String?
        var systemVersion: String?
        var weekday: String?
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
            let fact = try personal.saveMemory(text: text, replacing: id)
            try completed(.saveMemory, scope: scope)
            SessionLog.shared.record("personal.memory.saved", "count=\(personal.memoryCount)")
            return Output(ok: true, memory: fact)
        case "remove":
            _ = try authorized(.removeMemory, request: userRequest, scope: scope)
            guard let id = try optionalID(arguments.memory_id), try store.getMemory(id: id) != nil else { throw PersonalDataError.notFound }
            try personal.deleteMemory(id: id)
            try completed(.removeMemory, scope: scope)
            SessionLog.shared.record("personal.memory.removed", "count=\(personal.memoryCount)")
            return Output(ok: true, message: "Сведение удалено из долговременной памяти.")
        case "search":
            let matches = try store.searchMemories(arguments.query ?? "", limit: AssistantLimits.memorySlots)
            let hasClippedNotes = matches.contains { $0.text.count > AssistantLimits.memoryNoteCharacters }
            let snapshots = matches.map { fact in
                var snapshot = fact
                snapshot.text = AssistantLimits.clipped(fact.text, to: AssistantLimits.memoryNoteCharacters)
                return snapshot
            }
            return Output(ok: true, message: hasClippedNotes ? "Показаны первые \(AssistantLimits.memoryNoteCharacters) символов длинных старых записей. Полный текст сохранён в памяти приложения." : nil, memories: snapshots)
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
                .filter { $0.status != .completed && $0.dueAt > Date() }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .autoupdatingCurrent
            return Output(ok: true, reminders: Array(records.prefix(40)), localTime: formatter.string(from: Date()), timeZone: TimeZone.autoupdatingCurrent.identifier)
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
