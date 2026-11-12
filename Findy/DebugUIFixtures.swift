import Foundation
#if DEBUG && targetEnvironment(simulator)
import SQLite3
#endif

/// UI fixtures are available only in isolated Simulator test sessions.
@MainActor
enum DebugUIFixtures {
    static func prepareIfRequested() {
        #if DEBUG && targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"],
              let sessionID = UUID(uuidString: value) else { return }
        let args = ProcessInfo.processInfo.arguments
        let fixtureDefaults = UserDefaults(suiteName: "findy.ui-tests." + sessionID.uuidString)
        if args.contains("--seed-ui-oversized-prompt"), fixtureDefaults?.data(forKey: "assistant.providers") == nil {
            let provider = AssistantProvider(name: "Тестовый сервис", endpoint: "https://example.invalid/v1", apiStyle: .realtime,
                models: ["test-model"], systemPrompt: String(repeating: "я", count: 501))
            fixtureDefaults?.set(try? JSONEncoder().encode([provider]), forKey: "assistant.providers")
        }
        if args.contains("--seed-ui-legacy-memory") || args.contains("--seed-ui-memory-cap") {
            do { try seedMemories(sessionID: sessionID, legacy: args.contains("--seed-ui-legacy-memory")) }
            catch { SessionLog.shared.record("ui.memoryFixture.failed", SessionLog.describe(error)) }
        }
        let settings = AssistantSettings.shared
        if args.contains("--skip-onboarding") { settings.completeOnboarding() }
        let localReplies = args.contains("--ui-local-replies") || args.contains("--seed-ui-history") || args.contains("--seed-ui-rich-history") || args.contains("--seed-ui-delete-history")
        if args.contains("--seed-ui-provider") || localReplies {
            do {
                if settings.providers.isEmpty {
                    let provider = AssistantProvider(name: "Тестовый сервис", endpoint: "https://example.invalid/v1", apiStyle: .realtime, models: ["test-model"])
                    try settings.upsertProvider(provider, apiKey: nil)
                    try settings.selectModel(providerID: provider.id, modelID: "test-model")
                }
                if args.contains("--ui-local-replies"), let provider = settings.selectedProvider { settings.grantSharing(for: provider) }
            } catch { SessionLog.shared.record("ui.providerFixture.failed", SessionLog.describe(error)) }
        }
        let richHistory = args.contains("--seed-ui-rich-history")
        let deletionHistory = args.contains("--seed-ui-delete-history")
        guard richHistory || deletionHistory || args.contains("--seed-ui-history") else { return }
        do {
            let store = try PersonalData.shared.requireStore()
            if deletionHistory && fixtureDefaults?.bool(forKey: "deleteHistorySeeded") == true { return }
            guard try store.totalCount() == 0 else { return }
            for number in 1...(deletionHistory ? 3 : richHistory ? 80 : 520) {
                if richHistory {
                    let user = number.isMultiple(of: 2)
                    let text = user
                        ? "Вопрос \(number): расскажи подробнее о поездке и учти длинный адрес https://example.com/very-long-path/with-many-components?query=long-value&another=value"
                        : "Ответ \(number). Вот подробное объяснение с несколькими абзацами и переносами строк. Этот текст помогает проверить, что сообщения сохраняют правильную ширину и не перекрываются.\n\nВторая часть ответа содержит дополнительные сведения, которые занимают несколько строк на экране телефона."
                    let sources = user ? [] : (1...4).map { index in
                        AssistantSource(title: "Источник \(index)", url: URL(string: "https://source\(index).example.com/article")!)
                    }
                    try store.upsertMessage(AssistantMessage(role: user ? .user : .assistant, text: text, sources: sources), scope: "conversation", createdAt: Date(timeIntervalSince1970: Double(number)))
                    continue
                }
                let message = AssistantMessage(role: number.isMultiple(of: 2) ? .assistant : .user,
                    text: String(format: "Сообщение %04d", number))
                try store.upsertMessage(message, scope: "conversation", createdAt: Date(timeIntervalSince1970: Double(number)))
            }
            if deletionHistory { fixtureDefaults?.set(true, forKey: "deleteHistorySeeded") }
        } catch { SessionLog.shared.record("ui.fixture.failed", SessionLog.describe(error)) }
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    /// Seed an older database directly to exercise non-destructive limit upgrades.
    /// Callers already require a valid isolated Simulator session UUID.
    private static func seedMemories(sessionID: UUID, legacy: Bool) throws {
        let directory = URL.applicationSupportDirectory.appending(path: "Findy/UITests/" + sessionID.uuidString,
            directoryHint: .isDirectory)
        let store = try LocalDataStore(databaseURL: directory.appending(path: "findy.sqlite"))
        guard try store.memoryCount() == 0 else { return }
        if !legacy {
            for index in 1...AssistantLimits.memorySlots {
                try store.upsertMemory(MemoryFact(text: "Тестовый факт \(index)"))
            }
            return
        }
        var database: OpaquePointer?
        guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        for index in 1...16 {
            let prefix = "Наследие "
            let text = index == 16 ? prefix + String(repeating: "я", count: 501 - prefix.count) : "Тестовый факт \(index)"
            var statement: OpaquePointer?
            let sql = "INSERT INTO memories(id, body, normalized, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, UUID().uuidString.lowercased(), -1, transient)
            sqlite3_bind_text(statement, 2, text, -1, transient)
            sqlite3_bind_text(statement, 3, "legacy-fixture-\(index)", -1, transient)
            sqlite3_bind_double(statement, 4, Double(index))
            sqlite3_bind_double(statement, 5, Double(index))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    #endif

}
