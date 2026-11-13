import Foundation
import SQLite3
import XCTest
import AssistantCore
import LocalData

final class LocalStateTests: XCTestCase, @unchecked Sendable {
    func testDeletingMessageRemovesOnlyItsImageMetadata() throws {
        try withStore { store, _ in
            let message = AssistantMessage(role: .assistant, text: "Изображение готово.")
            let key = "image." + message.id.uuidString.lowercased()
            try store.upsertMessage(message, scope: "test")
            try store.setLocalState(Data("image.png".utf8), for: key)
            try store.setLocalState(Data("other".utf8), for: "image.other")
            try store.deleteMessage(id: message.id)
            XCTAssertNil(try store.getMessage(id: message.id))
            XCTAssertNil(try store.localState(for: key))
            XCTAssertEqual(try store.localState(for: "image.other"), Data("other".utf8))
        }
    }

    func testBinaryStateRoundTripsEmbeddedNULsAndDistinguishesKeysExactly() throws {
        try withStore { store, _ in
            let value = Data([0, 1, 0, 255, 42, 0])
            let key = "intent.\0scope"
            try store.setLocalState(value, for: key)
            XCTAssertEqual(try store.localState(for: key), value)
            XCTAssertNil(try store.localState(for: "intent."))
            XCTAssertNil(try store.localState(for: "INTENT.\0scope"))
            let other = Data("Другое состояние 👋".utf8)
            try store.setLocalState(other, for: "intent.other")
            try store.setLocalState(nil, for: key)
            XCTAssertNil(try store.localState(for: key))
            XCTAssertEqual(try store.localState(for: "intent.other"), other)
        }
    }

    func testEmptyBLOBIsAStoredValueWhileNilDeletesIt() throws {
        try withStore { store, url in
            try store.setLocalState(Data(), for: "empty")
            XCTAssertEqual(try store.localState(for: "empty"), Data())
            XCTAssertEqual(try LocalDataStore(databaseURL: url).localState(for: "empty"), Data())
            try store.setLocalState(nil, for: "empty")
            XCTAssertNil(try store.localState(for: "empty"))
        }
    }

    func testStateSizeAndUTF8KeyBoundariesDoNotDamageExistingValues() throws {
        try withStore { store, _ in
            let maximum = Data(repeating: 7, count: 32_768)
            let maximumKey = String(repeating: "я", count: 128) // 256 UTF-8 bytes
            try store.setLocalState(maximum, for: maximumKey)
            XCTAssertEqual(try store.localState(for: maximumKey), maximum)
            XCTAssertThrowsError(try store.setLocalState(Data(repeating: 8, count: 32_769), for: maximumKey))
            XCTAssertEqual(try store.localState(for: maximumKey), maximum)
            for key in ["", String(repeating: "я", count: 129)] {
                XCTAssertThrowsError(try store.setLocalState(Data([1]), for: key))
                XCTAssertThrowsError(try store.localState(for: key))
            }
            XCTAssertEqual(try store.localState(for: maximumKey), maximum)
        }
    }

