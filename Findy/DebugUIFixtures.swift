import Foundation
#if DEBUG && targetEnvironment(simulator)
import SQLite3
import UIKit
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
                models: ["test-model"], systemPrompt: String(repeating: "я", count: AssistantLimits.systemPromptCharacters + 1))
            fixtureDefaults?.set(try? JSONEncoder().encode([provider]), forKey: "assistant.providers")
        }
        if args.contains("--seed-ui-legacy-memory") || args.contains("--seed-ui-memory-cap") {
            do { try seedMemories(sessionID: sessionID, legacy: args.contains("--seed-ui-legacy-memory")) }
            catch { SessionLog.shared.record("ui.memoryFixture.failed", SessionLog.describe(error)) }
        }
        let settings = AssistantSettings.shared
        if args.contains("--skip-onboarding") { settings.completeOnboarding() }
        let showcase = args.contains("--seed-ui-showcase") || args.contains("--seed-ui-demo")
        let localReplies = args.contains("--ui-local-replies") || args.contains("--seed-ui-history") || args.contains("--seed-ui-rich-history") || args.contains("--seed-ui-delete-history") || showcase
        if args.contains("--seed-ui-provider") || localReplies {
            do {
                if settings.providers.isEmpty {
                    let provider = AssistantProvider(name: showcase ? "Мой помощник" : "Тестовый сервис", endpoint: "https://example.invalid/v1", apiStyle: .realtime, models: ["test-model"])
                    try settings.upsertProvider(provider, apiKey: nil)
                    try settings.selectModel(providerID: provider.id, modelID: "test-model")
                }
                if args.contains("--ui-local-replies"), let provider = settings.selectedProvider { settings.grantSharing(for: provider) }
            } catch { SessionLog.shared.record("ui.providerFixture.failed", SessionLog.describe(error)) }
        }
        if args.contains("--seed-ui-image") {
            do {
                if try PersonalData.shared.requireStore().totalCount() == 0 { try GeneratedImages.saveFixture(scope: "conversation") }
            } catch { SessionLog.shared.record("ui.imageFixture.failed", SessionLog.describe(error)) }
        }
        if args.contains("--ui-attachments-fixture"), var provider = settings.selectedProvider {
            provider.imageInputEnabled = true
            do { try settings.upsertProvider(provider, apiKey: nil) }
            catch { SessionLog.shared.record("ui.attachmentFixture.failed", SessionLog.describe(error)) }
        }
        if args.contains("--demo-generated-image") {
            do { try seedGeneratedImageDemo() }
            catch { SessionLog.shared.record("ui.demoImage.failed", SessionLog.describe(error)) }
            return
        }
        if args.contains("--seed-ui-demo") {
            do { try seedDemo(attachments: args.contains("--demo-attachments"), voice: args.contains("--preview-voice-listening")) }
            catch { SessionLog.shared.record("ui.demo.failed", SessionLog.describe(error)) }
            return
        }
        let richHistory = args.contains("--seed-ui-rich-history")
        let deletionHistory = args.contains("--seed-ui-delete-history")
        guard showcase || richHistory || deletionHistory || args.contains("--seed-ui-history") else { return }
        do {
            let store = try PersonalData.shared.requireStore()
            if deletionHistory && fixtureDefaults?.bool(forKey: "deleteHistorySeeded") == true { return }
            guard try store.totalCount() == 0 else { return }
            if showcase {
                let messages: [(AssistantMessage.Role, String)] = [
                    (.user, "Еду за город на выходные. Помоги собрать вещи на два дня."),
                    (.assistant, "Возьмите документы, телефон с зарядкой, сменную одежду и удобную обувь. Добавьте воду, перекус и средства гигиены. Для прохладного вечера пригодится тёплая кофта."),
                    (.user, "Обещают дождь. Что добавить?"),
                    (.assistant, "Дождевик или непромокаемую куртку, запасные носки и пакет для мокрых вещей. Если будете гулять, выбирайте обувь, которая не промокает.")
                ]
                for (index, message) in messages.enumerated() {
                    try store.upsertMessage(AssistantMessage(role: message.0, text: message.1), scope: "conversation", createdAt: Date(timeIntervalSince1970: Double(index)))
                }
                return
            }
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
    private static func seedGeneratedImageDemo() throws {
        let store = try PersonalData.shared.requireStore()
        guard try store.totalCount() == 0 else { return }
        let url = URL.applicationSupportDirectory.appending(path: "FindyDemoGeneratedImage.png")
        let image = try Data(contentsOf: url)
        guard UIImage(data: image) != nil else { throw ImageGenerationError.invalidImage }
        let messages: [(AssistantMessage.Role, String)] = [
            (.user, "Хочу красивую картинку для настроения."),
            (.assistant, "Что хотите увидеть на ней?"),
            (.user, "Лесное озеро на рассвете, небольшой причал и лёгкий туман. Спокойные, тёплые цвета.")
        ]
        for (index, entry) in messages.enumerated() {
            try store.upsertMessage(AssistantMessage(role: entry.0, text: entry.1), scope: "conversation", createdAt: Date(timeIntervalSince1970: Double(index + 1)))
        }
        try GeneratedImages.save(image, scope: "conversation")
    }

    private static func seedDemo(attachments: Bool, voice: Bool) throws {
        let store = try PersonalData.shared.requireStore()
        guard try store.totalCount() == 0 else { return }
        let facts = [
            "Предпочитаю короткие ответы и конкретные шаги.",
            "Люблю пешие прогулки и спокойные маршруты у воды.",
            "Обычно тренируюсь во вторник и четверг вечером.",
            "На выходные выбираю поездки на один-два дня."
        ]
        for (index, text) in facts.enumerated() {
            let date = Date(timeIntervalSince1970: 1_794_566_400 + Double(index) * 60)
            try store.upsertMemory(MemoryFact(text: text, createdAt: date, updatedAt: date))
        }
        let conversation: [(AssistantMessage.Role, String)]
        if attachments {
            let image = AssistantAttachment(name: "Прогулка у озера.jpg", mimeType: "image/jpeg", data: demoMap())
            let file = AssistantAttachment(name: "Список вещей.txt", mimeType: "text/plain", data: Data("Вода — 1,5 л\nЛёгкий перекус\nЗаряженный телефон\nНепромокаемая куртка\nУдобная обувь".utf8))
            let message = AssistantMessage(role: .user, text: "Подойдёт такой маршрут для спокойной прогулки? Приложил карту и список вещей.")
            try store.upsertMessage(message, scope: "conversation", createdAt: Date(timeIntervalSince1970: 1))
            try ChatAttachments.persist([image, file], messageID: message.id, store: store)
            conversation = [
                (.assistant, "Маршрут выглядит спокойным: основная часть проходит по лесу, а у озера удобно сделать привал. В список стоит добавить небольшой запас воды."),
                (.user, "Можно уложиться в полдня?"),
                (.assistant, "Да, если идти без спешки и сделать один длинный привал. Начните утром и заранее отметьте точку, откуда удобнее вернуться.")
            ]
        } else if voice {
            conversation = [
                (.user, "Помоги спокойно спланировать завтрашний день."),
                (.assistant, "Начнём с главного. Какие два дела вы точно хотите закончить, и во сколько нужно выйти из дома?")
            ]
        } else {
            conversation = [
                (.user, "Планирую прогулку за городом в субботу. Помоги собраться без лишних вещей."),
                (.assistant, "Начните с удобной обуви, воды и лёгкого перекуса. Возьмите заряженный телефон, пауэрбанк и непромокаемую куртку."),
                (.user, "Хочу пройти около 10 км и вернуться до вечера."),
                (.assistant, "Выберите кольцевой маршрут и оставьте запас времени на остановки. На 10 км заложите 3–4 часа: точное время зависит от рельефа и темпа."),
                (.user, "Что проверить утром перед выходом?"),
                (.assistant, "Прогноз погоды, заряд телефона и доступность маршрута. Сохраните карту офлайн и сообщите близкому человеку, куда идёте.")
            ]
        }
        for (index, entry) in conversation.enumerated() {
            try store.upsertMessage(AssistantMessage(role: entry.0, text: entry.1), scope: "conversation", createdAt: Date(timeIntervalSince1970: Double(index + 2)))
        }
    }

    private static func demoMap() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 420)).jpegData(withCompressionQuality: 0.9) { renderer in
            let context = renderer.cgContext
            UIColor(red: 0.90, green: 0.94, blue: 0.87, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
            UIColor(red: 0.66, green: 0.84, blue: 0.86, alpha: 1).setFill()
            context.fillEllipse(in: CGRect(x: 218, y: 93, width: 260, height: 191))
            for (x, y) in [(62.0, 94.0), (111, 129), (156, 74), (535, 112), (570, 157), (518, 194), (74, 242), (127, 276), (181, 325), (464, 333), (526, 305), (565, 354)] {
                let tree = UIBezierPath()
                tree.move(to: CGPoint(x: x, y: y)); tree.addLine(to: CGPoint(x: x - 15, y: y + 30)); tree.addLine(to: CGPoint(x: x + 15, y: y + 30)); tree.close()
                UIColor(red: 0.37, green: 0.57, blue: 0.40, alpha: 0.6).setFill(); tree.fill()
            }
            let route = UIBezierPath()
            route.move(to: CGPoint(x: 89, y: 348)); route.addCurve(to: CGPoint(x: 195, y: 155), controlPoint1: CGPoint(x: 81, y: 243), controlPoint2: CGPoint(x: 166, y: 220))
            route.addCurve(to: CGPoint(x: 481, y: 120), controlPoint1: CGPoint(x: 228, y: 57), controlPoint2: CGPoint(x: 410, y: 47))
            route.addCurve(to: CGPoint(x: 470, y: 300), controlPoint1: CGPoint(x: 547, y: 182), controlPoint2: CGPoint(x: 507, y: 269))
            route.addCurve(to: CGPoint(x: 89, y: 348), controlPoint1: CGPoint(x: 362, y: 365), controlPoint2: CGPoint(x: 194, y: 350))
            route.lineWidth = 6; route.lineCapStyle = .round; route.setLineDash([8, 7], count: 2, phase: 0)
            UIColor(red: 0.84, green: 0.41, blue: 0.23, alpha: 1).setStroke(); route.stroke()
            let title = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor(red: 0.20, green: 0.34, blue: 0.27, alpha: 1)]
            ("Прогулка у озера" as NSString).draw(at: CGPoint(x: 24, y: 19), withAttributes: title)
            ("8,5 км · кольцевой маршрут" as NSString).draw(at: CGPoint(x: 24, y: 379), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
            ("Лесное озеро" as NSString).draw(at: CGPoint(x: 267, y: 175), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: UIColor(red: 0.19, green: 0.41, blue: 0.49, alpha: 1)])
            UIColor.white.setFill(); context.fillEllipse(in: CGRect(x: 78, y: 337, width: 22, height: 22))
            UIColor(red: 0.84, green: 0.41, blue: 0.23, alpha: 1).setFill(); context.fillEllipse(in: CGRect(x: 83, y: 342, width: 12, height: 12))
        }
    }

    /// Seed an older database directly to exercise non-destructive limit upgrades.
    /// Callers already require a valid isolated Simulator session UUID.
    private static func seedMemories(sessionID: UUID, legacy: Bool) throws {
        let directory = URL.applicationSupportDirectory.appending(path: "Findy/UITests/" + sessionID.uuidString,
            directoryHint: .isDirectory)
        let store = try LocalDataStore(databaseURL: directory.appending(path: "findy.sqlite"))
        guard try store.memoryCount() == 0 else { return }
        if !legacy {
            for index in 1...AssistantLimits.memorySlots {
                let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                let text = index == 1 ? "Самая старая запись" : "Тестовый факт \(index)"
                try store.upsertMemory(MemoryFact(text: text, createdAt: date, updatedAt: date))
            }
            return
        }
        var database: OpaquePointer?
        guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        for index in 1...(AssistantLimits.memorySlots + 1) {
            let prefix = "Наследие "
            let text = index == AssistantLimits.memorySlots + 1 ? prefix + String(repeating: "я", count: 501 - prefix.count) : "Тестовый факт \(index)"
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
