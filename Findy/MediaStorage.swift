import Foundation
import SwiftUI

/// On-device copies only. Message text and storage outside Findy are untouched.
@MainActor
final class MediaStorage: ObservableObject {
    static let shared = MediaStorage()
    static let preferenceKey = "mediaRetentionDays"
    static let choices = [0, 7, 30, 60, 90]
    @Published private(set) var lastError: String?
    @Published private(set) var revision = 0
    struct Summary { let count: Int; let bytes: Int64; let hasEntries: Bool }
    private struct Plan { var updates: [String: Data] = [:]; var files = Set<URL>(); var protected = Set<URL>() }

    private init() {}

    func summary(store: LocalDataStore) throws -> Summary {
        let plan = try prepare(store: store, cutoff: nil)
        var bytes: Int64 = 0
        var count = 0
        for url in plan.files {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true {
                count += 1
                bytes += Int64(size.fileSize ?? 0)
            }
        }
        return Summary(count: count, bytes: bytes, hasEntries: !plan.updates.isEmpty || count > 0)
    }

    @discardableResult
    func clean(store: LocalDataStore, cutoff: Date?) throws -> Int {
        let plan = try prepare(store: store, cutoff: cutoff)
        // Commit removed markers first, so deleted files are never re-sent and
        // a crash cannot leave an apparently live reference to a missing file.
        try store.updateMediaStates(plan.updates)
        if !plan.updates.isEmpty || !plan.files.isEmpty { revision += 1 }
        var firstError: Error?
        var removed = 0
        for url in plan.files.subtracting(plan.protected) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url); removed += 1 }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        lastError = nil
        return removed
    }

    func runAutomaticIfIdle(now: Date = Date()) {
        let days = UserDefaults.standard.integer(forKey: Self.preferenceKey)
        guard Self.choices.contains(days), days > 0 else { return }
        let session = VoiceSession.shared
        guard !session.isRunning, !session.isSendingText, session.phase == .idle else { return }
        do {
            let store = try PersonalData.shared.requireStore()
            _ = try clean(store: store, cutoff: now.addingTimeInterval(-Double(days) * 86_400))
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private func prepare(store: LocalDataStore, cutoff: Date?) throws -> Plan {
        var result = Plan()
        for state in try store.mediaStates() {
            let selected = cutoff.map { state.createdAt <= $0 } ?? true
            if state.key.hasPrefix("attachment.") {
                var entries: [StoredChatAttachment]
                do { entries = try JSONDecoder().decode([StoredChatAttachment].self, from: state.value) }
                catch { throw ChatAttachmentError.unavailable }
                guard entries.count <= ChatAttachments.maximumCount, entries.allSatisfy(ChatAttachments.validated) else { throw ChatAttachmentError.unavailable }
                var changed = false
                for index in entries.indices {
                    let url = ChatAttachments.folder(store).appendingPathComponent(entries[index].fileName)
                    if entries[index].isRemoved { result.files.insert(url) }
                    else if selected { entries[index].removed = true; result.files.insert(url); changed = true }
                    else { result.protected.insert(url) }
                }
                if changed { result.updates[state.key] = try JSONEncoder().encode(entries) }
            } else {
                guard let name = String(data: state.value, encoding: .utf8) else { throw ChatAttachmentError.unavailable }
                let expected = state.messageID.uuidString.lowercased() + ".png"
                guard name == "removed" || name == expected else { throw ChatAttachmentError.unavailable }
                let url = GeneratedImages.directory(for: store).appendingPathComponent(expected)
                if name == "removed" { result.files.insert(url); continue }
                if selected { result.updates[state.key] = Data("removed".utf8); result.files.insert(url) }
                else { result.protected.insert(url) }
            }
        }
        return result
    }
}

/// Instantiated when the app view is built, after DEBUG fixtures select their database.
@MainActor
struct MediaRetentionLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var session = VoiceSession.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: session.isSendingText) { _, busy in
                if !busy && scenePhase == .active { MediaStorage.shared.runAutomaticIfIdle() }
            }
            .onChange(of: session.isRunning) { _, busy in
                if !busy && scenePhase == .active { MediaStorage.shared.runAutomaticIfIdle() }
            }
            .onChange(of: session.phase) { _, phase in
                if phase == .idle && scenePhase == .active { MediaStorage.shared.runAutomaticIfIdle() }
            }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
