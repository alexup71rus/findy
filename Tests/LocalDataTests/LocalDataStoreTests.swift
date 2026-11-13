import XCTest
import Foundation
import SQLite3
import AssistantCore
import LocalData

final class LocalDataStoreTests: XCTestCase, @unchecked Sendable {
    func testDeletingMessageRemovesItFromContextPreservesOtherDataAndInvalidatesIntents() throws {
        try withStore { store, url in
            let first = try store.upsertMessage(AssistantMessage(role: .user, text: "Первое"), scope: "conversation")
            let wrong = try store.upsertMessage(AssistantMessage(role: .assistant, text: "Неверная тема"), scope: "conversation")
            let last = try store.upsertMessage(AssistantMessage(role: .user, text: "Последнее"), scope: "conversation")
            let fact = try store.upsertMemory(MemoryFact(text: "Факт"))
            let reminder = try store.upsertReminder(LocalReminder(title: "Напоминание", dueAt: Date(timeIntervalSince1970: 500)))
            try store.setLocalState(Data("pending".utf8), for: "intent.conversation")
            try store.setLocalState(Data("keep".utf8), for: "unrelated")
            try store.deleteMessage(id: wrong.id)
            let reopened = try LocalDataStore(databaseURL: url)
            XCTAssertNil(try reopened.getMessage(id: wrong.id))
            XCTAssertEqual(try reopened.recentContext(scope: "conversation").map(\.id), [first.id, last.id])
            XCTAssertEqual(try reopened.latest().map(\.id), [first.id, last.id])
            XCTAssertEqual(try reopened.totalCount(), 2)
            XCTAssertNil(try reopened.localState(for: "intent.conversation"))
            XCTAssertEqual(try reopened.localState(for: "unrelated"), Data("keep".utf8))
            XCTAssertEqual(try reopened.getMemory(id: fact.id), fact)
            XCTAssertEqual(try reopened.getReminder(id: reminder.id), reminder)
            try reopened.deleteMessage(id: first.id)
            XCTAssertEqual(try reopened.oldestCursor(), last.sequence)
            try reopened.deleteMessage(id: last.id)
            XCTAssertNil(try reopened.newestCursor())
        }
    }

    func testMessageDeletionRollsBackIfIntentInvalidationFails() throws {
        try withStore { store, url in
            let item = try store.upsertMessage(AssistantMessage(role: .user, text: "Останется"), scope: "conversation")
            try store.setLocalState(Data("pending".utf8), for: "intent.conversation")
            try fixtureSQL(url, "CREATE TRIGGER reject_intent_delete BEFORE DELETE ON local_state BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END;")
            XCTAssertThrowsError(try store.deleteMessage(id: item.id))
            XCTAssertEqual(try store.getMessage(id: item.id), item)
            XCTAssertEqual(try store.localState(for: "intent.conversation"), Data("pending".utf8))
        }
    }
    func testKeysetPaginationOverTwelveHundredMessagesHasStableOrderAndNoDuplicates() throws {
        try withStore { store, _ in
            var inserted: [StoredMessage] = []
            for index in 0..<1_205 {
                inserted.append(try store.upsertMessage(
                    AssistantMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Сообщение \(index)"),
                    scope: "provider-\(index % 3)", createdAt: Date(timeIntervalSince1970: Double(index))
                ))
            }
            XCTAssertEqual(try store.totalCount(), 1_205)
            XCTAssertEqual(try store.oldestCursor(), inserted.first?.sequence)
            XCTAssertEqual(try store.newestCursor(), inserted.last?.sequence)
            XCTAssertEqual(try store.latest(limit: 10_000).count, 200)
            XCTAssertTrue(try store.latest(limit: 0).isEmpty)
            XCTAssertTrue(try store.before(sequence: Int64.max, limit: -1).isEmpty)

            var page = try store.latest(limit: 97)
            var backward = page
            while let first = page.first {
                page = try store.before(sequence: first.sequence, limit: 97)
                backward.insert(contentsOf: page, at: 0)
            }
            XCTAssertEqual(backward.map(\.id), inserted.map(\.id))
            XCTAssertEqual(Set(backward.map(\.id)).count, inserted.count)
            XCTAssertEqual(backward.map(\.sequence), backward.map(\.sequence).sorted())

            var forward: [StoredMessage] = []
            var cursor: Int64 = 0
            while true {
                let next = try store.after(sequence: cursor, limit: 113)
                guard let last = next.last else { break }
                forward.append(contentsOf: next)
                cursor = last.sequence
            }
            XCTAssertEqual(forward, inserted)
            let expectedContext = inserted.filter { $0.scope == "provider-1" }.suffix(AssistantLimits.contextMessageDefault)
            XCTAssertEqual(try store.recentContext(scope: "provider-1"), Array(expectedContext))
        }
    }

