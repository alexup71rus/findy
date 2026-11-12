import Foundation
import XCTest
@testable import AssistantCore

final class RealtimeContextWindowTests: XCTestCase {
    private func created(_ id: String, type: String = "message", role: String? = nil,
                         previous: String? = nil, event: String = "conversation.item.created") throws -> Data {
        var item: [String: Any] = ["id": id, "type": type]
        if let role { item["role"] = role }
        var object: [String: Any] = ["type": event, "item": item]
        if let previous { object["previous_item_id"] = previous }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func deleted(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "conversation.item.deleted", "item_id": id])
    }

    func testBootstrapSelectsTheLatestFourteenMessagesAndRetainsTheirIdentities() {
        let history = (0..<30).map { index in
            AssistantMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Message \(index)")
        }
        let result = AssistantContext.recent(history)
        XCTAssertEqual(result.map(\.id), Array(history.suffix(14)).map(\.id))
        XCTAssertEqual(result.first?.role, .user)
        XCTAssertEqual(result.count, 14)
    }

    func testBootstrapFiltersEmptyMessagesBeforeLimitingAndDropsLeadingAssistant() {
        let old = AssistantMessage(role: .user, text: "Old question")
        let answer = AssistantMessage(role: .assistant, text: "Old answer")
        let history = [old, answer] + (0..<13).map { index in
            AssistantMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Current \(index)")
        } + [AssistantMessage(role: .user, text: " \n\t")]
        let result = AssistantContext.recent(history)
        XCTAssertEqual(result.map(\.id), Array(history.dropLast()).map(\.id))
        XCTAssertEqual(result.count, 15)
        XCTAssertEqual(result.first?.role, .user)
        XCTAssertTrue(AssistantContext.recent([AssistantMessage(role: .assistant, text: "Orphan answer")]).isEmpty)
    }

    func testConfiguredWindowKeepsLongHistory() throws {
        var window = RealtimeConversationWindow()
        for index in 0..<20 {
            try window.observe(created("configured-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant"))
        }
        _ = window.removeOlderItems(limit: 5)
        XCTAssertEqual(window.messageCount, 4)
        let current = AssistantMessage(role: .user, text: "Привет 👨‍👩‍👧‍👦")
        let long = AssistantMessage(role: .assistant, text: String(repeating: "д", count: 10_000))
        let old = AssistantMessage(role: .user, text: "старое")
        XCTAssertEqual(AssistantContext.recent([old, long, current], limit: 5), [old, long, current])
        XCTAssertEqual(AssistantLimits.clipped("а👨‍👩‍👧‍👦б", to: 2), "а👨‍👩‍👧‍👦")
        XCTAssertEqual(AssistantLimits.normalizedContextMessageCount(52), 50)
        XCTAssertEqual(AssistantLimits.normalizedContextMessageCount(8), 10)
    }

    func testFiftyMessagesWithToolItemsRemainWithinTheTrackingWindow() throws {
        var window = RealtimeConversationWindow()
        var previous: String?
        for turn in 0..<25 {
            let user = "user-\(turn)"
            try window.observe(created(user, role: "user", previous: previous))
            previous = user
            for call in 0..<6 {
                let function = "call-\(turn)-\(call)"
                let output = "output-\(turn)-\(call)"
                try window.observe(created(function, type: "function_call", previous: previous))
                try window.observe(created(output, type: "function_call_output", previous: function))
                previous = output
            }
            let answer = "answer-\(turn)"
            try window.observe(created(answer, role: "assistant", previous: previous))
            previous = answer
        }
        XCTAssertEqual(window.messageCount, 50)
        XCTAssertTrue(window.removeOlderItems(limit: 50).isEmpty)
        try window.observe(created("user-25", role: "user", previous: previous))
        let removed = window.removeOlderItems(limit: 50)
        XCTAssertEqual(window.messageCount, 49)
        XCTAssertTrue(removed.contains("user-0"))
        XCTAssertTrue(removed.contains("output-0-5"))
        XCTAssertTrue(removed.contains("answer-0"))
        try window.observe(created("answer-25", role: "assistant", previous: "user-25"))
        XCTAssertEqual(window.messageCount, 50)
        XCTAssertTrue(window.removeOlderItems(limit: 50).isEmpty)
    }

    func testCreatedAndAddedEventsForTheSameItemAreIdempotent() throws {
        var window = RealtimeConversationWindow()
        try window.observe(created("user-1", role: "user"))
        try window.observe(created("user-1", role: "user", event: "conversation.item.added"))
        try window.observe(created("assistant-1", role: "assistant", previous: "user-1"))
        try window.observe(created("assistant-1", role: "assistant", previous: "user-1", event: "conversation.item.added"))
        XCTAssertEqual(window.messageCount, 2)
        XCTAssertTrue(window.removeOlderItems().isEmpty)
    }

    func testSlidingWindowDeletesOldMessageToolPairsAndPreservesSystemInstructions() throws {
        var window = RealtimeConversationWindow()
        try window.observe(created("system", role: "system"))
        var previous = "system"
        for turn in 0..<10 {
            let user = "user-\(turn)"
            let function = "function-\(turn)"
            let output = "result-\(turn)"
            let assistant = "assistant-\(turn)"
            try window.observe(created(user, role: "user", previous: previous))
            try window.observe(created(function, type: "function_call", previous: user))
            try window.observe(created(output, type: "function_call_output", previous: function))
            try window.observe(created(assistant, role: "assistant", previous: output))
            previous = assistant
        }
        XCTAssertEqual(window.messageCount, 20)
        let removed = Set(window.removeOlderItems())
        let expected = Set((0..<3).flatMap { ["user-\($0)", "function-\($0)", "result-\($0)", "assistant-\($0)"] })
        XCTAssertEqual(removed, expected)
        XCTAssertFalse(removed.contains("system"))
        XCTAssertEqual(window.messageCount, 14)
        XCTAssertTrue(window.removeOlderItems().isEmpty)
    }

    func testPruningSkipsALeadingAssistantEvenWhenThatLeavesThirteenMessages() throws {
        var window = RealtimeConversationWindow()
        for index in 0..<21 {
            try window.observe(created("item-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant"))
        }
        let removed = window.removeOlderItems()
        XCTAssertEqual(removed, (0..<6).map { "item-\($0)" })
        XCTAssertEqual(window.messageCount, 15)
    }

    func testLateDeletionAcknowledgementsDoNotDeleteFreshContextItems() throws {
        var window = RealtimeConversationWindow()
        for index in 0..<20 {
            try window.observe(created("item-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant"))
        }
        let removed = window.removeOlderItems()
        XCTAssertEqual(window.messageCount, 14)
        try window.observe(created("fresh-user", role: "user", previous: "item-19"))
        for id in removed { try window.observe(deleted(id)) }
        XCTAssertEqual(window.messageCount, 15)
        let nextRemoval = window.removeOlderItems()
        XCTAssertTrue(nextRemoval.isEmpty)
        XCTAssertEqual(window.messageCount, 15)
        try window.observe(deleted("fresh-user"))
        XCTAssertEqual(window.messageCount, 14)
    }

    func testObservedServerOrderingUsesPreviousItemInsteadOfArrivalOrder() throws {
        var window = RealtimeConversationWindow()
        try window.observe(created("system", role: "system"))
        for index in 0..<20 {
            let previous = index == 0 ? "system" : "item-\(index - 1)"
            try window.observe(created("item-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", previous: previous))
        }
        // A server event may refer to an insertion before newer items that the
        // client has already observed. Its tool item belongs to the old turn.
        try window.observe(created("late-old-tool", type: "function_call_output", previous: "item-3"))
        let removed = window.removeOlderItems()
        XCTAssertTrue(removed.contains("late-old-tool"))
        XCTAssertFalse(removed.contains("system"))
        XCTAssertLessThanOrEqual(window.messageCount, 14)
    }
}