extension MediaStorage {
    func runSmokeIfRequested() {
        guard ProcessInfo.processInfo.environment["FINDY_MEDIA_CLEANUP_SMOKE"] == "1" else { return }
        let output = URL.documentsDirectory.appending(path: "media-cleanup-smoke.txt")
        let root = URL.temporaryDirectory.appending(path: "FindyMediaTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try LocalDataStore(databaseURL: root.appending(path: "db.sqlite"))
            let now = Date()
            let oldTime = now.addingTimeInterval(-40 * 86_400)
            let newTime = now.addingTimeInterval(-86_400)
            let old = AssistantMessage(role: .user, text: "Старый текст")
            let recent = AssistantMessage(role: .user, text: "Новый текст")
            let oldImage = AssistantMessage(role: .assistant, text: "Изображение готово.")
            let newImage = AssistantMessage(role: .assistant, text: "Новое изображение.")
            _ = try store.upsertMessage(old, scope: "test", createdAt: oldTime)
            _ = try store.upsertMessage(recent, scope: "test", createdAt: newTime)
            _ = try store.upsertMessage(oldImage, scope: "test", createdAt: oldTime)
            _ = try store.upsertMessage(newImage, scope: "test", createdAt: newTime)
            let memory = try store.upsertMemory(MemoryFact(text: "Память остаётся"))
            let reminder = try store.upsertReminder(LocalReminder(title: "Напоминание остаётся", dueAt: now))
            let unique = AssistantAttachment(name: "old.txt", mimeType: "text/plain", data: Data("старый файл".utf8))
            let shared = AssistantAttachment(name: "shared.txt", mimeType: "text/plain", data: Data("общий файл".utf8))
            try ChatAttachments.persist([unique, shared], messageID: old.id, store: store)
            let descriptors = try ChatAttachments.descriptors(for: old.id, store: store)
            try store.setLocalState(JSONEncoder().encode([descriptors[1]]), for: "attachment." + recent.id.uuidString.lowercased())
            let genFolder = GeneratedImages.directory(for: store)
            try FileManager.default.createDirectory(at: genFolder, withIntermediateDirectories: true)
            for msg in [oldImage, newImage] {
                let name = msg.id.uuidString.lowercased() + ".png"
                try Data("image".utf8).write(to: genFolder.appendingPathComponent(name))
                try store.setLocalState(Data(name.utf8), for: "image." + msg.id.uuidString.lowercased())
            }
            let original = root.appending(path: "original-in-files.txt")
            try Data("original".utf8).write(to: original)
            let invalidKey = "attachment." + UUID().uuidString.lowercased()
            let invalidMessage = AssistantMessage(id: UUID(uuidString: String(invalidKey.dropFirst("attachment.".count)))!, role: .user, text: "invalid")
            _ = try store.upsertMessage(invalidMessage, scope: "test", createdAt: oldTime)
            try store.setLocalState(Data("invalid".utf8), for: invalidKey)
            var refusedCorruptManifest = false
            do { _ = try clean(store: store, cutoff: now.addingTimeInterval(-30 * 86_400)) }
            catch ChatAttachmentError.unavailable { refusedCorruptManifest = true }
            guard refusedCorruptManifest else { throw ChatAttachmentError.unavailable }
            guard FileManager.default.fileExists(atPath: ChatAttachments.folder(store).appendingPathComponent(descriptors[0].fileName).path) else { throw ChatAttachmentError.unavailable }
            try store.deleteMessage(id: invalidMessage.id)
            let removed = try clean(store: store, cutoff: now.addingTimeInterval(-30 * 86_400))
            guard removed == 2,
                  try ChatAttachments.descriptors(for: old.id, store: store).allSatisfy(\.isRemoved),
                  try ChatAttachments.descriptors(for: recent.id, store: store).first?.isRemoved == false,
                  FileManager.default.fileExists(atPath: ChatAttachments.folder(store).appendingPathComponent(descriptors[1].fileName).path),
                  try ChatAttachments.hydrate(old, store: store).attachments.isEmpty,
                  try ChatAttachments.hydrate(recent, store: store).attachments.count == 1,
                  try store.localState(for: "image." + oldImage.id.uuidString.lowercased()) == Data("removed".utf8),
                  try store.getMemory(id: memory.id) != nil, try store.getReminder(id: reminder.id) != nil,
                  try store.getMessage(id: old.id)?.message.text == "Старый текст" else { throw ChatAttachmentError.unavailable }
            guard try clean(store: store, cutoff: nil) == 2,
                  FileManager.default.fileExists(atPath: original.path),
                  try ChatAttachments.hydrate(recent, store: store).attachments.isEmpty,
                  try store.localState(for: "image." + newImage.id.uuidString.lowercased()) == Data("removed".utf8) else { throw ChatAttachmentError.unavailable }
            // Simulate a failed file delete after tombstoning: later runs retry it.
            let leftover = ChatAttachments.folder(store).appendingPathComponent(descriptors[0].fileName)
            try Data("leftover".utf8).write(to: leftover)
            guard try clean(store: store, cutoff: now.addingTimeInterval(-90 * 86_400)) == 1,
                  !FileManager.default.fileExists(atPath: leftover.path) else { throw ChatAttachmentError.unavailable }
            try "PASS age cutoff, shared file, corrupt manifest, tombstone retry, manual cleanup, preserved history/memory/reminders/original".write(to: output, atomically: true, encoding: .utf8)
        } catch { try? "FAIL \(error)".write(to: output, atomically: true, encoding: .utf8) }
    }
}
#endif