    func testLateTranscriptUpsertsPreserveReservedOrderCreationDateAndScope() throws {
        try withStore { store, _ in
            let userID = UUID()
            let answerID = UUID()
            let created = Date(timeIntervalSince1970: 100)
            let user = try store.upsertMessage(AssistantMessage(id: userID, role: .user, text: ""), scope: "first", createdAt: created)
            let answer = try store.upsertMessage(AssistantMessage(id: answerID, role: .assistant, text: ""), scope: "first", createdAt: created.addingTimeInterval(1))
            XCTAssertTrue(try store.recentContext(scope: "first").isEmpty)
            let source = AssistantSource(title: "Источник", url: URL(string: "https://example.com/источник")!)
            let answerFilled = try store.upsertMessage(
                AssistantMessage(id: answerID, role: .assistant, text: "Ответ 👋", sources: [source]),
                scope: "second", createdAt: Date(timeIntervalSince1970: 900)
            )
            let userFilled = try store.upsertMessage(
                AssistantMessage(id: userID, role: .user, text: "Вопрос"), scope: "first", createdAt: Date(timeIntervalSince1970: 800)
            )
            XCTAssertEqual(userFilled.sequence, user.sequence)
            XCTAssertEqual(userFilled.createdAt, user.createdAt)
            XCTAssertEqual(answerFilled.sequence, answer.sequence)
            XCTAssertEqual(answerFilled.createdAt, answer.createdAt)
            XCTAssertEqual(answerFilled.scope, "first")
            XCTAssertEqual(answerFilled.message.sources, [source])
            XCTAssertEqual(try store.latest().map(\.message.text), ["Вопрос", "Ответ 👋"])
            XCTAssertEqual(try store.recentContext(scope: "first").map(\.id), [userID, answerID])
            XCTAssertTrue(try store.recentContext(scope: "second").isEmpty)
            XCTAssertEqual(try store.totalCount(), 2)
        }
    }

    func testContextResetIsPerScopeAndDoesNotDeleteTheTimelineOrAdmitLateOldTranscripts() throws {
        try withStore { store, url in
            let first = try store.upsertMessage(AssistantMessage(role: .user, text: "Старое A"), scope: "A")
            let other = try store.upsertMessage(AssistantMessage(role: .user, text: "Старое B"), scope: "B")
            _ = try store.upsertMessage(AssistantMessage(role: .assistant, text: " \n\t\u{00A0}"), scope: "A")
            let boundary = try store.resetContext(scope: "A")
            XCTAssertEqual(boundary, try store.newestCursor())
            XCTAssertTrue(try store.recentContext(scope: "A").isEmpty)
            XCTAssertEqual(try store.recentContext(scope: "B").map(\.id), [other.id])
            XCTAssertEqual(try store.latest().count, 3)
            _ = try store.upsertMessage(AssistantMessage(id: first.id, role: .user, text: "Поздняя расшифровка старого A"), scope: "A")
            XCTAssertTrue(try store.recentContext(scope: "A").isEmpty)
            let next = try store.upsertMessage(AssistantMessage(role: .user, text: "Новое A"), scope: "A")
            XCTAssertEqual(try store.recentContext(scope: "A").map(\.id), [next.id])
            XCTAssertTrue(try store.recentContext(scope: "A", after: next.sequence).isEmpty)
            let reopened = try LocalDataStore(databaseURL: url)
            XCTAssertEqual(try reopened.recentContext(scope: "A").map(\.id), [next.id])
            XCTAssertEqual(try reopened.totalCount(), 4)
        }
    }

