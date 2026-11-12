import XCTest
@testable import ConversationRules

final class ConversationRulesTests: XCTestCase {
    func testConfigurableSilenceTimeoutAndDisabledAutomaticStop() {
        var clock = SilenceClock(now: 100, timeout: 30)
        XCTAssertFalse(clock.shouldEndSession(at: 129.9))
        XCTAssertTrue(clock.shouldEndSession(at: 130))
        clock.heardSpeech(at: 120)
        XCTAssertFalse(clock.shouldEndSession(at: 149.9))
        XCTAssertTrue(clock.shouldEndSession(at: 150))
        let disabled = SilenceClock(now: 100, timeout: 0)
        XCTAssertFalse(disabled.shouldEndSession(at: 100_000))
        let invalid = SilenceClock(now: 100, timeout: .nan)
        XCTAssertTrue(invalid.shouldEndSession(at: 105))
    }
    func testSpokenReplyKeepsWordsWithoutReadingLinksAndCitations() {
        XCTAssertEqual(ConversationRules.displayText(from: "По данным NASA. citesource"), "По данным NASA.")
        XCTAssertEqual(
            ConversationRules.spokenText(from: "По [данным NASA](https://www.nasa.gov/example), полёт состоялся. citesource"),
            "По данным NASA, полёт состоялся."
        )
        XCTAssertEqual(ConversationRules.spokenText(from: "**Привет!**"), "Привет!")
        XCTAssertEqual(ConversationRules.spokenText(from: "https://example.com"), "Ответ доступен в приложении.")
    }

