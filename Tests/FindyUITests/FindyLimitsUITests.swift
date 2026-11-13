import XCTest

final class FindyLimitsUITests: XCTestCase {
    private func launch(_ arguments: [String] = [], session: String = UUID().uuidString, draft: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FINDY_UI_TEST_SESSION"] = session
        app.launchEnvironment["FINDY_UI_TEST_DRAFT"] = draft
        app.launchArguments = ["--skip-onboarding"] + arguments
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testComposerClipsUnicodeAndNativeTypingAt500Characters() {
        let permitted = String(repeating: "я", count: 499) + "👨‍👩‍👧‍👦"
        let app = launch(["--seed-ui-provider"], draft: permitted + "ю")
        let field = app.textFields["chat-composer"]
        let counter = app.staticTexts["chat-character-count"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, permitted)
        XCTAssertEqual(counter.value as? String, "500 из 500")
        field.tap(); field.typeText("ю")
        XCTAssertEqual((field.value as? String)?.count, 500)
        XCTAssertEqual(counter.value as? String, "500 из 500")
        XCTAssertFalse(app.buttons["chat-microphone"].exists)
        XCTAssertTrue(app.buttons["chat-send"].isEnabled)
        XCTAssertLessThanOrEqual(counter.frame.maxY, field.frame.minY)
        capture("Limits light native keyboard Unicode500", app: app)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(counter.value as? String, "499 из 500")
        field.typeText("ю")
        XCTAssertEqual(counter.value as? String, "500 из 500")
    }

    func testChatCounterAppearsAt400AboveFieldWithoutMovingLayout() {
        let app = launch(["--seed-ui-provider"], draft: String(repeating: "я", count: 399))
        let field = app.textFields["chat-composer"]
        let counter = app.staticTexts["chat-character-count"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Let native keyboard entry settle before recording geometry.
        field.typeText("я" + XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual((field.value as? String)?.count, 399)
        XCTAssertFalse(counter.exists, "The quiet counter is hidden from accessibility below80%")
        let fieldBefore = field.frame
        let historyBefore = app.scrollViews["chat-history"].frame
        let sendBefore = app.buttons["chat-send"].frame
        capture("Chat counter399 hidden stable line", app: app)

        field.typeText("я")
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.value as? String, "400 из 500")
        XCTAssertLessThanOrEqual(counter.frame.maxY, field.frame.minY)
        XCTAssertEqual(field.frame.minY, fieldBefore.minY, accuracy: 0.5)
        XCTAssertEqual(field.frame.height, fieldBefore.height, accuracy: 0.5)
        XCTAssertEqual(app.scrollViews["chat-history"].frame.maxY, historyBefore.maxY, accuracy: 0.5)
        XCTAssertEqual(app.buttons["chat-send"].frame.minY, sendBefore.minY, accuracy: 0.5)
        capture("Chat counter400 above stable composer", app: app)

        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual((field.value as? String)?.count, 399)
        XCTAssertFalse(counter.exists)
        XCTAssertEqual(field.frame.minY, fieldBefore.minY, accuracy: 0.5)
        XCTAssertEqual(app.scrollViews["chat-history"].frame.maxY, historyBefore.maxY, accuracy: 0.5)
        field.typeText(String(repeating: "я", count: 101))
        XCTAssertEqual(counter.value as? String, "500 из 500")
        XCTAssertLessThanOrEqual(counter.frame.maxY, field.frame.minY)
        XCTAssertEqual(field.frame.minY, fieldBefore.minY, accuracy: 0.5)
        capture("Chat counter500 above composer", app: app)
    }

    func testVoiceComposerHasNoCharacterCounter() {
        let app = launch(["--preview-voice-listening"])
        let stop = app.buttons["chat-voice-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat-character-count"].exists)
        let voice = app.descendants(matching: .any)["chat-voice-composer"].firstMatch
        XCTAssertLessThanOrEqual(voice.frame.height, 60)
        capture("Limits compact voice without counter", app: app)
        stop.tap()
        let field = app.textFields["chat-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["chat-character-count"].exists)
        field.tap(); field.typeText("Привет")
        XCTAssertFalse(app.staticTexts["chat-character-count"].exists)
        capture("Limits native keyboard short draft", app: app)
    }

    func testOversizedSavedPromptRemainsEditableAndCancelPreservesIt() {
        let app = launch(["--seed-ui-oversized-prompt", "--show-settings"])
        let row = app.buttons["system-prompt-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editor = app.textViews["system-prompt-editor"]
        let counter = app.staticTexts["system-prompt-character-count"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let original = editor.value as? String ?? ""
        XCTAssertEqual(original.count, 1501)
        XCTAssertEqual((counter.value as? String)?.filter { !$0.isWhitespace }, "1501из1500")
        XCTAssertFalse(app.buttons["system-prompt-save"].isEnabled)
        // Tap inside the first text line rather than the editor's blank centre.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.03)).tap()
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual((counter.value as? String)?.filter { !$0.isWhitespace }, "1500из1500")
        XCTAssertTrue(app.buttons["system-prompt-save"].isEnabled)
        capture("Limits prompt keyboard1500", app: app)
        app.buttons["system-prompt-cancel"].tap()
        row.tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["system-prompt-preset"].tap()
        app.buttons["Полезный"].tap()
        XCTAssertTrue(app.buttons["system-prompt-save"].isEnabled)
        let restored = editor.value as? String ?? ""
        XCTAssertLessThanOrEqual(restored.count, 1500)
        app.buttons["system-prompt-save"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, restored)
        app.buttons["system-prompt-preset"].tap()
        app.buttons["Пользовательский"].tap()
        XCTAssertEqual(editor.value as? String, original)
    }

    func testMemoryCapLeavesLegacyEntriesVisibleAndEditable() {
        let app = launch(["--seed-ui-legacy-memory", "--show-memory"])
        let count = app.staticTexts["memory-slot-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "31 из 30")
        XCTAssertTrue(app.buttons["memory-add"].isEnabled)
        let legacy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Наследие ")).firstMatch
        XCTAssertTrue(legacy.waitForExistence(timeout: 5))
        legacy.press(forDuration: 1)
        app.buttons["Изменить"].tap()
        let editor = app.textViews["memory-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual((editor.value as? String)?.count, 501)
        XCTAssertEqual(app.staticTexts["memory-character-count"].value as? String, "501 из 500")
        XCTAssertFalse(app.buttons["memory-save"].isEnabled)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(app.staticTexts["memory-character-count"].value as? String, "500 из 500")
        XCTAssertTrue(app.buttons["memory-save"].isEnabled)
        let characterCount = app.staticTexts["memory-character-count"]
        XCTAssertTrue(characterCount.isHittable, "Counter remains visible above the native keyboard")
        XCTAssertLessThanOrEqual(characterCount.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture("Limits memory editing grandfathered501", app: app)
        app.buttons["memory-save"].tap()
        XCTAssertEqual(count.value as? String, "31 из 30")
        XCTAssertTrue(app.buttons["memory-add"].isEnabled)
    }

    func testFullMemoryAllowsManualAddAndReplacesOldestUpdatedRecord() {
        let app = launch(["--seed-ui-memory-cap", "--show-memory"])
        let count = app.staticTexts["memory-slot-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "30 из 30")
        XCTAssertTrue(app.buttons["memory-add"].isEnabled)
        capture("Limits30 memory slots", app: app)
        let fact = app.staticTexts["Тестовый факт 30"]
        XCTAssertTrue(fact.waitForExistence(timeout: 5))
        fact.press(forDuration: 1)
        app.buttons["Изменить"].tap()
        let editor = app.textViews["memory-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" изменён")
        XCTAssertTrue(app.buttons["memory-save"].isEnabled)
        app.buttons["memory-save"].tap()
        XCTAssertEqual(count.value as? String, "30 из 30")
        XCTAssertTrue(app.buttons["memory-add"].isEnabled)
        app.buttons["memory-add"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("Новая запись вместо самой старой")
        app.buttons["memory-save"].tap()
        XCTAssertTrue(app.staticTexts["Новая запись вместо самой старой"].waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "30 из 30")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Overflow is handled automatically without a confirmation")
        capture("Full memory manual add replaces oldest", app: app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Новая запись вместо самой старой"].waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "30 из 30")
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Самая старая запись")
        XCTAssertFalse(app.staticTexts["Самая старая запись"].exists, "The oldest last-updated record is replaced")
    }

    func testContextMessagePickerPersistsBothEndpoints() {
        let app = launch(["--show-settings"])
        let picker = app.buttons["context-message-count"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("15") || picker.value as? String == "15")
        picker.tap()
        app.buttons["5"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("5") || picker.value as? String == "5")
        app.terminate(); app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("5") || picker.value as? String == "5")
        picker.tap()
        let fifty = app.buttons["50"]
        if !fifty.isHittable { app.swipeUp() }
        fifty.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("50") || picker.value as? String == "50")
        capture("Context messages50 persisted", app: app)
    }
}
