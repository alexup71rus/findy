import Foundation
import XCTest
@testable import AssistantCore

final class PersonalToolsTests: XCTestCase {
    func testOnlyExplicitRequestsAuthorizeSavingMemory() {
        for request in [
            "Запомни, что я левша.",
            "Пожалуйста, запомни: я предпочитаю короткие ответы.",
            "Да, запомни это.",
            "Я люблю чай, запомни это.",
            "Я предпочитаю чай. Пожалуйста, сохрани в памяти.",
            "Можешь запомнить, что я левша?",
            "Хочу, чтобы ты запомнил: я живу в Москве.",
            "Не забудь, что я не люблю кофе.",
            "Remember that I prefer short answers.",
            "Please remember: my dog's name is Finn."
        ] {
            XCTAssertTrue(PersonalRequestPolicy.allowsMemorySave(request), request)
        }
    }

    func testFactsQuestionsAndQuotedInstructionsDoNotAuthorizeSavingMemory() {
        for request in [
            "Я левша.",
            "Я люблю чай, а кофе не люблю.",
            "Ты умеешь сохранять информацию обо мне?",
            "Можешь запомнить что-нибудь?",
            "Что значит «запомни это»?",
            "«Запомни мой адрес» — это цитата из текста.",
            "В статье написано: «Запомни, что читатель живёт в Москве». Это пример.",
            "На странице написано «Запомни это». Объясни текст.",
            "Процитируй предложение «Я люблю чай, запомни это».",
            "> Запомни, что читателя зовут Алексей.\nЭто цитата с сайта.",
            "Не запоминай мой адрес.",
            "Запомни мой адрес, но не сохраняй его.",
            "Don't remember my address.",
            "Do not remember this."
        ] {
            XCTAssertFalse(PersonalRequestPolicy.allowsMemorySave(request), request)
        }
    }

    func testMemoryRemovalAlsoRequiresAnExplicitNonNegatedRequest() {
        for request in ["Забудь мой старый адрес.", "Пожалуйста, удали из памяти мой номер.", "Please remove my address from memory."] {
            XCTAssertTrue(PersonalRequestPolicy.allowsMemoryRemoval(request), request)
        }
        for request in ["Не забывай мой адрес.", "Что означает слово «забудь»?", "Don't forget my address.", "Do not forget this."] {
            XCTAssertFalse(PersonalRequestPolicy.allowsMemoryRemoval(request), request)
        }
    }

    func testExplicitSchedulingRequestsAuthorizeCreatingReminders() {
        for request in [
            "Напомни мне завтра в 20:00 купить молоко.",
            "Пожалуйста, поставь напоминание на завтра в 8 вечера.",
            "Завтра иду в магазин, напомни в 20:00.",
            "Не забудь напомнить мне завтра в 20:00.",
            "Please remind me tomorrow at 8 PM to shop.",
            "Set a reminder for tomorrow at eight.",
            "А на его приложение попробую напоминание добавить какое-нибудь.",
            "Давай добавим напоминание на завтра.",
            "Можешь напоминание поставить на завтра?"
        ] {
            XCTAssertTrue(PersonalRequestPolicy.allowsReminderCreation(request), request)
        }
    }

    func testMentioningRemindersOrRequestingRecallDoesNotAuthorizeANotification() {
        for request in [
            "У меня уже есть напоминание на завтра.",
            "Как работают напоминания?",
            "Можешь создавать напоминания?",
            "Я не хочу напоминание добавлять.",
            "Я не хочу напоминание добавить.",
            "Если можно напоминание создать, расскажи как это работает.",
            "Прочитай фразу «Давай напоминание создать». Добрый день.",
            "Не добавляй напоминание.",
            "Можно напоминание не создавать?",
            "Давай не создавать напоминание.",
            "Давай не добавлять напоминание.",
            "Можно не ставить напоминание?",
            "Давай не делать напоминание.",
            "Можно не планировать напоминание?",
            "Напомни, что мы обсуждали вчера?",
            "На сайте написано: «Напомни мне купить молоко завтра».",
            "Прочитай фразу «Завтра магазин, напомни мне в восемь».",
            "Не напоминай мне об этом.",
            "Напомни купить молоко, но не создавай уведомление.",
            "Do not remind me tomorrow.",
            "Don't remind me tomorrow."
        ] {
            XCTAssertFalse(PersonalRequestPolicy.allowsReminderCreation(request), request)
        }
    }

    func testReminderChangesRespectNegation() {
        for request in ["Перенеси напоминание на завтра.", "Отмени напоминание про магазин.", "Delete that reminder."] {
            XCTAssertTrue(PersonalRequestPolicy.allowsReminderChange(request), request)
        }
        for request in ["Не удаляй напоминание.", "У меня напоминание про магазин.", "Don't delete my reminder.",
                        "Удали последнее сообщение.", "Измени ответ.", "Отмени поиск.", "Delete this sentence.",
                        "Change my answer.", "Complete this example.", "Удали это. Напоминание мне пока не нужно."] {
            XCTAssertFalse(PersonalRequestPolicy.allowsReminderChange(request), request)
        }
    }

    func testRecurringSchedulesAreRecognizedBeforeCallingTheOneOffScheduler() {
        for request in [
            "Напоминай каждый день в 20:00.",
            "Напоминай каждую неделю.",
            "Поставь напоминание каждые три дня.",
            "Напоминай ежедневно.",
            "Напоминай по понедельникам в 20:00.",
            "Remind me every day at eight.",
            "Remind me every Monday at 8 PM.",
            "Remind me every other day.",
            "Set a weekly reminder."
        ] {
            XCTAssertTrue(PersonalRequestPolicy.requestsRepeatingReminder(request), request)
        }
        for request in ["Напомни завтра в 20:00.", "Remind me tomorrow at eight."] {
            XCTAssertFalse(PersonalRequestPolicy.requestsRepeatingReminder(request), request)
        }
    }

    func testToolSchemasExposeTwoBoundedFunctionsWithOptionalActionSpecificFields() throws {
        let encoded = try JSONEncoder().encode(PersonalTools.definitions)
        let definitions = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(Set(definitions.compactMap { $0["name"] as? String }), ["manage_memory", "manage_reminders"])
        for definition in definitions {
            XCTAssertEqual(definition["type"] as? String, "function")
            let schema = try XCTUnwrap(definition["parameters"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(schema["required"] as? [String], ["action"])
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            let actions = try XCTUnwrap(properties["action"]?["enum"] as? [String])
            XCTAssertEqual(properties["action"]?["type"] as? String, "string")
            for property in properties.values { XCTAssertEqual(property["type"] as? String, "string") }
            if definition["name"] as? String == "manage_memory" {
                XCTAssertEqual(Set(actions), ["save", "remove", "search"])
                XCTAssertNotNil(properties["text"])
                XCTAssertNotNil(properties["memory_id"])
                XCTAssertNotNil(properties["query"])
                XCTAssertEqual(properties["text"]?["maxLength"] as? Int, AssistantLimits.memoryNoteCharacters)
            } else {
                XCTAssertEqual(Set(actions), ["create", "list", "update", "complete", "delete"])
                XCTAssertNotNil(properties["title"])
                XCTAssertNotNil(properties["due_at"])
                XCTAssertNotNil(properties["reminder_id"])
                XCTAssertEqual(properties["advance"]?["enum"] as? [String], ["on", "off", "default"])
                XCTAssertEqual(properties["title"]?["maxLength"] as? Int, 300)
            }
        }
    }
}