    func testSpeechRemovesWebAddressesAndCitationOnlyParentheses() {
        for citation in [
            "(https://www.nasa.gov/mission?id=42)",
            "(www.nasa.gov/mission?id=42)",
            "(nasa.gov/mission?id=42)",
            "([NASA](https://www.nasa.gov/mission?id=42))",
            "(см. [NASA](https://www.nasa.gov/mission), [BBC](https://bbc.com/news))",
            "(<a href='https://www.nasa.gov/mission'>NASA</a>)",
            "([Wikipedia](https://en.wikipedia.org/wiki/Swift_(programming_language)))"
        ] {
            XCTAssertEqual(
                ConversationRules.spokenText(from: "Запуск состоялся 12.11.2026 \(citation)."),
                "Запуск состоялся 12.11.2026.",
                citation
            )
        }
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Ответ готов, www.nasa.gov/mission?id=42, продолжим."),
            "Ответ готов, продолжим."
        )
    }

    func testSpeechPreservesSemanticLinkLabelsAndParentheticalContent() {
        for text in [
            "По [данным NASA](https://www.nasa.gov/mission), запуск состоялся.",
            "По <a class='source' href='https://www.nasa.gov/mission'><strong>данным NASA</strong></a>, запуск состоялся."
        ] {
            XCTAssertEqual(ConversationRules.spokenText(from: text), "По данным NASA, запуск состоялся.")
        }
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Это эксперимент (на [Марсе](https://nasa.gov/mars)), результат важен."),
            "Это эксперимент (на Марсе), результат важен."
        )
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Запуск осуществила [NASA](https://nasa.gov)."),
            "Запуск осуществила NASA."
        )
    }

    func testSpeechRemovesStandaloneCitationLinksAndSourceSections() {
        for heading in ["Источники:", "**Ссылки:**", "## Sources", "References:"] {
            let text = """
            Запуск состоялся.

            \(heading)
            1. [NASA](https://nasa.gov/mission)
            2. bbc.com/news?id=42
            """
            XCTAssertEqual(ConversationRules.spokenText(from: text), "Запуск состоялся.", heading)
        }
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Запуск состоялся.\n[NASA](https://nasa.gov)\n<a href='https://bbc.com'>BBC</a>"),
            "Запуск состоялся."
        )
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Запуск состоялся.\nИсточники: [NASA](https://nasa.gov)"),
            "Запуск состоялся."
        )
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Запуск состоялся. [NASA](https://nasa.gov), [BBC](https://bbc.com)."),
            "Запуск состоялся."
        )
    }

    func testSpeechRetainsTheAnswerAfterASourceBlock() {
        let text = """
        Запуск состоялся.

        Sources:
        - [NASA](https://nasa.gov/mission)

        Практический вывод: эксперимент можно повторить.
        """
        XCTAssertEqual(
            ConversationRules.spokenText(from: text),
            "Запуск состоялся. Практический вывод: эксперимент можно повторить."
        )
    }

    func testSpeechRemovesNumberedReferencesOnlyInSourceContext() {
        let sourceURL = URL(string: "https://nasa.gov/mission")!
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Значение 42 [1], цена 199 ₽ [^2].", sourceURLs: [sourceURL]),
            "Значение 42, цена 199 ₽."
        )
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Обозначения [1] и [2] сохраняются."),
            "Обозначения [1] и [2] сохраняются."
        )
        let footnotes = """
        Стоимость — 1 299,50 ₽. Данные на 12.11.2026 [1][^2].

        [1]: https://nasa.gov/prices
        [^2]: www.bbc.com/news
        """
        XCTAssertEqual(
            ConversationRules.spokenText(from: footnotes),
            "Стоимость — 1 299,50 ₽. Данные на 12.11.2026."
        )
    }

    func testSpeechRemovesProviderCitationMarkers() {
        XCTAssertEqual(
            ConversationRules.spokenText(from: "Запуск состоялся.【1†NASA】 citeturn2view0"),
            "Запуск состоялся."
        )
    }

    func testSpeechKeepsOrdinarySentencesNumbersPricesDatesEmailsAndVersions() {
        let text = "Источники энергии бывают солнечными и ветровыми. Пишите на help@example.com. Версия Node.js 22.1, iOS 27.0, цена 1 299,50 ₽ на 12.11.2026."
        XCTAssertEqual(ConversationRules.spokenText(from: text), text)
        XCTAssertEqual(ConversationRules.spokenText(from: "Источники: солнечная и ветровая энергия."), "Источники: солнечная и ветровая энергия.")
        XCTAssertEqual(ConversationRules.spokenText(from: "Конфигурация app.swift, версия v1.2.3."), "Конфигурация app.swift, версия v1.2.3.")
        XCTAssertEqual(ConversationRules.spokenText(from: "<a href='mailto:help@example.com'>help@example.com</a>"), "help@example.com")
        XCTAssertEqual(ConversationRules.spokenText(from: "42"), "42")
        XCTAssertEqual(ConversationRules.spokenText(from: "199,50 ₽"), "199,50 ₽")
    }

    func testSourceOnlyAnswersHaveAShortSpokenFallbackButKeepVisibleLinks() {
        for text in [
            "https://nasa.gov",
            "<https://nasa.gov/mission?id=42>",
            "www.nasa.gov/mission?id=42",
            "nasa.gov/mission?id=42",
            "[NASA](https://nasa.gov)",
            "(<a href='https://nasa.gov'>NASA</a>)",
            "Источники:\n- [NASA](https://nasa.gov)\n- bbc.com/news"
        ] {
            XCTAssertEqual(ConversationRules.spokenText(from: text), "Ответ доступен в приложении.", text)
        }
        let visible = "По [данным NASA](https://nasa.gov), запуск состоялся."
        XCTAssertEqual(ConversationRules.displayText(from: visible), visible)
    }

    func testGreetingIgnoresCaseAndSurroundingWhitespaceAndPunctuation() {
        for transcript in ["Привет", "привет", "ПРИВЕТ", "  Привет!\n", "«Привет...»", "\t?! ПРИВЕТ !?\r\n"] {
            XCTAssertEqual(
                ConversationRules.reply(to: transcript),
                "Привет! Я твой голосовой помощник",
                transcript
            )
        }
    }

    func testOtherUtterancesUseThePlaceholderReply() {
        for transcript in ["Как дела?", "Привет помощник", "Ну привет", "при вет", "Привет! Привет!"] {
            XCTAssertEqual(
                ConversationRules.reply(to: transcript),
                "Функция общения пока не реализована",
                transcript
            )
        }
    }

    func testInitialSilenceEndsAtExactlyFiveSecondsWithoutCreatingAnUtterance() {
        let clock = SilenceClock(now: 10)
        XCTAssertFalse(clock.shouldEndSession(at: 14.999))
        XCTAssertTrue(clock.shouldEndSession(at: 15))
        XCTAssertFalse(clock.shouldFinishUtterance(at: 15))
    }

    func testSpeechResetsBothPauseAndSessionDeadlines() {
        var clock = SilenceClock(now: 0)
        clock.heardSpeech(at: 4)
        XCTAssertFalse(clock.shouldFinishUtterance(at: 4.899))
        XCTAssertTrue(clock.shouldFinishUtterance(at: 4.9))
        XCTAssertFalse(clock.shouldEndSession(at: 8.999))
        XCTAssertTrue(clock.shouldEndSession(at: 9))
    }

    func testContinuousSpeechKeepsTheSessionAlive() {
        var clock = SilenceClock(now: 0)
        for time in [4.0, 8.0, 12.0, 16.0] {
            clock.heardSpeech(at: time)
            XCTAssertFalse(clock.shouldEndSession(at: time))
        }
        XCTAssertFalse(clock.shouldEndSession(at: 20.999))
        XCTAssertTrue(clock.shouldEndSession(at: 21))
    }

    func testResumingAfterEachReplyStartsANewTurnAndExcludesSynthesisTime() {
        var clock = SilenceClock(now: 0)
        for time in [20.0, 40.0, 60.0] {
            clock.resumedListening(at: time)
            XCTAssertFalse(clock.shouldEndSession(at: time))
            XCTAssertFalse(clock.shouldFinishUtterance(at: time + 1))
            clock.heardSpeech(at: time + 1)
            XCTAssertFalse(clock.shouldFinishUtterance(at: time + 1.899))
            XCTAssertTrue(clock.shouldFinishUtterance(at: time + 1.9))
            XCTAssertTrue(clock.shouldFinishUtterance(at: time + 2))
            XCTAssertFalse(clock.shouldEndSession(at: time + 5))
        }
    }

    func testStaleSpeechDoesNotMoveTheDeadlineOrCreateANewUtterance() {
        var clock = SilenceClock(now: 10)
        clock.heardSpeech(at: 9)
        XCTAssertFalse(clock.shouldFinishUtterance(at: 11))
        XCTAssertFalse(clock.shouldEndSession(at: 14.999))
        XCTAssertTrue(clock.shouldEndSession(at: 15))

        clock.heardSpeech(at: 20)
        clock.heardSpeech(at: 15)
        XCTAssertFalse(clock.shouldFinishUtterance(at: 20.899))
        XCTAssertTrue(clock.shouldFinishUtterance(at: 21))
        XCTAssertFalse(clock.shouldEndSession(at: 24.999))
        XCTAssertTrue(clock.shouldEndSession(at: 25))
    }

    func testStaleResumeDoesNotResetCurrentUtterance() {
        var clock = SilenceClock(now: 0)
        clock.heardSpeech(at: 10)
        clock.resumedListening(at: 9)
        XCTAssertTrue(clock.shouldFinishUtterance(at: 11))
        XCTAssertFalse(clock.shouldEndSession(at: 14.999))
        XCTAssertTrue(clock.shouldEndSession(at: 15))
    }

    func testClockQueriesBeforeLastActivityDoNotExpire() {
        var clock = SilenceClock(now: 100)
        clock.heardSpeech(at: 101)
        XCTAssertFalse(clock.shouldFinishUtterance(at: 50))
        XCTAssertFalse(clock.shouldEndSession(at: 50))
    }
}
