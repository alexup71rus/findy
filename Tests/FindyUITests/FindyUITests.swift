import XCTest

final class FindyUITests: XCTestCase {
    private func launch(_ arguments: [String] = [], session: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FINDY_UI_TEST_SESSION"] = session
        app.launchArguments = ["--skip-onboarding"] + arguments
        app.launch()
        return app
    }

    func testGeneratedImageViewer() {
        let app = launch(["--seed-ui-image"])
        let image = app.buttons["Открыть изображение"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap()
        XCTAssertTrue(app.buttons["Закрыть"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.pinch(withScale: 2, velocity: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Generated image viewer zoomed"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Поделиться или сохранить"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 3) || app.buttons["Copy"].exists || app.buttons["Скопировать"].exists)
        app.terminate()
        let closing = launch(["--seed-ui-image"])
        closing.buttons["Открыть изображение"].tap()
        closing.navigationBars["Изображение"].buttons["Закрыть"].tap()
        XCTAssertTrue(closing.buttons["Открыть изображение"].waitForExistence(timeout: 3))
    }

    func testSettingsGroupsAndSilenceChoices() {
        let app = launch(["--seed-ui-provider", "--show-settings"])
        XCTAssertFalse(app.staticTexts["Для выбранного провайдера"].exists)
        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "Grouped settings"; settingsShot.lifetime = .keepAlways; add(settingsShot)
        app.buttons["system-prompt-settings"].tap()
        XCTAssertTrue(app.textViews["system-prompt-editor"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Тестовый сервис"].exists)
        let promptShot = XCTAttachment(screenshot: app.screenshot())
        promptShot.name = "Prompt without provider heading"; promptShot.lifetime = .keepAlways; add(promptShot)
        app.buttons["system-prompt-cancel"].tap()
        app.buttons["voice-settings"].tap()
        XCTAssertFalse(app.switches["Только Bluetooth-микрофон"].exists)
        app.buttons["voice-silence-timeout"].tap()
        for title in ["5 секунд", "10 секунд", "15 секунд", "30 секунд", "Не завершать автоматически"] {
            XCTAssertTrue(app.buttons[title].exists)
        }
        XCTAssertFalse(app.buttons["60 секунд"].exists)
        XCTAssertFalse(app.buttons["120 секунд"].exists)
    }

    func testWaitingMusicSelectionAndPreview() {
        let app = launch(["--show-settings"])
        app.buttons["voice-settings"].tap()
        let link = app.buttons["Музыка ожидания"]
        if !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let selection = app.buttons["waiting-music-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        selection.tap()
        app.buttons["По очереди"].tap()
        XCTAssertTrue(selection.label.contains("По очереди") || (selection.value as? String) == "По очереди")
        let preview = app.buttons["Послушать Лифт · 2"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        preview.tap()
        let stop = app.buttons["Остановить Лифт · 2"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        selection.tap()
        app.buttons["Нет"].tap()
    }

    func testProviderVoiceSelectionKeepsPreviewExplicit() {
        let app = launch(["--seed-ui-provider", "--show-settings", "--show-speech-settings"])
        let marin = app.buttons["speech.preview.provider:marin"]
        let cedar = app.buttons["speech.preview.provider:cedar"]
        XCTAssertTrue(marin.waitForExistence(timeout: 5))
        XCTAssertTrue(cedar.waitForExistence(timeout: 5))
        for button in [marin, cedar] {
            XCTAssertTrue(button.isEnabled && button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let choice = app.buttons["Голос модели Cedar"]
        XCTAssertEqual(choice.value as? String, "Не выбран")
        choice.tap()
        XCTAssertEqual(choice.value as? String, "Выбран")
        XCTAssertEqual(marin.label, "Послушать голос Marin")
        XCTAssertEqual(cedar.label, "Послушать голос Cedar")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Остановить пример голоса")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Provider voices with Cedar selected"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVoiceComposerLocksInputAndRestoresDraftAfterStopping() {
        let app = launch(["--seed-ui-provider", "--ui-preview-voice"])
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Сохранённый черновик")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let stop = app.buttons["chat-voice-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(composer.exists)
        XCTAssertFalse(app.buttons["chat-send"].exists)
        XCTAssertFalse(app.buttons["chat-microphone"].exists)
        XCTAssertTrue(stop.isEnabled && stop.isHittable)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
        let voice = app.descendants(matching: .any)["chat-voice-composer"].firstMatch
        XCTAssertEqual(voice.label, "Голосовой разговор")
        XCTAssertEqual(voice.value as? String, "Слушаю")
        XCTAssertFalse(app.staticTexts["Слушаю"].exists, "The wave describes voice state without visible status text")
        XCTAssertLessThanOrEqual(voice.frame.height, 60, "Voice stays in the existing one-line composer")
        XCTAssertLessThanOrEqual(voice.frame.maxX + 4, stop.frame.minX, "Stop floats outside the capsule")
        let historyBottom = app.scrollViews["chat-history"].frame.maxY
        XCTAssertGreaterThan(historyBottom, voice.frame.maxY, "The scroll viewport extends behind the floating voice composer")
        stop.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Сохранённый черновик")
        XCTAssertTrue(app.buttons["chat-send"].isEnabled)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        app.terminate()
        let closing = launch(["--preview-voice-stopping"])
        XCTAssertTrue(closing.buttons["chat-voice-stop"].waitForExistence(timeout: 5))
        XCTAssertFalse(closing.buttons["chat-voice-stop"].isEnabled)
        XCTAssertFalse(closing.textFields["chat-composer"].exists)
        XCTAssertFalse(closing.buttons["chat-send"].exists)
        XCTAssertFalse(closing.staticTexts["Завершаю…"].exists)
        let closingVoice = closing.descendants(matching: .any)["chat-voice-composer"].firstMatch
        XCTAssertEqual(closingVoice.value as? String, "Завершаю…")
    }

    func testStartingVoiceComposerKeepsAccessibleStateWithoutStatusText() {
        let app = launch(["--preview-voice-starting"])
        let voice = app.descendants(matching: .any)["chat-voice-composer"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertEqual(voice.label, "Голосовой разговор")
        XCTAssertEqual(voice.value as? String, "Подключаюсь…")
        XCTAssertGreaterThan(voice.frame.width, app.frame.width * 0.6, "An empty history must keep the voice composer at full chat width")
        XCTAssertFalse(app.staticTexts["Подключаюсь…"].exists)
        XCTAssertFalse(app.textFields["chat-composer"].exists)
        XCTAssertTrue(app.buttons["chat-voice-stop"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Gray wave while connecting"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testFloatingComposerHidesVoiceForDraftAndKeepsTextCancelInsideField() {
        let app = launch(["--ui-local-replies"])
        let composer = app.textFields["chat-composer"]
        let microphone = app.buttons["chat-microphone"]
        let send = app.buttons["chat-send"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertLessThan(send.frame.maxX, microphone.frame.minX)
        XCTAssertGreaterThanOrEqual(microphone.frame.width, 44)
        let emptyWidth = composer.frame.width
        composer.tap(); composer.typeText("Test")
        XCTAssertTrue(microphone.waitForNonExistence(timeout: 3))
        XCTAssertGreaterThan(composer.frame.width, emptyWidth + 20)
        XCTAssertTrue(send.isEnabled)
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(microphone.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled)
        composer.typeText("Привет")
        send.tap()
        XCTAssertEqual(send.label, "Остановить ответ")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(microphone.exists)
        XCTAssertFalse(app.buttons["chat-voice-stop"].exists)
        send.tap()
        XCTAssertEqual(send.label, "Отправить сообщение")
        XCTAssertTrue(microphone.waitForExistence(timeout: 3))
    }

    func testFirstRunOffersSetup() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Приложение не настроено"].waitForExistence(timeout: 5))
        app.buttons["chat-setup"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
    }

    func testChatHeaderLayoutAndGitHubCancel() {
        let app = launch(["--seed-ui-rich-history"])
        let logo = app.buttons["findy-github"]
        let menu = app.buttons["findy-menu"]
        let clear = app.buttons["chat-clear"]
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        XCTAssertLessThan(logo.frame.maxX, menu.frame.minX)
        XCTAssertEqual(menu.frame.midY, clear.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(clear.frame.maxX, menu.frame.minX)
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        let actions = app.descendants(matching: .any)["chat-header-actions"].firstMatch
        XCTAssertTrue(actions.exists)
        XCTAssertTrue(actions.frame.contains(clear.frame) && actions.frame.contains(menu.frame))
        clear.tap()
        XCTAssertTrue(app.alerts["Очистить чат?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Отмена"].tap()
        logo.tap()
        XCTAssertTrue(app.alerts["Вы будете перенаправлены на GitHub приложения"].waitForExistence(timeout: 3))
        app.alerts.buttons["Отмена"].tap()
        XCTAssertTrue(logo.isHittable)
        app.scrollViews["chat-history"].swipeDown()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Soft chat edges and shared header capsule"; shot.lifetime = .keepAlways; add(shot)
        menu.tap()
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Готово"].isHittable)
        app.buttons["Готово"].tap()
        XCTAssertTrue(logo.isHittable)
    }

    func testComposerOverlaysScrollingHistoryAndKeyboard() {
        let app = launch(["--seed-ui-rich-history"])
        let history = app.scrollViews["chat-history"]
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(history.frame.maxY, composer.frame.maxY)
        history.swipeDown()
        let jump = app.buttons["chat-jump-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        XCTAssertLessThan(jump.frame.maxY, composer.frame.minY)
        let scrolling = XCTAttachment(screenshot: app.screenshot())
        scrolling.name = "History underneath floating glass composer"; scrolling.lifetime = .keepAlways; add(scrolling)
        jump.tap()
        composer.tap()
        composer.typeText("Длинный черновик для проверки высоты поля ввода и отступа под последним сообщением. Он занимает несколько строк, пока клавиатура открыта.")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertGreaterThan(history.frame.maxY, composer.frame.maxY)
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "Multiline floating composer above keyboard"; keyboard.lifetime = .keepAlways; add(keyboard)
    }

    func testRichHistoryStaysInsideViewportWithKeyboardAndScrolling() {
        let app = launch(["--seed-ui-rich-history"])
        let history = app.scrollViews["chat-history"]
        let answer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ответ 79.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(answer.frame.minX, history.frame.minX + 12)
        XCTAssertLessThanOrEqual(answer.frame.maxX, history.frame.maxX + 1)
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Вопрос 80:")).firstMatch
        XCTAssertTrue(last.exists)
        let composer = app.textFields["chat-composer"]
        XCTAssertLessThanOrEqual(last.frame.maxY, composer.frame.minY, "The last row should rest above the floating composer")
        XCTAssertLessThan(composer.frame.minY - last.frame.maxY, 70, "The last row should remain near the composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(answer.frame.maxX, history.frame.maxX + 1)
        history.swipeDown(velocity: .fast)
        history.swipeDown(velocity: .fast)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Rich history with keyboard"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(history.exists)
    }

    func testStreamingDoesNotPullReaderBackToLatest() {
        let app = launch(["--seed-ui-rich-history", "--ui-local-replies"])
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Проверка прокрутки")
        app.buttons["chat-send"].tap()
        let history = app.scrollViews["chat-history"]
        history.swipeDown(velocity: .fast)
        let jump = app.buttons["chat-jump-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        sleep(3)
        XCTAssertTrue(jump.exists, "Streaming should not return the reader to the latest message")
    }

    func testDeleteSingleMessageAndClearHistoryRequireConfirmation() {
        let app = launch(["--seed-ui-delete-history"])
        let first = app.staticTexts["Сообщение 0001"]
        let second = app.staticTexts["Сообщение 0002"]
        let third = app.staticTexts["Сообщение 0003"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        second.press(forDuration: 1)
        app.buttons["Удалить"].tap()
        XCTAssertTrue(app.buttons["Удалить сообщение"].waitForExistence(timeout: 5))
        app.buttons["Отмена"].tap()
        XCTAssertTrue(second.exists)
        second.press(forDuration: 1)
        app.buttons["Удалить"].tap()
        app.buttons["Удалить сообщение"].tap()
        XCTAssertFalse(second.waitForExistence(timeout: 2))
        XCTAssertTrue(first.exists && third.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        app.buttons["chat-clear"].tap()
        XCTAssertTrue(app.alerts["Очистить чат?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Отмена"].tap()
        XCTAssertTrue(first.exists && third.exists)
        app.buttons["chat-clear"].tap()
        app.alerts.buttons["Очистить чат"].tap()
        XCTAssertFalse(first.waitForExistence(timeout: 2))
        XCTAssertFalse(third.exists)
        app.terminate(); app.launch()
        XCTAssertFalse(first.exists || third.exists)
    }

    func testHistoryPagesBeyondWindowAndReturnsToLatest() {
        let app = launch(["--seed-ui-history"])
        let history = app.scrollViews["chat-history"]
        XCTAssertTrue(app.staticTexts["Сообщение 0520"].waitForExistence(timeout: 10))
        // More than three pages must leave the 120-row in-memory window.
        for _ in 0..<24 { history.swipeDown(velocity: .fast) }
        let earlier = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Сообщение 0[0-3][0-9][0-9]")).firstMatch
        XCTAssertTrue(earlier.exists, "Scrolling should cross the three-page window")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "History older pages"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["chat-jump-latest"].tap()
        XCTAssertTrue(app.staticTexts["Сообщение 0520"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Сообщение 0520"].isHittable)
    }

    func testMessagePersistsAfterRelaunch() {
        let session = UUID().uuidString
        let app = launch(["--ui-local-replies"], session: session)
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Привет")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(app.staticTexts["Привет"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Привет"].waitForExistence(timeout: 5))
        app.terminate()
        // The first provider send must preserve the draft when consent is cancelled.
        let providerApp = launch(["--seed-ui-provider"])
        let providerComposer = providerApp.textFields["chat-composer"]
        providerComposer.tap(); providerComposer.typeText("Не отправлять")
        providerApp.buttons["chat-send"].tap()
        XCTAssertTrue(providerApp.alerts["Разрешить передачу данных?"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: providerApp.screenshot())
        screenshot.name = "Provider sharing consent"; screenshot.lifetime = .keepAlways; add(screenshot)
        providerApp.alerts.buttons["Отмена"].tap()
        XCTAssertEqual(providerComposer.value as? String, "Не отправлять")
        providerApp.buttons["chat-send"].tap()
        XCTAssertTrue(providerApp.alerts["Разрешить передачу данных?"].waitForExistence(timeout: 5))
        providerApp.alerts.buttons["Отмена"].tap()
        providerApp.terminate()
        providerApp.launchArguments += ["--show-settings", "--show-speech-settings"]
        providerApp.launch()
        let phoneMode = providerApp.segmentedControls.buttons["iPhone"]
        XCTAssertTrue(phoneMode.waitForExistence(timeout: 5))
        phoneMode.tap()
        XCTAssertTrue(providerApp.staticTexts["Автоматически"].waitForExistence(timeout: 5))
        providerApp.segmentedControls.buttons["Провайдер"].tap()
        XCTAssertTrue(providerApp.staticTexts["Голос модели"].waitForExistence(timeout: 5))
    }

    func testMemoryCreateEditDeleteAndPersistence() {
        let session = UUID().uuidString
        let app = launch(["--show-memory"], session: session)
        app.buttons["memory-add"].tap()
        let editor = app.textViews["memory-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("Люблю чай")
        app.buttons["memory-save"].tap()
        XCTAssertTrue(app.staticTexts["Люблю чай"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        let fact = app.staticTexts["Люблю чай"]
        XCTAssertTrue(fact.waitForExistence(timeout: 5))
        fact.press(forDuration: 1)
        app.buttons["Изменить"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(" с лимоном")
        app.buttons["memory-save"].tap()
        let updated = app.staticTexts["Люблю чай с лимоном"]
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        updated.press(forDuration: 1)
        app.buttons["Удалить"].tap()
        app.buttons["Удалить"].tap()
        XCTAssertTrue(app.staticTexts["Пока ничего не сохранено"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Пока ничего не сохранено"].waitForExistence(timeout: 5))
    }
}
