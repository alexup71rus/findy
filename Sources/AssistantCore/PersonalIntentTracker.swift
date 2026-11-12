import Foundation

public enum PersonalMutation: String, Codable, CaseIterable, Sendable {
    case saveMemory, removeMemory, createReminder, changeReminder
}

/// Keeps explicit authorization through a short clarification, and consumes it
/// for subsequent turns after the action really succeeds. The current turn may
/// contain several facts/reminders, so a successful call doesn't revoke sibling
/// calls from the same utterance.
public struct PersonalIntentTracker: Codable, Sendable {
    private var requestID: UUID?
    private var currentText = ""
    private var origins: [PersonalMutation: String] = [:]
    private var consumed = Set<PersonalMutation>()
    private var followupsRemaining = 0
    private var expiresAt = Date.distantPast

    // The full transcript already belongs to the messages table. It needn't be
    // copied into the small durable pending-intent state.
    private enum CodingKeys: String, CodingKey { case requestID, origins, consumed, followupsRemaining, expiresAt }

    public init() {}

    public mutating func accept(id: UUID, text: String, now: Date = Date()) {
        if requestID == id { currentText = text; return }
        for action in consumed { origins[action] = nil }
        consumed = []
        if now >= expiresAt || followupsRemaining == 0 { origins = [:] }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.range(of: #"^(?:не надо|отмена|забудь просьбу|отмени просьбу|never mind|cancel that)\b"#, options: .regularExpression) != nil {
            origins = [:]
        } else {
            var actions = Set<PersonalMutation>()
            if PersonalRequestPolicy.allowsMemorySave(text) { actions.insert(.saveMemory) }
            if PersonalRequestPolicy.allowsMemoryRemoval(text) { actions.insert(.removeMemory) }
            if PersonalRequestPolicy.allowsReminderCreation(text) { actions.insert(.createReminder) }
            if PersonalRequestPolicy.allowsReminderChange(text) { actions.insert(.changeReminder) }
            if !actions.isEmpty {
                origins = Dictionary(uniqueKeysWithValues: actions.map { ($0, String(text.prefix(2_000))) })
                followupsRemaining = 2
                expiresAt = now.addingTimeInterval(180)
            } else {
                followupsRemaining = max(0, followupsRemaining - 1)
            }
        }
        requestID = id
        currentText = text
    }

    public func request(for action: PersonalMutation, currentRequest: String, now: Date = Date()) -> String? {
        guard now < expiresAt, currentText == currentRequest, let origin = origins[action] else { return nil }
        return origin == currentRequest ? currentRequest : origin + "\nУточнение пользователя: " + currentRequest
    }

    public mutating func didComplete(_ action: PersonalMutation) { consumed.insert(action) }

    public func hasPendingRequest(now: Date = Date()) -> Bool {
        now < expiresAt && origins.keys.contains { !consumed.contains($0) }
    }
}