    func testPendingStateSurvivesARealCloseAndReopen() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let saved = Data("Pending explicit reminder\0with binary suffix".utf8)
        var store: LocalDataStore? = try LocalDataStore(databaseURL: url)
        try store?.setLocalState(saved, for: "intent.provider")
        store = nil
        let reopened = try LocalDataStore(databaseURL: url)
        XCTAssertEqual(try reopened.localState(for: "intent.provider"), saved)
        let updated = Data([9, 0, 8])
        try reopened.setLocalState(updated, for: "intent.provider")
        XCTAssertEqual(try reopened.localState(for: "intent.provider"), updated)
    }

    func testClearHistoryClearsPendingStateAndBoundariesButKeepsPersonalData() throws {
        try withStore { store, url in
            _ = try store.upsertMessage(AssistantMessage(role: .user, text: "Прежний вопрос"), scope: "provider")
            _ = try store.resetContext(scope: "provider")
            let fact = try store.upsertMemory(MemoryFact(text: "Люблю чай"))
            let reminder = try store.upsertReminder(LocalReminder(title: "Магазин", dueAt: Date(timeIntervalSince1970: 2_000_000_000)))
            try store.setLocalState(Data("pending".utf8), for: "intent.provider")
            try store.clearHistory()
            let reopened = try LocalDataStore(databaseURL: url)
            XCTAssertEqual(try reopened.totalCount(), 0)
            XCTAssertNil(try reopened.localState(for: "intent.provider"))
            XCTAssertEqual(try reopened.getMemory(id: fact.id), fact)
            XCTAssertEqual(try reopened.getReminder(id: reminder.id), reminder)
            let next = try reopened.upsertMessage(AssistantMessage(role: .user, text: "Новый вопрос"), scope: "provider")
            XCTAssertEqual(try reopened.recentContext(scope: "provider").map(\.id), [next.id])
        }
    }

    func testVersionOneDatabaseMigratesWithoutLosingHistoryMemoryRemindersOrContextBoundary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "migration.sqlite")
        var store: LocalDataStore? = try LocalDataStore(databaseURL: url)
        let original = try XCTUnwrap(store).upsertMessage(AssistantMessage(role: .user, text: "До сброса"), scope: "provider")
        _ = try store?.resetContext(scope: "provider")
        let current = try XCTUnwrap(store).upsertMessage(AssistantMessage(role: .user, text: "После сброса"), scope: "provider")
        let fact = try XCTUnwrap(store).upsertMemory(MemoryFact(text: "Существовавшее предпочтение"))
        let reminder = try XCTUnwrap(store).upsertReminder(LocalReminder(title: "Существовавшее напоминание", dueAt: Date(timeIntervalSince1970: 2_000_000_000)))
        store = nil
        // Schema 1 had the same three user tables and context boundaries, but
        // did not have durable pending intent state.
        try fixtureSQL(url, "DROP TABLE local_state; PRAGMA user_version=1;")
        let upgraded = try LocalDataStore(databaseURL: url)
        XCTAssertEqual(try upgraded.totalCount(), 2)
        XCTAssertEqual(try upgraded.getMessage(id: original.id), original)
        XCTAssertEqual(try upgraded.getMessage(id: current.id), current)
        XCTAssertEqual(try upgraded.recentContext(scope: "provider").map(\.id), [current.id])
        XCTAssertEqual(try upgraded.getMemory(id: fact.id), fact)
        XCTAssertEqual(try upgraded.getReminder(id: reminder.id), reminder)
        XCTAssertNil(try upgraded.localState(for: "new-state"))
        let pending = Data([0, 42, 255])
        try upgraded.setLocalState(pending, for: "new-state")
        XCTAssertEqual(try LocalDataStore(databaseURL: url).localState(for: "new-state"), pending)
        XCTAssertEqual(try scalarSQL(url, "PRAGMA user_version"), 2)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Findy.LocalStateTest.\(UUID().uuidString)")
    }

    private func withStore(_ body: (LocalDataStore, URL) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        try body(LocalDataStore(databaseURL: url), url)
    }

    private func fixtureSQL(_ url: URL, _ sql: String) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database = opened else { throw LocalStateFixtureError(code: result) }
        defer { sqlite3_close_v2(database) }
        let executed = sqlite3_exec(database, sql, nil, nil, nil)
        guard executed == SQLITE_OK else { throw LocalStateFixtureError(code: executed) }
    }

    private func scalarSQL(_ url: URL, _ sql: String) throws -> Int64 {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database = opened else { throw LocalStateFixtureError(code: result) }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw LocalStateFixtureError(code: prepared) }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else { throw LocalStateFixtureError(code: stepped) }
        return sqlite3_column_int64(statement, 0)
    }
}

private struct LocalStateFixtureError: Error { let code: Int32 }
