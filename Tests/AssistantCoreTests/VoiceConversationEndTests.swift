import XCTest
@testable import AssistantCore

final class VoiceConversationEndTests: XCTestCase {
    private func call(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["source_quote": text]), as: UTF8.self)
    }
    func testGroundedEndingAndAmbiguousSpeech() throws {
        for value in ["Пока", "До свидания!", "Спокойной ночи", "Спасибо, это всё на сегодня", "На сегодня всё, спасибо", "Мне пора, давай закончим"] {
            XCTAssertTrue(VoiceConversationEnd.allowsCall(arguments: try call(value), latestUtterance: value), value)
        }
        for value in ["Спасибо", "Пока не надо", "расскажи как сказать пока по-английски", "ты сказал пока", "Пока, и напомни завтра о встрече", "Спокойной ночи, но у меня ещё вопрос", "Пока, какая погода?", "До свидания, как погода", "Скажи «пока»", "Don't end the conversation"] {
            XCTAssertFalse(VoiceConversationEnd.allowsCall(arguments: try call(value), latestUtterance: value), value)
        }
        XCTAssertFalse(VoiceConversationEnd.allowsCall(arguments: try call("Пока"), latestUtterance: "Пока не надо"))
        XCTAssertFalse(VoiceConversationEnd.allowsCall(arguments: "{}", latestUtterance: "Пока"))
    }
    func testStandaloneFallbackDoesNotMatchPartialGoodbyes() {
        for value in ["Пока!", "До свидания", "Спокойной ночи."] { XCTAssertTrue(VoiceConversationEnd.isStandaloneFarewell(value)) }
        for value in ["Пока не надо", "Пока, напомни завтра", "Спасибо", "Как сказать пока", "Спокойной ночи?", ""] { XCTAssertFalse(VoiceConversationEnd.isStandaloneFarewell(value)) }
    }
    func testFarewellRecognitionAvoidsNegationsAndSubstringMatches() {
        for text in ["До свидания!", "Спокойной ночи, до встречи.", "Пока!"] { XCTAssertTrue(VoiceConversationEnd.containsFarewell(text)) }
        for text in ["Покажу вам ответ", "Пока не надо", "Ты сказал пока", "Скажи «пока»", "Пока, какой ответ?"] { XCTAssertFalse(VoiceConversationEnd.containsFarewell(text)) }
    }
    func testFarewellRetryWaitsForNewResponseAndIsCancelledBySpeech() {
        var state = VoiceEndState()
        state.request(preservingCurrentResponse: true)
        state.responseCompleted(success: true, hasToolCalls: false)
        XCTAssertTrue(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.request() // One new response is requested in the existing voice session.
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.responseCompleted(success: true, hasToolCalls: false)
        XCTAssertFalse(state.shouldEnd(isPlaying: true, userSpeaking: false, responseActive: false))
        state.reset() // New speech invalidates the request, even if old audio drains later.
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
    }
    func testPendingRequiresFinalSuccessfulResponseAndDrainedAudio() {
        var state = VoiceEndState()
        state.request()
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.responseCompleted(success: true, hasToolCalls: true)
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.responseCompleted(success: true, hasToolCalls: false)
        XCTAssertFalse(state.shouldEnd(isPlaying: true, userSpeaking: false, responseActive: false))
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: true, responseActive: false))
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: true))
        XCTAssertTrue(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.reset()
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.request(); state.responseCompleted(success: false, hasToolCalls: false)
        XCTAssertFalse(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        // Transcript can finalize after the answer audio has already drained.
        state.responseCompleted(success: true, hasToolCalls: false)
        state.request(preservingCurrentResponse: true)
        XCTAssertTrue(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
        state.reset(); state.request(); state.responseCompleted(success: true, hasToolCalls: false)
        XCTAssertTrue(state.shouldEnd(isPlaying: false, userSpeaking: false, responseActive: false))
    }
}
