import Foundation

/// Shared limits for editable fields and the message-count setting.
public enum AssistantLimits {
    public static let inputCharacters = 500
    public static let systemPromptCharacters = 1500
    public static let memoryNoteCharacters = 500
    public static let memorySlots = 30
    public static let contextMessageMinimum = 5
    public static let contextMessageMaximum = 50
    public static let contextMessageStep = 5
    public static let contextMessageDefault = 15
    public static func normalizedContextMessageCount(_ value: Int) -> Int {
        let bounded = min(contextMessageMaximum, max(contextMessageMinimum, value))
        return min(contextMessageMaximum, ((bounded + contextMessageStep / 2) / contextMessageStep) * contextMessageStep)
    }

    public static func clipped(_ text: String, to limit: Int) -> String {
        String(text.prefix(max(0, limit)))
    }
}
