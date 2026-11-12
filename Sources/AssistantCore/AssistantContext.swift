import Foundation

public enum AssistantContext {
    public static let messageLimit = AssistantLimits.contextMessageDefault

    public static func recent(_ messages: [AssistantMessage], limit: Int = AssistantLimits.contextMessageDefault) -> [AssistantMessage] {
        var result = Array(messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(AssistantLimits.normalizedContextMessageCount(limit)))
        while result.first?.role == .assistant { result.removeFirst() }
        return result
    }
}

/// Tracks actual server items, including function calls and their outputs.
/// Removing older messages also removes their auxiliary tool items.
struct RealtimeConversationWindow {
    private struct Item {
        let id: String
        let type: String
        let role: String?
        var isMessage: Bool { type == "message" && ["user", "assistant"].contains(role ?? "") }
    }
    private var items: [Item] = []
    var messageCount: Int { items.filter(\.isMessage).count }

    mutating func observe(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw RealtimeClientError.invalidEvent }
        if type == "conversation.item.deleted", let id = event["item_id"] as? String {
            items.removeAll { $0.id == id }
            return
        }
        guard ["conversation.item.created", "conversation.item.added"].contains(type),
              let item = event["item"] as? [String: Any],
              let id = item["id"] as? String, !id.isEmpty,
              let itemType = item["type"] as? String,
              !items.contains(where: { $0.id == id }) else { return }
        guard id.count <= 512, items.count < 1_024 else { throw RealtimeClientError.eventTooLarge }
        let value = Item(id: id, type: itemType, role: item["role"] as? String)
        if let previous = event["previous_item_id"] as? String,
           let index = items.firstIndex(where: { $0.id == previous }) {
            items.insert(value, at: index + 1)
        } else {
            items.append(value)
        }
    }

    mutating func removeOlderItems(limit: Int = AssistantLimits.contextMessageDefault) -> [String] {
        let messages = items.indices.filter { items[$0].isMessage }
        let limit = AssistantLimits.normalizedContextMessageCount(limit)
        guard messages.count > limit else { return [] }
        var retained = Array(messages.suffix(limit))
        while let index = retained.first, items[index].role == "assistant" { retained.removeFirst() }
        guard let boundary = retained.first else { return [] }
        // System items are never part of the sliding user/assistant window.
        let removed = items.prefix(boundary).filter { $0.role != "system" }.map(\.id)
        let ids = Set(removed)
        items.removeAll { ids.contains($0.id) }
        return removed
    }
}
