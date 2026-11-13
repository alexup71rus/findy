import Foundation
import XCTest
@testable import AssistantCore

final class PersonalIntentTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testExplicitReminderCanReceiveTwoClarificationsWithoutLosingItsOrigin() throws {
        var tracker = PersonalIntentTracker()
        let original = "Напомни купить молоко."
        tracker.accept(id: UUID(), text: original, now: now)
        XCTAssertEqual(tracker.request(for: .createReminder, currentRequest: original, now: now), original)
        tracker.accept(id: UUID(), text: "Завтра.", now: now.addingTimeInterval(5))
        let first = try XCTUnwrap(tracker.request(for: .createReminder, currentRequest: "Завтра.", now: now.addingTimeInterval(5)))
        XCTAssertTrue(first.contains(original))
        XCTAssertTrue(first.contains("Завтра."))
        tracker.accept(id: UUID(), text: "В восемь вечера.", now: now.addingTimeInterval(10))
        XCTAssertNotNil(tracker.request(for: .createReminder, currentRequest: "В восемь вечера.", now: now.addingTimeInterval(10)))
        tracker.accept(id: UUID(), text: "Дня, дня.", now: now.addingTimeInterval(15))
        XCTAssertNotNil(tracker.request(for: .createReminder, currentRequest: "Дня, дня.", now: now.addingTimeInterval(15)))
        tracker.accept(id: UUID(), text: "В тринадцать ноль ноль.", now: now.addingTimeInterval(20))
        XCTAssertNotNil(tracker.request(for: .createReminder, currentRequest: "В тринадцать ноль ноль.", now: now.addingTimeInterval(20)))
        tracker.accept(id: UUID(), text: "Хорошо.", now: now.addingTimeInterval(25))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "Хорошо.", now: now.addingTimeInterval(25)))
        XCTAssertFalse(tracker.hasPendingRequest(now: now.addingTimeInterval(25)))
    }

    func testNaturalSpokenReminderRequestSurvivesTheActualClarifications() {
        var tracker = PersonalIntentTracker()
        tracker.accept(id: UUID(), text: "А на его приложение попробую напоминание добавить какое-нибудь.", now: now)
        for (offset, text) in ["Ну давай завтра в час стрижка у меня, барбершоп.", "Дня, дня.", "В тринадцать ноль ноль."].enumerated() {
            let instant = now.addingTimeInterval(Double(offset + 1) * 5)
            tracker.accept(id: UUID(), text: text, now: instant)
            XCTAssertNotNil(tracker.request(for: .createReminder, currentRequest: text, now: instant))
        }
        tracker.didComplete(.createReminder)
        tracker.accept(id: UUID(), text: "Расскажи другую историю.", now: now.addingTimeInterval(25))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "Расскажи другую историю.", now: now.addingTimeInterval(25)))
    }

    func testCurrentUserEvidenceCannotUseAnEarlierTurn() {
        var tracker = PersonalIntentTracker()
        tracker.accept(id: UUID(), text: "Теперь Москва", now: now)
        XCTAssertTrue(tracker.isCurrentUserRequest("Теперь Москва"))
        tracker.accept(id: UUID(), text: "Привет", now: now.addingTimeInterval(1))
        XCTAssertFalse(tracker.isCurrentUserRequest("Теперь Москва"))
        XCTAssertFalse(tracker.isCurrentUserRequest(""))
    }

    func testSuccessfulActionDoesNotAuthorizeAnUnrelatedSubsequentTurn() {
        var tracker = PersonalIntentTracker()
        let original = "Напомни завтра в 20:00 купить молоко."
        tracker.accept(id: UUID(), text: original, now: now)
        tracker.didComplete(.createReminder)
        XCTAssertFalse(tracker.hasPendingRequest(now: now))
        tracker.accept(id: UUID(), text: "Расскажи что-нибудь интересное.", now: now.addingTimeInterval(1))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "Расскажи что-нибудь интересное.", now: now.addingTimeInterval(1)))
    }

    func testSeveralFactsFromTheSameUtteranceRemainAuthorizedAfterTheFirstSave() {
        var tracker = PersonalIntentTracker()
        let id = UUID()
        let request = "Запомни: я левша и я люблю чай."
        tracker.accept(id: id, text: request, now: now)
        XCTAssertNotNil(tracker.request(for: .saveMemory, currentRequest: request, now: now))
        tracker.didComplete(.saveMemory)
        XCTAssertNotNil(tracker.request(for: .saveMemory, currentRequest: request, now: now.addingTimeInterval(1)))
        // Reobserving the identical persisted user item doesn't consume a
        // clarification or revoke the sibling function call.
        tracker.accept(id: id, text: request, now: now.addingTimeInterval(1))
        XCTAssertNotNil(tracker.request(for: .saveMemory, currentRequest: request, now: now.addingTimeInterval(1)))
        tracker.didComplete(.saveMemory)
        tracker.accept(id: UUID(), text: "Спасибо.", now: now.addingTimeInterval(2))
        XCTAssertNil(tracker.request(for: .saveMemory, currentRequest: "Спасибо.", now: now.addingTimeInterval(2)))
    }

    func testStaleRawRequestCannotAuthorizeTheCurrentTurn() {
        var tracker = PersonalIntentTracker()
        let original = "Запомни, что я люблю чай."
        tracker.accept(id: UUID(), text: original, now: now)
        tracker.accept(id: UUID(), text: "Без сахара.", now: now.addingTimeInterval(1))
        XCTAssertNil(tracker.request(for: .saveMemory, currentRequest: original, now: now.addingTimeInterval(1)))
        XCTAssertNotNil(tracker.request(for: .saveMemory, currentRequest: "Без сахара.", now: now.addingTimeInterval(1)))
        XCTAssertNil(tracker.request(for: .saveMemory, currentRequest: "Посторонний запрос", now: now.addingTimeInterval(1)))
    }

    func testNewExplicitActionReplacesTheOldPendingAction() {
        var tracker = PersonalIntentTracker()
        tracker.accept(id: UUID(), text: "Напомни купить молоко.", now: now)
        let save = "Запомни, что я люблю чай."
        tracker.accept(id: UUID(), text: save, now: now.addingTimeInterval(1))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: save, now: now.addingTimeInterval(1)))
        XCTAssertNotNil(tracker.request(for: .saveMemory, currentRequest: save, now: now.addingTimeInterval(1)))
        XCTAssertNil(tracker.request(for: .removeMemory, currentRequest: save, now: now.addingTimeInterval(1)))
    }

    func testRevisedTranscriptForSameItemRevokesEarlierConsent() {
        var tracker = PersonalIntentTracker()
        let id = UUID()
        tracker.accept(id: id, text: "Запомни мой город.", now: now)
        tracker.accept(id: id, text: "Запомни мой город, не сохраняй его.", now: now.addingTimeInterval(1))
        XCTAssertNil(tracker.request(for: .saveMemory, currentRequest: "Запомни мой город, не сохраняй его.", now: now.addingTimeInterval(1)))
    }

    func testExplicitRefusalRevokesEarlierPendingMutations() {
        for refusal in ["Не сохраняй это.", "Не запоминай.", "Теперь Москва, не меняй память.", "Не нужно сохранять.", "Не запоминать."] {
            var tracker = PersonalIntentTracker()
            tracker.accept(id: UUID(), text: "Запомни мой город.", now: now)
            tracker.accept(id: UUID(), text: refusal, now: now.addingTimeInterval(1))
            XCTAssertNil(tracker.request(for: .saveMemory, currentRequest: refusal, now: now.addingTimeInterval(1)), refusal)
        }
        for refusal in ["Не напоминай мне.", "Не создавай напоминание.", "Don't remind me."] {
            var tracker = PersonalIntentTracker()
            tracker.accept(id: UUID(), text: "Напомни купить молоко.", now: now)
            tracker.accept(id: UUID(), text: refusal, now: now.addingTimeInterval(1))
            XCTAssertNil(tracker.request(for: .createReminder, currentRequest: refusal, now: now.addingTimeInterval(1)), refusal)
        }
        for refusal in ["Не удаляй это из памяти.", "Не забывай мой адрес.", "Не нужно удалять.", "Don't forget that."] {
            var tracker = PersonalIntentTracker()
            tracker.accept(id: UUID(), text: "Забудь мой адрес.", now: now)
            tracker.accept(id: UUID(), text: refusal, now: now.addingTimeInterval(1))
            XCTAssertNil(tracker.request(for: .removeMemory, currentRequest: refusal, now: now.addingTimeInterval(1)), refusal)
        }
        var tracker = PersonalIntentTracker()
        tracker.accept(id: UUID(), text: "Удали напоминание про молоко.", now: now)
        tracker.accept(id: UUID(), text: "Не удаляй его.", now: now.addingTimeInterval(1))
        XCTAssertNil(tracker.request(for: .changeReminder, currentRequest: "Не удаляй его.", now: now.addingTimeInterval(1)))
    }

    func testCancellationRevokesPendingAuthorizationInRussianAndEnglish() {
        for cancellation in ["Не надо.", "Отмена.", "Забудь просьбу.", "Отмени просьбу.", "Never mind.", "Cancel that."] {
            var tracker = PersonalIntentTracker()
            tracker.accept(id: UUID(), text: "Напомни купить молоко.", now: now)
            tracker.accept(id: UUID(), text: cancellation, now: now.addingTimeInterval(1))
            XCTAssertFalse(tracker.hasPendingRequest(now: now.addingTimeInterval(1)), cancellation)
            XCTAssertNil(tracker.request(for: .createReminder, currentRequest: cancellation, now: now.addingTimeInterval(1)), cancellation)
            tracker.accept(id: UUID(), text: "Завтра в восемь.", now: now.addingTimeInterval(2))
            XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "Завтра в восемь.", now: now.addingTimeInterval(2)), cancellation)
        }
    }

    func testAuthorizationExpiresAfterThreeMinutesAndClarificationDoesNotExtendIt() {
        var tracker = PersonalIntentTracker()
        let original = "Напомни купить молоко."
        tracker.accept(id: UUID(), text: original, now: now)
        XCTAssertTrue(tracker.hasPendingRequest(now: now.addingTimeInterval(179)))
        tracker.accept(id: UUID(), text: "Завтра.", now: now.addingTimeInterval(179))
        XCTAssertNotNil(tracker.request(for: .createReminder, currentRequest: "Завтра.", now: now.addingTimeInterval(179)))
        XCTAssertFalse(tracker.hasPendingRequest(now: now.addingTimeInterval(180)))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "Завтра.", now: now.addingTimeInterval(180)))
        tracker.accept(id: UUID(), text: "В восемь.", now: now.addingTimeInterval(181))
        XCTAssertNil(tracker.request(for: .createReminder, currentRequest: "В восемь.", now: now.addingTimeInterval(181)))
    }

    func testCodableRestoresPendingIntentButDoesNotPersistTheCurrentClarificationText() throws {
        var tracker = PersonalIntentTracker()
        let original = "Напомни купить молоко."
        tracker.accept(id: UUID(), text: original, now: now)
        let clarification = "Уникальное уточнение: завтра."
        tracker.accept(id: UUID(), text: clarification, now: now.addingTimeInterval(1))
        let encoded = try JSONEncoder().encode(tracker)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["currentText"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(clarification))
        var restored = try JSONDecoder().decode(PersonalIntentTracker.self, from: encoded)
        XCTAssertTrue(restored.hasPendingRequest(now: now.addingTimeInterval(2)))
        XCTAssertNil(restored.request(for: .createReminder, currentRequest: clarification, now: now.addingTimeInterval(2)))
        restored.accept(id: UUID(), text: "В 20:00.", now: now.addingTimeInterval(2))
        let authorized = try XCTUnwrap(restored.request(for: .createReminder, currentRequest: "В 20:00.", now: now.addingTimeInterval(2)))
        XCTAssertTrue(authorized.contains(original))
        XCTAssertTrue(authorized.contains("В 20:00."))
    }

    func testPersistedCompletedIntentCannotAuthorizeAFutureTurn() throws {
        var tracker = PersonalIntentTracker()
        tracker.accept(id: UUID(), text: "Запомни, что я левша.", now: now)
        tracker.didComplete(.saveMemory)
        var restored = try JSONDecoder().decode(PersonalIntentTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertFalse(restored.hasPendingRequest(now: now.addingTimeInterval(1)))
        let later = "А ещё я люблю чай."
        restored.accept(id: UUID(), text: later, now: now.addingTimeInterval(1))
        XCTAssertNil(restored.request(for: .saveMemory, currentRequest: later, now: now.addingTimeInterval(1)))
    }
}