    func testSQLiteWriteFailureAndInvalidSourcesLeaveExistingMessageUnchanged() throws {
        try withStore { store, url in
            let original = try store.upsertMessage(AssistantMessage(role: .user, text: "Не терять"), scope: "A", createdAt: Date(timeIntervalSince1970: 10))
            try fixtureSQL(url, "CREATE TRIGGER reject_message_update BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END;")
            XCTAssertThrowsError(try store.upsertMessage(AssistantMessage(id: original.id, role: .assistant, text: "Не сохранять"), scope: "A"))
            XCTAssertEqual(try store.getMessage(id: original.id), original)
            try fixtureSQL(url, "DROP TRIGGER reject_message_update")
            let unsafe = AssistantSource(title: "Invalid", url: URL(fileURLWithPath: "/fixture/private.txt"))
            XCTAssertThrowsError(try store.upsertMessage(AssistantMessage(id: original.id, role: .assistant, text: "Also not saved", sources: [unsafe]), scope: "A"))
            XCTAssertEqual(try store.getMessage(id: original.id), original)
            XCTAssertEqual(try LocalDataStore(databaseURL: url).getMessage(id: original.id), original)
            XCTAssertEqual(try store.totalCount(), 1)
        }
    }

    func testHistoryReopensAndClearHistoryLeavesMemoriesAndRemindersAlone() throws {
        try withStore { store, url in
            let stored = try store.upsertMessage(AssistantMessage(role: .user, text: "Текст\0после нуля"), scope: "provider")
            let fact = try store.upsertMemory(MemoryFact(text: "Люблю чай"))
            let reminder = try store.upsertReminder(LocalReminder(title: "Проверка", dueAt: Date(timeIntervalSince1970: 500)))
            try store.setLocalState(Data("event-id".utf8), for: "eventkit." + reminder.id.uuidString)
            try store.setLocalState(Data("intent".utf8), for: "intent.test")
            let reopened = try LocalDataStore(databaseURL: url)
            XCTAssertEqual(try reopened.getMessage(id: stored.id), stored)
            XCTAssertEqual(try reopened.getMessage(id: UUID()), nil)
            try reopened.clearHistory()
            XCTAssertEqual(try store.totalCount(), 0)
            XCTAssertNil(try store.oldestCursor())
            XCTAssertNil(try store.newestCursor())
            XCTAssertEqual(try store.getMemory(id: fact.id), fact)
            XCTAssertEqual(try store.getReminder(id: reminder.id), reminder)
            XCTAssertEqual(try store.localState(for: "eventkit." + reminder.id.uuidString), Data("event-id".utf8))
            XCTAssertNil(try store.localState(for: "intent.test"))
            let next = try store.upsertMessage(AssistantMessage(role: .user, text: "После очистки"), scope: "provider")
            XCTAssertGreaterThan(next.sequence, stored.sequence)
        }
    }

