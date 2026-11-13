import Foundation
#if canImport(AssistantCore)
import AssistantCore
#endif

public struct StoredMessage: Identifiable, Equatable, Sendable {
    public var id: UUID { message.id }
    public let message: AssistantMessage
    public let sequence: Int64
    public let createdAt: Date
    public let scope: String

    public init(message: AssistantMessage, sequence: Int64, createdAt: Date, scope: String) {
        self.message = message
        self.sequence = sequence
        self.createdAt = createdAt
        self.scope = scope
    }
}

public struct StoredMediaState: Sendable {
    public let key: String
    public let value: Data
    public let messageID: UUID
    public let createdAt: Date
    public init(key: String, value: Data, messageID: UUID, createdAt: Date) {
        self.key = key; self.value = value; self.messageID = messageID; self.createdAt = createdAt
    }
}

public struct MemoryFact: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum LocalReminderStatus: String, Codable, CaseIterable, Sendable {
    case scheduled, blocked, completed
}

public struct LocalReminder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var dueAt: Date
    public let createdAt: Date
    public var updatedAt: Date
    public var status: LocalReminderStatus
    public var notificationIdentifier: String { id.uuidString }

    public init(
        id: UUID = UUID(), title: String, dueAt: Date,
        createdAt: Date = Date(), updatedAt: Date = Date(), status: LocalReminderStatus = .scheduled
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }
}

public enum LocalDataError: Error, LocalizedError, Equatable, Sendable {
    case invalidValue(String)
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int64)
    case invalidStoredData(String)
    case duplicateMemory

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let description): return description
        case .sqlite(let code, let message): return "Ошибка локальной базы данных (\(code)): \(message)"
        case .unsupportedSchema(let version): return "База данных создана более новой версией приложения (схема \(version))."
        case .invalidStoredData(let field): return "Не удалось прочитать локальные данные: \(field)."
        case .duplicateMemory: return "Такой факт уже сохранён."
        }
    }
}
