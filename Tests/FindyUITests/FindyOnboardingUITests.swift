import XCTest

final class FindyOnboardingUITests: XCTestCase {
    private func launch(_ arguments: [String] = [], session: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FINDY_UI_TEST_SESSION"] = session
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGuideSkipPersistsAndLeavesSetupAvailable() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Говорите, не доставая iPhone"].waitForExistence(timeout: 5))
        capture("Guide hands-free", app: app)
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.staticTexts["Приложение не настроено"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat-setup"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Приложение не настроено"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding-skip"].exists)
    }

    func testGuideShowsShortcutsAndFinishesInSettings() {
        let app = launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 5))
        capture("Guide hands-free", app: app)
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.buttons["onboarding-shortcuts-link"].waitForExistence(timeout: 5))
        capture("Guide shortcuts", app: app)
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["Подключите свою модель"].waitForExistence(timeout: 5))
        capture("Guide provider", app: app)
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
        let shortcuts = app.buttons["findy-shortcuts-link"]
        if !shortcuts.isHittable { app.swipeUp() }
        XCTAssertTrue(shortcuts.exists)
        let guide = app.buttons["settings-guide"]
        if !guide.isHittable { app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.staticTexts["Говорите, не доставая iPhone"].waitForExistence(timeout: 5))
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
    }

    func testPromptPresetsPreserveCustomAfterSaving() {
        let app = launch(["--seed-ui-showcase", "--show-settings"])
        let row = app.buttons["system-prompt-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editor = app.textViews["system-prompt-editor"]
        let helpful = app.buttons["Полезный"]
        let custom = app.buttons["Пользовательский"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let defaultPrompt = editor.value as? String ?? ""
        XCTAssertFalse(defaultPrompt.isEmpty)
        app.buttons["system-prompt-preset"].tap()
        capture("Prompt preset choices", app: app)
        helpful.tap()
        editor.tap()
        editor.typeText(" Custom instructions")
        let customPrompt = editor.value as? String ?? ""
        XCTAssertNotEqual(customPrompt, defaultPrompt)
        capture("Prompt custom with keyboard", app: app)
        app.buttons["system-prompt-save"].tap()
        row.tap()
        app.buttons["system-prompt-preset"].tap()
        helpful.tap()
        XCTAssertEqual(editor.value as? String, defaultPrompt)
        app.buttons["system-prompt-cancel"].tap()
        row.tap()
        XCTAssertEqual(editor.value as? String, customPrompt)
        app.buttons["system-prompt-preset"].tap()
        helpful.tap()
        app.buttons["system-prompt-save"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, defaultPrompt)
        app.buttons["system-prompt-preset"].tap()
        custom.tap()
        XCTAssertEqual(editor.value as? String, customPrompt)
        capture("Custom prompt preserved after relaunch", app: app)
    }

    func testAllPromptPresetsAndCustomSurviveSwitching() {
        let app = launch(["--seed-ui-provider", "--show-settings"])
        let row = app.buttons["system-prompt-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editor = app.textViews["system-prompt-editor"]
        let menu = app.buttons["system-prompt-preset"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let helpfulText = editor.value as? String ?? ""
        menu.tap()
        app.buttons["Циничный"].tap()
        let cynicalText = editor.value as? String ?? ""
        XCTAssertNotEqual(cynicalText, helpfulText)
        menu.tap()
        app.buttons["Мотивирующий"].tap()
        let motivatingText = editor.value as? String ?? ""
        XCTAssertNotEqual(motivatingText, helpfulText)
        XCTAssertNotEqual(motivatingText, cynicalText)
        menu.tap()
        app.buttons["Пользовательский"].tap()
        XCTAssertTrue((editor.value as? String ?? "").isEmpty)
        editor.tap()
        editor.typeText("Custom saved")
        app.buttons["system-prompt-save"].tap()
        row.tap()
        menu.tap()
        app.buttons["Циничный"].tap()
        app.buttons["system-prompt-save"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, cynicalText)
        menu.tap()
        app.buttons["Пользовательский"].tap()
        XCTAssertEqual(editor.value as? String, "Custom saved")
        editor.tap()
        editor.typeText(" discarded")
        app.buttons["system-prompt-cancel"].tap()
        row.tap()
        XCTAssertEqual(editor.value as? String, cynicalText)
        menu.tap()
        app.buttons["Пользовательский"].tap()
        XCTAssertEqual(editor.value as? String, "Custom saved")
    }

    func testEmptyCustomPresetRoundTripsAndCancelDiscardsChanges() {
        let app = launch(["--seed-ui-provider", "--show-settings"])
        let row = app.buttons["system-prompt-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editor = app.textViews["system-prompt-editor"]
        let helpful = app.buttons["Полезный"]
        let custom = app.buttons["Пользовательский"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["system-prompt-preset"].tap()
        custom.tap()
        XCTAssertTrue((editor.value as? String ?? "").isEmpty)
        editor.tap()
        editor.typeText("My custom instructions")
        app.buttons["system-prompt-save"].tap()
        row.tap()
        app.buttons["system-prompt-preset"].tap()
        helpful.tap()
        app.buttons["system-prompt-save"].tap()
        row.tap()
        app.buttons["system-prompt-preset"].tap()
        custom.tap()
        XCTAssertEqual(editor.value as? String, "My custom instructions")
        editor.tap()
        editor.typeText(" discarded")
        app.buttons["system-prompt-cancel"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["system-prompt-preset"].tap()
        custom.tap()
        XCTAssertEqual(editor.value as? String, "My custom instructions")
    }

    func testPromptSaveCancelAndRelaunchPreserveExactText() {
        let app = launch(["--seed-ui-provider", "--show-settings"])
        XCTAssertFalse(app.buttons["onboarding-skip"].exists)
        let row = app.buttons["system-prompt-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editor = app.textViews["system-prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let original = editor.value as? String ?? ""
        editor.tap()
        editor.typeText(" Cancelled edit")
        capture("Prompt keyboard and native controls", app: app)
        app.buttons["system-prompt-cancel"].tap()
        row.tap()
        XCTAssertEqual(editor.value as? String, original)
        editor.tap()
        editor.typeText(" Saved edit")
        let saved = editor.value as? String ?? ""
        app.buttons["system-prompt-save"].tap()
        row.tap()
        XCTAssertEqual(editor.value as? String, saved)
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, saved)
        capture("Prompt restored after relaunch", app: app)
    }
}