    func testMemoryCRUDDeduplicatesUnicodeAndSearchesRussianWithoutASCIIOnlyCollation() throws {
        try withStore { store, url in
            let original = try store.upsertMemory(MemoryFact(text: "Люблю йогу и кофе ☕️", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)))
            let duplicate = try store.upsertMemory(MemoryFact(text: "  ЛЮБЛЮ   и\u{0306}ОГУ И кофе ☕️ \n"))
            XCTAssertEqual(duplicate.id, original.id)
            XCTAssertEqual(try store.memories().count, 1)
            XCTAssertEqual(try store.searchMemories("ЙОГУ").map(\.id), [original.id])
            XCTAssertEqual(try store.searchMemories("КОФЕ").map(\.id), [original.id])
            let edited = try store.upsertMemory(MemoryFact(id: original.id, text: "Вечерний бег", createdAt: Date(timeIntervalSince1970: 999), updatedAt: Date(timeIntervalSince1970: 20)))
            XCTAssertEqual(edited.createdAt, original.createdAt)
            XCTAssertEqual(edited.updatedAt, Date(timeIntervalSince1970: 20))
            XCTAssertTrue(try store.searchMemories("йогу").isEmpty)
            XCTAssertEqual(try store.searchMemories("БЕГ"), [edited])
            XCTAssertEqual(try LocalDataStore(databaseURL: url).getMemory(id: original.id), edited)
            try store.deleteMemory(id: original.id)
            XCTAssertNil(try store.getMemory(id: original.id))
            XCTAssertTrue(try store.memories().isEmpty)
        }
    }

    func testMemoryValidationAndDuplicateEditAreAtomic() throws {
        try withStore { store, _ in
            let first = try store.upsertMemory(MemoryFact(text: "Первый факт"))
            let second = try store.upsertMemory(MemoryFact(text: "Второй факт"))
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(text: " \n\t")))
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(text: String(repeating: "я", count: 501))))
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(id: first.id, text: "ВТОРОЙ ФАКТ")))
            XCTAssertEqual(try store.getMemory(id: first.id), first)
            XCTAssertEqual(try store.getMemory(id: second.id), second)
            let maximum = try store.upsertMemory(MemoryFact(text: String(repeating: "я", count: 500)))
            XCTAssertEqual(maximum.text.count, 500)
            XCTAssertEqual(try store.memories().count, 3)
        }
    }

    func testMemoryCapacityAllowsDeduplicationEditingAndReplacementAfterDeletion() throws {
        try withStore { store, _ in
            let records = try (0..<AssistantLimits.memorySlots).map { try store.upsertMemory(MemoryFact(text: "Факт \($0)")) }
            XCTAssertEqual(try store.memoryCount(), 15)
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(text: "Шестнадцатый факт")))
            XCTAssertEqual(try store.memoryCount(), 15)
            XCTAssertEqual(try store.upsertMemory(MemoryFact(text: "  ФАКТ 0 ")).id, records[0].id)
            var edited = records[0]
            edited.text = "Изменённый факт"
            XCTAssertEqual(try store.upsertMemory(edited).text, edited.text)
            try store.deleteMemory(id: records[1].id)
            let replacement = try store.upsertMemory(MemoryFact(text: "Новое сведение"))
            XCTAssertEqual(try store.getMemory(id: replacement.id), replacement)
            XCTAssertEqual(try store.memoryCount(), 15)
        }
    }

    func testMemoryLimitCountsUnicodeCharactersWithoutSilentlyClipping() throws {
        try withStore { store, url in
            let text = String(repeating: "👩‍💻", count: AssistantLimits.memoryNoteCharacters)
            let record = try store.upsertMemory(MemoryFact(text: text))
            XCTAssertEqual(record.text, text)
            var edited = record
            edited.text += "я"
            XCTAssertThrowsError(try store.upsertMemory(edited))
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(text: String(repeating: "е\u{0301}", count: 501))))
            XCTAssertEqual(try store.getMemory(id: record.id), record)
            XCTAssertEqual(try LocalDataStore(databaseURL: url).getMemory(id: record.id), record)
            XCTAssertEqual(try store.memoryCount(), 1)
        }
    }

    func testLegacyMemoryRecordsReopenWithoutLossBeyondBothNewLimitsAndPageSize() throws {
        try withStore { store, url in
            let id = UUID()
            let legacyText = String(repeating: "я", count: 751)
            let statements = (0..<205).map { index in
                let recordID = index == 0 ? id : UUID()
                let body = index == 0 ? legacyText : "Старая запись \(index)"
                return "INSERT INTO memories(id, body, normalized, created_at, updated_at) VALUES ('\(recordID.uuidString.lowercased())', '\(body)', 'legacy-\(index)', 1, 2);"
            }.joined(separator: "\n")
            try fixtureSQL(url, statements)
            let reopened = try LocalDataStore(databaseURL: url)
            XCTAssertEqual(try reopened.memoryCount(), 205)
            XCTAssertEqual(try reopened.memories().count, 200)
            XCTAssertEqual(try reopened.allMemories().count, 205)
            XCTAssertEqual(try reopened.getMemory(id: id)?.text, legacyText)
            XCTAssertEqual(try reopened.searchMemories("legacy-0").first?.text, legacyText)
            XCTAssertThrowsError(try reopened.upsertMemory(MemoryFact(text: "Новый факт")))
            var edited = try XCTUnwrap(reopened.getMemory(id: id))
            XCTAssertThrowsError(try reopened.upsertMemory(edited))
            edited.text = "Сокращённая запись"
            XCTAssertEqual(try reopened.upsertMemory(edited).text, edited.text)
            try reopened.deleteMemory(id: id)
            XCTAssertEqual(try reopened.memoryCount(), 204)
            XCTAssertThrowsError(try reopened.upsertMemory(MemoryFact(text: "Всё ещё нет свободного места")))
            XCTAssertEqual(try store.memoryCount(), 204)
        }
    }

    func testFailedMemoryWriteDoesNotConsumeSlotOrAlterExistingNote() throws {
        try withStore { store, url in
            let original = try store.upsertMemory(MemoryFact(text: "Сохранённый факт"))
            try fixtureSQL(url, "CREATE TRIGGER reject_memory_insert BEFORE INSERT ON memories BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END;")
            XCTAssertThrowsError(try store.upsertMemory(MemoryFact(text: "Не сохранять")))
            var edited = original
            edited.text = "Не изменять"
            XCTAssertThrowsError(try store.upsertMemory(edited))
            XCTAssertEqual(try store.memoryCount(), 1)
            XCTAssertEqual(try store.getMemory(id: original.id), original)
            try fixtureSQL(url, "DROP TRIGGER reject_memory_insert")
            for index in 1..<AssistantLimits.memorySlots { try store.upsertMemory(MemoryFact(text: "Факт \(index)")) }
            XCTAssertEqual(try store.memoryCount(), AssistantLimits.memorySlots)
        }
    }

    func testConcurrentMemoryWritersCannotOverfillLastSlot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "timeline.sqlite")
        let first = try LocalDataStore(databaseURL: url)
        let second = try LocalDataStore(databaseURL: url)
        for index in 0..<(AssistantLimits.memorySlots - 1) { try first.upsertMemory(MemoryFact(text: "Факт \(index)")) }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (index, store) in [first, second].enumerated() {
                group.addTask { (try? store.upsertMemory(MemoryFact(text: "Конкурентный факт \(index)"))) != nil }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try first.memoryCount(), AssistantLimits.memorySlots)
    }

    func testReminderCRUDStatusesDateBoundariesAndReopen() throws {
        try withStore { store, url in
            let created = Date(timeIntervalSince1970: 10)
            let first = try store.upsertReminder(LocalReminder(title: "Раньше", dueAt: Date(timeIntervalSince1970: 100), createdAt: created, updatedAt: created))
            let blocked = try store.upsertReminder(LocalReminder(title: "Без разрешения", dueAt: Date(timeIntervalSince1970: 80), status: .blocked))
            let completed = try store.upsertReminder(LocalReminder(title: "Сделано", dueAt: Date(timeIntervalSince1970: 90), status: .completed))
            let future = try store.upsertReminder(LocalReminder(title: "Позже", dueAt: Date(timeIntervalSince1970: 200)))
            XCTAssertEqual(try store.reminders().map(\.id), [blocked.id, completed.id, first.id, future.id])
            XCTAssertEqual(try store.reminders(status: .scheduled).map(\.id), [first.id, future.id])
            XCTAssertEqual(try store.reminders(dueBefore: Date(timeIntervalSince1970: 100)).map(\.id), [first.id])
            XCTAssertTrue(try store.reminders(dueBefore: Date(timeIntervalSince1970: 99)).isEmpty)
            XCTAssertEqual(first.notificationIdentifier, first.id.uuidString)

            let edited = try store.upsertReminder(LocalReminder(id: first.id, title: "Изменено", dueAt: Date(timeIntervalSince1970: 300), createdAt: Date(timeIntervalSince1970: 900), updatedAt: Date(timeIntervalSince1970: 20), status: .completed))
            XCTAssertEqual(edited.createdAt, created)
            XCTAssertEqual(edited.updatedAt, Date(timeIntervalSince1970: 20))
            XCTAssertEqual(edited.status, .completed)
            XCTAssertEqual(try LocalDataStore(databaseURL: url).getReminder(id: first.id), edited)
            XCTAssertEqual(try store.reminders(status: .scheduled).map(\.id), [future.id])
            XCTAssertThrowsError(try store.upsertReminder(LocalReminder(title: " ", dueAt: Date())))
            XCTAssertThrowsError(try store.upsertReminder(LocalReminder(title: "Invalid", dueAt: Date(timeIntervalSince1970: .infinity))))
            try store.deleteReminder(id: first.id)
            XCTAssertNil(try store.getReminder(id: first.id))
        }
    }

    func testCorruptDatabaseIsReportedWithoutDeletingOrReplacingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "corrupt.sqlite")
        let original = Data("This is an intentionally corrupt database fixture, not user data.".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try LocalDataStore(databaseURL: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFutureSchemaVersionIsNotReset() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "future.sqlite")
        try fixtureSQL(url, "CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES ('retain'); PRAGMA user_version=42;")
        XCTAssertThrowsError(try LocalDataStore(databaseURL: url)) { error in
            XCTAssertEqual(error as? LocalDataError, .unsupportedSchema(42))
        }
        try fixtureSQL(url, "CREATE TABLE retention_check AS SELECT value FROM future_data WHERE value = 'retain';")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Findy.LocalDataTest.\(UUID().uuidString)")
    }

    private func withStore(_ body: (LocalDataStore, URL) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "timeline.sqlite")
        try body(LocalDataStore(databaseURL: url), url)
    }

    private func fixtureSQL(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db else { throw FixtureError(code: opened) }
        defer { sqlite3_close_v2(db) }
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw FixtureError(code: result) }
    }
}

private struct FixtureError: Error { let code: Int32 }
