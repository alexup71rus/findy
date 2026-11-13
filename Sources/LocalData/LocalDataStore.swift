import Foundation
import SQLite3
#if canImport(AssistantCore)
import AssistantCore
#endif

/// One local timeline, independent of the currently selected provider. Context
/// queries use the caller's scope and reset boundary, while pagination stays global.
public final class LocalDataStore: @unchecked Sendable {
    public let databaseURL: URL
    private let lock = NSLock()
    private var database: OpaquePointer?
    private static let maximumPageSize = 200
    private static let messageColumns = "sequence, id, role, body, sources, created_at, scope"
    private static let memoryColumns = "id, body, created_at, updated_at"
    private static let reminderColumns = "id, title, due_at, created_at, updated_at, status"

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw LocalDataError.invalidValue("Для локальной базы нужен файловый URL.") }
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        // The app supplies an Application Support directory protected until the
        // first unlock. Adjacent SQLite/WAL/SHM files inherit that directory policy.
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let error = Self.databaseError(opened, code: result)
            if let opened { sqlite3_close_v2(opened) }
            throw error
        }
        database = opened
        do {
            try withDatabase { db in
                sqlite3_extended_result_codes(db, 1)
                sqlite3_busy_timeout(db, 5_000)
                let version = try Self.scalar(db, "PRAGMA user_version") ?? 0
                guard version <= 2 else { throw LocalDataError.unsupportedSchema(version) }
                let mode = try Self.rows(db, "PRAGMA journal_mode=WAL", read: { try Self.text($0, 0) }).first
                guard mode?.lowercased() == "wal" else {
                    throw LocalDataError.invalidValue("Не удалось включить WAL для локальной базы данных.")
                }
                try Self.execute(db, "PRAGMA synchronous=FULL")
                try Self.execute(db, "PRAGMA foreign_keys=ON")
                if version == 0 { try Self.migrate(db) }
                if version < 2 {
                    try Self.transaction(db) {
                        try Self.execute(db, "CREATE TABLE local_state(key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
                        try Self.execute(db, "PRAGMA user_version=2")
                    }
                }
                // Do not recreate or discard a database that claims an existing
                // schema but has missing/corrupt tables.
                _ = try Self.rows(db, "SELECT \(Self.messageColumns) FROM messages LIMIT 0", read: Self.readMessage)
                _ = try Self.rows(db, "SELECT \(Self.memoryColumns) FROM memories LIMIT 0", read: Self.readMemory)
                _ = try Self.rows(db, "SELECT \(Self.reminderColumns) FROM reminders LIMIT 0", read: Self.readReminder)
                _ = try Self.rows(db, "SELECT after_sequence FROM context_boundaries LIMIT 0", read: { sqlite3_column_int64($0, 0) })
                _ = try Self.rows(db, "SELECT key FROM local_state LIMIT 0", read: { try Self.text($0, 0) })
            }
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        lock.lock()
        if let database { sqlite3_close_v2(database) }
        lock.unlock()
    }

    /// Empty text is permitted to reserve a stable sequence before a late
    /// transcription arrives. Its first scope, sequence and creation date are immutable.
    @discardableResult
    public func upsertMessage(_ message: AssistantMessage, scope: String, createdAt: Date = Date()) throws -> StoredMessage {
        let scope = try Self.validScope(scope)
        try Self.validDate(createdAt)
        let sources = try JSONEncoder().encode(message.sources)
        return try withDatabase { db in
            try Self.transaction(db) {
                try Self.execute(db, """
                    INSERT INTO messages(id, role, body, sources, created_at, scope, has_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET role=excluded.role, body=excluded.body,
                        sources=excluded.sources, has_text=excluded.has_text
                    """, [
                        .text(message.id.uuidString.lowercased()), .text(message.role.rawValue), .text(message.text),
                        .blob(sources), .real(createdAt.timeIntervalSince1970), .text(scope),
                        .integer(message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                    ])
                guard let stored = try Self.message(db, id: message.id) else { throw LocalDataError.invalidStoredData("сообщение после записи") }
                return stored
            }
        }
    }

    public func latest(limit: Int = 50) throws -> [StoredMessage] {
        let limit = Self.pageLimit(limit)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            Array(try Self.rows(db, "SELECT \(Self.messageColumns) FROM messages ORDER BY sequence DESC LIMIT ?", [.integer(Int64(limit))], read: Self.readMessage).reversed())
        }
    }

    public func before(sequence: Int64, limit: Int = 50) throws -> [StoredMessage] {
        let limit = Self.pageLimit(limit)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            Array(try Self.rows(db, "SELECT \(Self.messageColumns) FROM messages WHERE sequence < ? ORDER BY sequence DESC LIMIT ?", [.integer(sequence), .integer(Int64(limit))], read: Self.readMessage).reversed())
        }
    }

    public func after(sequence: Int64, limit: Int = 50) throws -> [StoredMessage] {
        let limit = Self.pageLimit(limit)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            try Self.rows(db, "SELECT \(Self.messageColumns) FROM messages WHERE sequence > ? ORDER BY sequence ASC LIMIT ?", [.integer(sequence), .integer(Int64(limit))], read: Self.readMessage)
        }
    }

    public func recentContext(scope: String, after boundary: Int64? = nil, limit: Int = AssistantLimits.contextMessageDefault) throws -> [StoredMessage] {
        let scope = try Self.validScope(scope)
        let limit = Self.pageLimit(limit)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            let reset = try Self.scalar(db, "SELECT after_sequence FROM context_boundaries WHERE scope = ?", [.text(scope)]) ?? 0
            let cutoff = max(reset, boundary ?? 0)
            return Array(try Self.rows(db, """
                SELECT \(Self.messageColumns) FROM messages
                WHERE scope = ? AND has_text = 1 AND sequence > ? ORDER BY sequence DESC LIMIT ?
                """, [.text(scope), .integer(cutoff), .integer(Int64(limit))], read: Self.readMessage).reversed())
        }
    }

    public func getMessage(id: UUID) throws -> StoredMessage? {
        try withDatabase { try Self.message($0, id: id) }
    }

    /// Removes one message and invalidates pending tool authorizations derived
    /// from the old conversation, in the same transaction.
    public func deleteMessage(id: UUID) throws {
        try withDatabase { db in
            try Self.transaction(db) {
                try Self.execute(db, "DELETE FROM messages WHERE id = ?", [.text(id.uuidString.lowercased())])
                try Self.execute(db, "DELETE FROM local_state WHERE key = ?", [.text("image." + id.uuidString.lowercased())])
                try Self.execute(db, "DELETE FROM local_state WHERE key LIKE 'intent.%'")
            }
        }
    }

    public func totalCount() throws -> Int64 {
        try withDatabase { try Self.scalar($0, "SELECT COUNT(*) FROM messages") ?? 0 }
    }

    public func oldestCursor() throws -> Int64? {
        try withDatabase { try Self.scalar($0, "SELECT sequence FROM messages ORDER BY sequence ASC LIMIT 1") }
    }

    public func newestCursor() throws -> Int64? {
        try withDatabase { try Self.scalar($0, "SELECT sequence FROM messages ORDER BY sequence DESC LIMIT 1") }
    }

    /// Context resets do not remove messages from the visible timeline.
    @discardableResult
    public func resetContext(scope: String) throws -> Int64 {
        let scope = try Self.validScope(scope)
        return try withDatabase { db in
            try Self.transaction(db) {
                let maximum = try Self.scalar(db, "SELECT sequence FROM messages ORDER BY sequence DESC LIMIT 1") ?? 0
                try Self.execute(db, """
                    INSERT INTO context_boundaries(scope, after_sequence) VALUES (?, ?)
                    ON CONFLICT(scope) DO UPDATE SET after_sequence=MAX(context_boundaries.after_sequence, excluded.after_sequence)
                    """, [.text(scope), .integer(maximum)])
                return try Self.scalar(db, "SELECT after_sequence FROM context_boundaries WHERE scope = ?", [.text(scope)]) ?? maximum
            }
        }
    }

    /// Explicit user action only. Memories and reminders are separate records.
    public func clearHistory() throws {
        try withDatabase { db in
            try Self.transaction(db) {
                try Self.execute(db, "DELETE FROM messages")
                try Self.execute(db, "DELETE FROM context_boundaries")
                try Self.execute(db, "DELETE FROM local_state WHERE key NOT LIKE 'eventkit.%'")
            }
        }
    }

    public func localState(for key: String) throws -> Data? {
        guard !key.isEmpty, key.utf8.count <= 256 else { throw LocalDataError.invalidValue("Недопустимый ключ локального состояния.") }
        return try withDatabase { db in
            try Self.rows(db, "SELECT value FROM local_state WHERE key = ?", [.text(key)]) { statement in
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
                return Data(bytes: bytes, count: count)
            }.first
        }
    }

    public func setLocalState(_ value: Data?, for key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 256, (value?.count ?? 0) <= 32_768 else { throw LocalDataError.invalidValue("Недопустимое локальное состояние.") }
        try withDatabase { db in
            if let value {
                try Self.execute(db, "INSERT INTO local_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .blob(value)])
            } else { try Self.execute(db, "DELETE FROM local_state WHERE key = ?", [.text(key)]) }
        }
    }

    @discardableResult
    public func upsertMemory(_ fact: MemoryFact) throws -> MemoryFact {
        guard fact.text.count <= AssistantLimits.memoryNoteCharacters else {
            throw LocalDataError.invalidValue("Факт должен быть не длиннее \(AssistantLimits.memoryNoteCharacters) символов.")
        }
        let text = try Self.validText(fact.text, field: "Факт")
        let normalized = Self.normalized(text)
        try Self.validDate(fact.createdAt)
        try Self.validDate(fact.updatedAt)
        return try withDatabase { db in
            try Self.transaction(db) {
                if let duplicate = try Self.rows(db, "SELECT \(Self.memoryColumns) FROM memories WHERE normalized = ? LIMIT 1", [.text(normalized)], read: Self.readMemory).first,
                   duplicate.id != fact.id {
                    if try Self.memory(db, id: fact.id) != nil { throw LocalDataError.duplicateMemory }
                    return duplicate
                }
                // The count and insert share the write transaction. Separate
                // store instances cannot both claim the last available slot.
                // Legacy records are retained; edits never consume a slot.
                if try Self.memory(db, id: fact.id) == nil,
                   (try Self.scalar(db, "SELECT COUNT(*) FROM memories") ?? 0) >= Int64(AssistantLimits.memorySlots) {
                    throw LocalDataError.invalidValue("Память заполнена: лимит \(AssistantLimits.memorySlots) записей. Измените или удалите запись.")
                }
                try Self.execute(db, """
                    INSERT INTO memories(id, body, normalized, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET body=excluded.body, normalized=excluded.normalized, updated_at=excluded.updated_at
                    """, [.text(fact.id.uuidString.lowercased()), .text(text), .text(normalized), .real(fact.createdAt.timeIntervalSince1970), .real(fact.updatedAt.timeIntervalSince1970)])
                guard let stored = try Self.memory(db, id: fact.id) else { throw LocalDataError.invalidStoredData("факт после записи") }
                return stored
            }
        }
    }

    public func getMemory(id: UUID) throws -> MemoryFact? { try withDatabase { try Self.memory($0, id: id) } }

    public func memories(limit: Int = 200) throws -> [MemoryFact] { try searchMemories("", limit: limit) }

    public func memoryCount() throws -> Int {
        try withDatabase { Int(try Self.scalar($0, "SELECT COUNT(*) FROM memories") ?? 0) }
    }

    /// Full user-facing memory list, including records saved before the limits.
    /// Chat history remains paginated independently.
    public func allMemories() throws -> [MemoryFact] {
        try withDatabase { db in
            try Self.rows(db, "SELECT \(Self.memoryColumns) FROM memories ORDER BY updated_at DESC, id ASC", read: Self.readMemory)
        }
    }

    public func searchMemories(_ query: String, limit: Int = 200) throws -> [MemoryFact] {
        let limit = Self.pageLimit(limit)
        guard limit > 0 else { return [] }
        guard query.count <= 2_000 else { throw LocalDataError.invalidValue("Поисковый запрос должен быть не длиннее 2000 символов.") }
        let normalized = Self.normalized(query)
        return try withDatabase { db in
            try Self.rows(db, "SELECT \(Self.memoryColumns) FROM memories WHERE instr(normalized, ?) > 0 ORDER BY updated_at DESC, id ASC LIMIT ?", [.text(normalized), .integer(Int64(limit))], read: Self.readMemory)
        }
    }

    public func deleteMemory(id: UUID) throws {
        try withDatabase { try Self.execute($0, "DELETE FROM memories WHERE id = ?", [.text(id.uuidString.lowercased())]) }
    }

    @discardableResult
    public func upsertReminder(_ reminder: LocalReminder) throws -> LocalReminder {
        let title = try Self.validText(reminder.title, field: "Напоминание")
        try Self.validDate(reminder.dueAt)
        try Self.validDate(reminder.createdAt)
        try Self.validDate(reminder.updatedAt)
        return try withDatabase { db in
            try Self.transaction(db) {
                try Self.execute(db, """
                    INSERT INTO reminders(id, title, due_at, created_at, updated_at, status) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, due_at=excluded.due_at,
                        updated_at=excluded.updated_at, status=excluded.status
                    """, [.text(reminder.id.uuidString.lowercased()), .text(title), .real(reminder.dueAt.timeIntervalSince1970), .real(reminder.createdAt.timeIntervalSince1970), .real(reminder.updatedAt.timeIntervalSince1970), .text(reminder.status.rawValue)])
                guard let stored = try Self.reminder(db, id: reminder.id) else { throw LocalDataError.invalidStoredData("напоминание после записи") }
                return stored
            }
        }
    }

    public func getReminder(id: UUID) throws -> LocalReminder? { try withDatabase { try Self.reminder($0, id: id) } }

    public func reminders(status: LocalReminderStatus? = nil, limit: Int = 200) throws -> [LocalReminder] {
        let limit = min(max(0, limit), 10_000)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            if let status {
                return try Self.rows(db, "SELECT \(Self.reminderColumns) FROM reminders WHERE status = ? ORDER BY due_at ASC, id ASC LIMIT ?", [.text(status.rawValue), .integer(Int64(limit))], read: Self.readReminder)
            }
            return try Self.rows(db, "SELECT \(Self.reminderColumns) FROM reminders ORDER BY due_at ASC, id ASC LIMIT ?", [.integer(Int64(limit))], read: Self.readReminder)
        }
    }

    public func reminders(dueBefore: Date, status: LocalReminderStatus = .scheduled, limit: Int = 200) throws -> [LocalReminder] {
        try Self.validDate(dueBefore)
        let limit = min(max(0, limit), 10_000)
        guard limit > 0 else { return [] }
        return try withDatabase { db in
            try Self.rows(db, "SELECT \(Self.reminderColumns) FROM reminders WHERE status = ? AND due_at <= ? ORDER BY due_at ASC, id ASC LIMIT ?", [.text(status.rawValue), .real(dueBefore.timeIntervalSince1970), .integer(Int64(limit))], read: Self.readReminder)
        }
    }

    public func deleteReminder(id: UUID) throws {
        try withDatabase { try Self.execute($0, "DELETE FROM reminders WHERE id = ?", [.text(id.uuidString.lowercased())]) }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LocalDataError.invalidStoredData("база данных закрыта") }
        return try body(database)
    }

    private static func migrate(_ db: OpaquePointer) throws {
        try transaction(db) {
            try execute(db, """
                CREATE TABLE messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
                    body TEXT NOT NULL,
                    sources BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    scope TEXT NOT NULL,
                    has_text INTEGER NOT NULL CHECK(has_text IN (0, 1))
                );
                CREATE INDEX messages_scope_sequence ON messages(scope, has_text, sequence);
                CREATE TABLE context_boundaries(scope TEXT PRIMARY KEY NOT NULL, after_sequence INTEGER NOT NULL);
                CREATE TABLE memories (
                    id TEXT PRIMARY KEY NOT NULL, body TEXT NOT NULL, normalized TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                CREATE INDEX memories_updated ON memories(updated_at DESC, id);
                CREATE TABLE reminders (
                    id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, due_at REAL NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('scheduled', 'blocked', 'completed'))
                );
                CREATE INDEX reminders_status_due ON reminders(status, due_at, id);
                CREATE INDEX reminders_due ON reminders(due_at, id);
                PRAGMA user_version=1;
                """)
        }
    }

    private enum Binding {
        case text(String), blob(Data), real(Double), integer(Int64)
    }

    private static func statement<T>(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw databaseError(db, code: prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
            case .blob(let data):
                if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else { result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            }
            guard result == SQLITE_OK else { throw databaseError(db, code: result) }
        }
        return try body(statement)
    }

    private static func execute(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws {
        if bindings.isEmpty {
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            guard result == SQLITE_OK else { throw databaseError(db, code: result) }
        } else {
            try statement(db, sql, bindings) { prepared in
                let result = sqlite3_step(prepared)
                guard result == SQLITE_DONE else { throw databaseError(db, code: result) }
            }
        }
    }

    private static func rows<T>(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = [], read: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(db, sql, bindings) { prepared in
            var result: [T] = []
            while true {
                let status = sqlite3_step(prepared)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw databaseError(db, code: status) }
                result.append(try read(prepared))
            }
        }
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws -> Int64? {
        try rows(db, sql, bindings, read: { sqlite3_column_int64($0, 0) }).first
    }

    private static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute(db, "COMMIT")
            return value
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private static func message(_ db: OpaquePointer, id: UUID) throws -> StoredMessage? {
        try rows(db, "SELECT \(messageColumns) FROM messages WHERE id = ? LIMIT 1", [.text(id.uuidString.lowercased())], read: readMessage).first
    }

    private static func memory(_ db: OpaquePointer, id: UUID) throws -> MemoryFact? {
        try rows(db, "SELECT \(memoryColumns) FROM memories WHERE id = ? LIMIT 1", [.text(id.uuidString.lowercased())], read: readMemory).first
    }

    private static func reminder(_ db: OpaquePointer, id: UUID) throws -> LocalReminder? {
        try rows(db, "SELECT \(reminderColumns) FROM reminders WHERE id = ? LIMIT 1", [.text(id.uuidString.lowercased())], read: readReminder).first
    }

    private static func readMessage(_ statement: OpaquePointer) throws -> StoredMessage {
        let id = try identifier(statement, 1)
        guard let role = AssistantMessage.Role(rawValue: try text(statement, 2)) else { throw LocalDataError.invalidStoredData("роль сообщения") }
        let sources: [AssistantSource]
        do { sources = try JSONDecoder().decode([AssistantSource].self, from: blob(statement, 4)) }
        catch { throw LocalDataError.invalidStoredData("источники сообщения") }
        return StoredMessage(
            message: AssistantMessage(id: id, role: role, text: try text(statement, 3), sources: sources),
            sequence: sqlite3_column_int64(statement, 0), createdAt: try date(statement, 5), scope: try text(statement, 6)
        )
    }

    private static func readMemory(_ statement: OpaquePointer) throws -> MemoryFact {
        MemoryFact(id: try identifier(statement, 0), text: try text(statement, 1), createdAt: try date(statement, 2), updatedAt: try date(statement, 3))
    }

    private static func readReminder(_ statement: OpaquePointer) throws -> LocalReminder {
        guard let status = LocalReminderStatus(rawValue: try text(statement, 5)) else { throw LocalDataError.invalidStoredData("статус напоминания") }
        return LocalReminder(id: try identifier(statement, 0), title: try text(statement, 1), dueAt: try date(statement, 2), createdAt: try date(statement, 3), updatedAt: try date(statement, 4), status: status)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else {
            throw LocalDataError.invalidStoredData("текстовое поле")
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        guard let string = String(bytes: bytes, encoding: .utf8) else { throw LocalDataError.invalidStoredData("кодировка текста") }
        return string
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { throw LocalDataError.invalidStoredData("данные источников") }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else { throw LocalDataError.invalidStoredData("данные источников") }
        return Data(bytes: pointer, count: count)
    }

    private static func identifier(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let id = UUID(uuidString: try text(statement, column)) else { throw LocalDataError.invalidStoredData("идентификатор записи") }
        return id
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) throws -> Date {
        guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, column)) else { throw LocalDataError.invalidStoredData("дата") }
        let value = sqlite3_column_double(statement, column)
        guard value.isFinite else { throw LocalDataError.invalidStoredData("дата") }
        return Date(timeIntervalSince1970: value)
    }

    private static func pageLimit(_ limit: Int) -> Int { min(max(0, limit), maximumPageSize) }

    private static func validScope(_ scope: String) throws -> String {
        let value = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096 else { throw LocalDataError.invalidValue("Не задан контекст подключения.") }
        return value
    }

    private static func validText(_ text: String, field: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LocalDataError.invalidValue("\(field) не может быть пустым.") }
        guard value.count <= 2_000 else { throw LocalDataError.invalidValue("\(field) должен быть не длиннее 2000 символов.") }
        return value
    }

    private static func validDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw LocalDataError.invalidValue("Указана некорректная дата.") }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased(with: Locale(identifier: "ru_RU"))
    }

    private static func databaseError(_ db: OpaquePointer?, code: Int32) -> LocalDataError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Не удалось открыть базу данных."
        return .sqlite(code: code, message: message)
    }
}
