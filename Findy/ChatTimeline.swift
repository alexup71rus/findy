import Combine
import Foundation

/// One durable transcript. At most three pages are retained in UI memory;
/// model context is queried separately and never depends on scroll position.
@MainActor
final class ChatTimeline: ObservableObject {
    static let shared = ChatTimeline()
    static let pageSize = 40
    static let windowLimit = 120

    @Published private(set) var records: [StoredMessage] = []
    @Published private(set) var hasOlder = false
    @Published private(set) var hasNewer = false
    @Published private(set) var isLoading = false
    @Published private(set) var totalCount: Int64 = 0
    @Published private(set) var lastError: String?
    private var latestSequence: Int64?
    private var oldestSequence: Int64?
    private var followingLatest = true
    var messages: [AssistantMessage] { records.map(\.message).filter { !$0.text.isEmpty } }
    var isAtLatest: Bool { !hasNewer }

    private init() {
        loadLatest()
        do { try ChatAttachments.reconcile(store: PersonalData.shared.requireStore()) }
        catch { lastError = error.localizedDescription }
    }

    func loadLatest() {
        do {
            let store = try PersonalData.shared.requireStore()
            records = try store.latest(limit: Self.pageSize)
            followingLatest = true
            try refreshBounds(store)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func mediaDidChange() { objectWillChange.send() }

    func setFollowingLatest(_ allowed: Bool) { followingLatest = allowed }

    @discardableResult
    func loadOlder() -> UUID? {
        guard !isLoading, hasOlder, let first = records.first else { return nil }
        let anchor = messages.first?.id
        followingLatest = false
        isLoading = true
        defer { isLoading = false }
        do {
            let store = try PersonalData.shared.requireStore()
            let page = try store.before(sequence: first.sequence, limit: Self.pageSize)
            records = Array((page + records).prefix(Self.windowLimit))
            try refreshBounds(store)
            lastError = nil
        } catch { lastError = error.localizedDescription }
        return anchor
    }

    @discardableResult
    func loadNewer() -> UUID? {
        guard !isLoading, hasNewer, let last = records.last else { return nil }
        let anchor = messages.last?.id
        isLoading = true
        defer { isLoading = false }
        do {
            let store = try PersonalData.shared.requireStore()
            let page = try store.after(sequence: last.sequence, limit: Self.pageSize)
            records = Array((records + page).suffix(Self.windowLimit))
            try refreshBounds(store)
            lastError = nil
        } catch { lastError = error.localizedDescription }
        return anchor
    }

    @discardableResult
    func accept(_ message: AssistantMessage, scope: String) throws -> StoredMessage {
        let store = try PersonalData.shared.requireStore()
        let followTail = isAtLatest && followingLatest
        if !message.attachments.isEmpty {
            try ChatAttachments.persist(message.attachments, messageID: message.id, store: store)
        }
        let saved: StoredMessage
        do { saved = try store.upsertMessage(message, scope: scope) }
        catch {
            if !message.attachments.isEmpty { try? ChatAttachments.discard(messageID: message.id, store: store) }
            throw error
        }
        if let index = records.firstIndex(where: { $0.id == saved.id }) {
            records[index] = saved
        } else if followTail {
            records.append(saved)
            records.sort { $0.sequence < $1.sequence }
            records = Array(records.suffix(Self.windowLimit))
        }
        try refreshBounds(store)
        lastError = nil
        return saved
    }

    func context(scope: String, limit: Int = AssistantLimits.contextMessageDefault, includeAttachments: Bool = true) throws -> [AssistantMessage] {
        let store = try PersonalData.shared.requireStore()
        let rows = try store.recentContext(scope: scope, limit: AssistantLimits.normalizedContextMessageCount(limit))
        let selected = AssistantContext.recent(rows.map(\.message), limit: limit)
        guard includeAttachments else { return selected }
        var bytes = 0
        var textCharacters = 0
        return try selected.map { message in
            let hydrated = try ChatAttachments.hydrate(message, store: store)
            bytes += hydrated.attachments.reduce(0) { $0 + $1.data.count }
            guard bytes <= ChatAttachments.maximumContextBytes else { throw ChatAttachmentError.contextTooLarge }
            for item in hydrated.attachments where item.mimeType == "text/plain" {
                guard let text = String(data: item.data, encoding: .utf8) else { throw ChatAttachmentError.invalidText }
                textCharacters += text.count
            }
            guard textCharacters <= ChatAttachments.maximumContextTextCharacters else { throw ChatAttachmentError.contextTextTooLarge }
            return hydrated
        }
    }

    func resetContext(scope: String) throws {
        _ = try PersonalData.shared.requireStore().resetContext(scope: scope)
    }

    func deleteHistory() throws {
        let store = try PersonalData.shared.requireStore()
        try store.clearHistory()
        var cleanupError: Error?
        do { try GeneratedImages.removeAllFiles(store: store) } catch { cleanupError = error }
        do { try ChatAttachments.removeAllFiles(store: store) } catch { if cleanupError == nil { cleanupError = error } }
        AssistantToolExecutor.clearAllIntents()
        loadLatest()
        if let cleanupError { throw cleanupError }
    }

    func deleteMessage(id: UUID) throws {
        let store = try PersonalData.shared.requireStore()
        let sequence = records.first(where: { $0.id == id })?.sequence
        let imageURL = GeneratedImages.url(for: id)
        let attachments = try ChatAttachments.descriptors(for: id, store: store)
        try store.deleteMessage(id: id)
        var cleanupError: Error?
        do { try ChatAttachments.removeFiles(attachments, store: store) } catch { cleanupError = error }
        if let imageURL, FileManager.default.fileExists(atPath: imageURL.path) {
            do { try FileManager.default.removeItem(at: imageURL) } catch { if cleanupError == nil { cleanupError = error } }
        }
        AssistantToolExecutor.clearAllIntents()
        records.removeAll { $0.id == id }
        if records.isEmpty, let sequence {
            let previous = try store.before(sequence: sequence, limit: Self.pageSize)
            records = previous.isEmpty ? try store.after(sequence: sequence, limit: Self.pageSize) : previous
        }
        try refreshBounds(store)
        lastError = nil
        if let cleanupError { throw cleanupError }
    }

    private func refreshBounds(_ store: LocalDataStore) throws {
        totalCount = try store.totalCount()
        latestSequence = try store.newestCursor()
        oldestSequence = try store.oldestCursor()
        hasOlder = records.first.map { $0.sequence > (oldestSequence ?? $0.sequence) } ?? false
        hasNewer = records.last.map { $0.sequence < (latestSequence ?? $0.sequence) } ?? false
    }
}
