import Foundation
import UIKit
import ImageIO
import PDFKit

struct StoredChatAttachment: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let mimeType: String
    let fileName: String
    var removed: Bool? = nil
    var isRemoved: Bool { removed == true }
}

enum ChatAttachmentError: Error, LocalizedError {
    case tooMany, tooLarge, invalidImage, invalidText, unsupported, unavailable, contextTooLarge, contextTextTooLarge
    var errorDescription: String? {
        switch self {
        case .tooMany: return "Можно прикрепить не больше трёх файлов к одному сообщению."
        case .tooLarge: return "Файл слишком большой. Изображение — до 2 МБ после обработки, текст — до 5 МБ и 20 000 символов."
        case .invalidImage: return "Не удалось прочитать изображение."
        case .invalidText: return "Не удалось прочитать текст файла. Поддерживаются UTF-8 и UTF-16."
        case .unsupported: return "Этот формат файла пока не поддерживается. Выберите изображение или текстовый файл."
        case .unavailable: return "Вложение недоступно на устройстве. Удалите сообщение или восстановите файл."
        case .contextTooLarge: return "Вложения в выбранной истории слишком велики для одного запроса. Начните новый разговор или удалите лишние сообщения."
        case .contextTextTooLarge: return "Общий текст файлов в истории превышает 60 000 символов. Начните новый разговор или удалите лишние сообщения."
        }
    }
}

@MainActor
enum ChatAttachments {
    static let maximumCount = 3
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumTextCharacters = 20_000
    static let maximumContextBytes = 10 * 1024 * 1024
    static let maximumContextTextCharacters = 60_000
    nonisolated private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml", "log", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "sh", "sql", "rb", "go", "rs", "java", "c", "h", "cpp", "kt"]
    static func folder(_ store: LocalDataStore) -> URL { store.databaseURL.deletingLastPathComponent().appendingPathComponent("ChatAttachments", isDirectory: true) }
    private static func key(_ id: UUID) -> String { "attachment." + id.uuidString.lowercased() }

    nonisolated static func importImage(data: Data, name: String) throws -> AssistantAttachment {
        guard data.count <= 30 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { throw ChatAttachmentError.invalidImage }
        let ui = UIImage(cgImage: image)
        for quality in [0.85, 0.72, 0.58, 0.45, 0.3] {
            if let bytes = ui.jpegData(compressionQuality: quality), bytes.count <= maximumBytes {
                return AssistantAttachment(name: safeName(name), mimeType: "image/jpeg", data: bytes)
            }
        }
        throw ChatAttachmentError.tooLarge
    }

    nonisolated static func importFile(url: URL) throws -> AssistantAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ChatAttachmentError.unsupported }
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(ext)
        let limit = isImage ? 30 * 1024 * 1024 : 5 * 1024 * 1024
        guard (values.fileSize ?? 0) <= limit else { throw ChatAttachmentError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit else { throw ChatAttachmentError.tooLarge }
        if isImage { return try importImage(data: data, name: url.lastPathComponent) }
        let value: String
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, let text = pdf.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatAttachmentError.invalidText }
            value = text
        } else if ext == "rtf" {
            guard let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string else { throw ChatAttachmentError.invalidText }
            value = text
        } else {
            guard textExtensions.contains(ext) else { throw ChatAttachmentError.unsupported }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { value = text }
            else if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value == 0 }) { value = text }
            else { throw ChatAttachmentError.invalidText }
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatAttachmentError.invalidText }
        guard value.count <= maximumTextCharacters, let bytes = value.data(using: .utf8), bytes.count <= maximumBytes else { throw ChatAttachmentError.tooLarge }
        return AssistantAttachment(name: safeName(url.lastPathComponent), mimeType: "text/plain", data: bytes)
    }

    nonisolated private static func safeName(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String((cleaned.isEmpty ? "Вложение" : cleaned).prefix(100))
    }
    static func validated(_ descriptor: StoredChatAttachment) -> Bool {
        descriptor.fileName == descriptor.id.uuidString.lowercased() + ".blob" && ["image/jpeg", "image/png", "text/plain"].contains(descriptor.mimeType)
    }
    static func list(for messageID: UUID) -> [StoredChatAttachment] {
        guard let store = try? PersonalData.shared.requireStore() else { return [] }
        return (try? descriptors(for: messageID, store: store)) ?? []
    }
    static func url(for descriptor: StoredChatAttachment) -> URL? {
        guard validated(descriptor), let store = try? PersonalData.shared.requireStore() else { return nil }
        return folder(store).appendingPathComponent(descriptor.fileName)
    }
    static func descriptors(for id: UUID, store: LocalDataStore) throws -> [StoredChatAttachment] {
        guard let data = try store.localState(for: key(id)) else { return [] }
        let list = try JSONDecoder().decode([StoredChatAttachment].self, from: data)
        guard list.count <= maximumCount, list.allSatisfy(validated) else { throw ChatAttachmentError.unavailable }
        return list
    }
    static func persist(_ attachments: [AssistantAttachment], messageID: UUID, store: LocalDataStore) throws {
        guard attachments.count <= maximumCount else { throw ChatAttachmentError.tooMany }
        guard try store.localState(for: key(messageID)) == nil else { throw ChatAttachmentError.unavailable }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw ChatAttachmentError.unavailable }
        let directory = folder(store)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var written: [URL] = []
        do {
            let records = try attachments.map { item -> StoredChatAttachment in
                guard !item.data.isEmpty else { throw ChatAttachmentError.invalidText }
                guard item.data.count <= maximumBytes, ["image/jpeg", "image/png", "text/plain"].contains(item.mimeType) else { throw ChatAttachmentError.tooLarge }
                if item.mimeType == "image/jpeg" || item.mimeType == "image/png" {
                    let prefix = [UInt8](item.data.prefix(8))
                    let jpeg = prefix.count >= 3 && Array(prefix.prefix(3)) == [255, 216, 255]
                    let png = prefix == [137, 80, 78, 71, 13, 10, 26, 10]
                    guard (item.mimeType == "image/jpeg" && jpeg) || (item.mimeType == "image/png" && png) else { throw ChatAttachmentError.invalidImage }
                }
                if item.mimeType == "text/plain" {
                    guard let text = String(data: item.data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatAttachmentError.invalidText }
                    guard text.count <= maximumTextCharacters else { throw ChatAttachmentError.tooLarge }
                }
                let name = item.id.uuidString.lowercased() + ".blob"
                let url = directory.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw ChatAttachmentError.unavailable }
                try item.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                written.append(url)
                return StoredChatAttachment(id: item.id, name: safeName(item.name), mimeType: item.mimeType, fileName: name)
            }
            try store.setLocalState(JSONEncoder().encode(records), for: key(messageID))
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    static func hydrate(_ message: AssistantMessage, store: LocalDataStore) throws -> AssistantMessage {
        let attachments = try descriptors(for: message.id, store: store).filter { !$0.isRemoved }.map { item in
            let data: Data
            do { data = try Data(contentsOf: folder(store).appendingPathComponent(item.fileName), options: .mappedIfSafe) }
            catch { throw ChatAttachmentError.unavailable }
            guard data.count <= maximumBytes else { throw ChatAttachmentError.tooLarge }
            return AssistantAttachment(id: item.id, name: item.name, mimeType: item.mimeType, data: data)
        }
        return AssistantMessage(id: message.id, role: message.role, text: message.text, sources: message.sources, attachments: attachments)
    }
    static func discard(messageID: UUID, store: LocalDataStore) throws {
        let entries = try descriptors(for: messageID, store: store)
        try store.setLocalState(nil, for: key(messageID))
        for item in entries { try? FileManager.default.removeItem(at: folder(store).appendingPathComponent(item.fileName)) }
    }
    static func removeFiles(_ entries: [StoredChatAttachment], store: LocalDataStore) throws {
        var firstError: Error?
        for item in entries where validated(item) {
            let url = folder(store).appendingPathComponent(item.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
    /// Recover only our own unreferenced UUID files after an interrupted write.
    /// Decode every manifest before removing anything, so corrupt metadata can
    /// never make a valid attachment look orphaned.
    static func reconcile(store: LocalDataStore) throws {
        let manifests = try store.attachmentStateIDs().map { id in
            (id, try descriptors(for: id, store: store), try store.getMessage(id: id) != nil)
        }
        let retained = Set(manifests.filter { $0.2 }.flatMap { $0.1.filter { !$0.isRemoved }.map(\.fileName) })
        for (id, entries, hasMessage) in manifests where !hasMessage {
            try removeFiles(entries.filter { !retained.contains($0.fileName) }, store: store)
            try store.setLocalState(nil, for: key(id))
        }
        let directory = folder(store)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".blob"), let id = UUID(uuidString: String(name.dropLast(5))),
                  name == id.uuidString.lowercased() + ".blob", !retained.contains(name) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    static func removeAllFiles(store: LocalDataStore) throws {
        let directory = folder(store)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
extension ChatAttachments {
    static func runSmokeIfRequested() {
        guard ProcessInfo.processInfo.environment["FINDY_ATTACHMENTS_SMOKE"] == "1" else { return }
        let output = URL.documentsDirectory.appending(path: "attachments-smoke.txt")
        let directory = URL.temporaryDirectory.appending(path: "FindyAttachmentTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try LocalDataStore(databaseURL: directory.appending(path: "db.sqlite"))
            let textURL = directory.appending(path: "test.txt")
            try "Привет файл".data(using: .utf16)!.write(to: textURL)
            let text = try importFile(url: textURL)
            guard String(data: text.data, encoding: .utf8) == "Привет файл" else { throw ChatAttachmentError.invalidText }
            let rtfURL = directory.appending(path: "test.rtf")
            let rtf = NSAttributedString(string: "RTF content")
            try rtf.data(from: NSRange(location: 0, length: rtf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtfURL)
            guard String(data: try importFile(url: rtfURL).data, encoding: .utf8)?.contains("RTF content") == true else { throw ChatAttachmentError.invalidText }
            let pdfURL = directory.appending(path: "test.pdf")
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300))
            let pdfData = pdf.pdfData { context in
                context.beginPage()
                ("PDF content" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
            try pdfData.write(to: pdfURL)
            guard String(data: try importFile(url: pdfURL).data, encoding: .utf8)?.contains("PDF content") == true else { throw ChatAttachmentError.invalidText }
            let emptyPDF = pdf.pdfData { $0.beginPage() }
            try emptyPDF.write(to: pdfURL)
            do { _ = try importFile(url: pdfURL); throw ChatAttachmentError.unavailable }
            catch ChatAttachmentError.invalidText {}
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2200, height: 1000))
            let image = renderer.image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2200, height: 1000)) }
            guard let bytes = image.pngData() else { throw ChatAttachmentError.invalidImage }
            let photo = try importImage(data: bytes, name: "photo.png")
            guard let decoded = UIImage(data: photo.data), max(decoded.size.width, decoded.size.height) <= 1600,
                  photo.mimeType == "image/jpeg" else { throw ChatAttachmentError.invalidImage }
            let message = AssistantMessage(role: .user, text: "Посмотри вложения.", attachments: [photo, text])
            try persist(message.attachments, messageID: message.id, store: store)
            _ = try store.upsertMessage(message, scope: "smoke")
            let saved = try store.getMessage(id: message.id)!.message
            guard saved.attachments.isEmpty, try hydrate(saved, store: store).attachments == message.attachments else { throw ChatAttachmentError.unavailable }
            let entries = try descriptors(for: message.id, store: store)
            let duplicateReferenceID = UUID()
            try store.setLocalState(JSONEncoder().encode(entries), for: "attachment." + duplicateReferenceID.uuidString.lowercased())
            try reconcile(store: store)
            guard try descriptors(for: duplicateReferenceID, store: store).isEmpty,
                  entries.allSatisfy({ FileManager.default.fileExists(atPath: folder(store).appendingPathComponent($0.fileName).path) }) else { throw ChatAttachmentError.unavailable }
            let orphan = folder(store).appendingPathComponent(UUID().uuidString.lowercased() + ".blob")
            try Data("orphan".utf8).write(to: orphan)
            let brokenID = UUID()
            try store.setLocalState(Data("invalid".utf8), for: "attachment." + brokenID.uuidString.lowercased())
            do { try reconcile(store: store); throw ChatAttachmentError.unavailable }
            catch is DecodingError {}
            guard FileManager.default.fileExists(atPath: orphan.path),
                  entries.allSatisfy({ FileManager.default.fileExists(atPath: folder(store).appendingPathComponent($0.fileName).path) }) else { throw ChatAttachmentError.unavailable }
            try store.setLocalState(nil, for: "attachment." + brokenID.uuidString.lowercased())
            try reconcile(store: store)
            guard !FileManager.default.fileExists(atPath: orphan.path),
                  entries.allSatisfy({ FileManager.default.fileExists(atPath: folder(store).appendingPathComponent($0.fileName).path) }) else { throw ChatAttachmentError.unavailable }
            try store.deleteMessage(id: message.id)
            guard try descriptors(for: message.id, store: store).isEmpty else { throw ChatAttachmentError.unavailable }
            try removeFiles(entries, store: store)
            guard entries.allSatisfy({ !FileManager.default.fileExists(atPath: folder(store).appendingPathComponent($0.fileName).path) }) else { throw ChatAttachmentError.unavailable }
            let abandoned = AssistantMessage(role: .user, text: "Abandoned", attachments: [text])
            try persist(abandoned.attachments, messageID: abandoned.id, store: store)
            let abandonedEntries = try descriptors(for: abandoned.id, store: store)
            try reconcile(store: store)
            guard try descriptors(for: abandoned.id, store: store).isEmpty,
                  abandonedEntries.allSatisfy({ !FileManager.default.fileExists(atPath: folder(store).appendingPathComponent($0.fileName).path) }) else { throw ChatAttachmentError.unavailable }
            let clearMessage = AssistantMessage(role: .user, text: "Вложение", attachments: [text])
            try persist(clearMessage.attachments, messageID: clearMessage.id, store: store)
            _ = try store.upsertMessage(clearMessage, scope: "smoke")
            try store.clearHistory()
            guard try descriptors(for: clearMessage.id, store: store).isEmpty else { throw ChatAttachmentError.unavailable }
            try removeAllFiles(store: store)
            guard !FileManager.default.fileExists(atPath: folder(store).path) else { throw ChatAttachmentError.unavailable }
            let timelineMessage = AssistantMessage(role: .user, text: "Посмотри вложения.", attachments: [text])
            _ = try ChatTimeline.shared.accept(timelineMessage, scope: "attachment-smoke")
            let hydrated = try ChatTimeline.shared.context(scope: "attachment-smoke")
            let voice = try ChatTimeline.shared.context(scope: "attachment-smoke", includeAttachments: false)
            guard hydrated.last?.attachments == [text], voice.last?.attachments.isEmpty == true else { throw ChatAttachmentError.unavailable }
            try ChatTimeline.shared.deleteMessage(id: timelineMessage.id)
            let settings = AssistantSettings.shared
            let scope = PersonalData.contextScope(settings: settings)
            let unique = "Первый запрос после запуска \(UUID().uuidString)"
            guard VoiceSession.shared.sendText(unique, attachments: [text]) else { throw ChatAttachmentError.unavailable }
            let selectedContext = try ChatTimeline.shared.context(scope: scope)
            guard let sent = selectedContext.last, sent.text == unique, sent.attachments == [text],
                  try PersonalData.shared.requireStore().getMessage(id: sent.id)?.scope == scope else { throw ChatAttachmentError.unavailable }
            VoiceSession.shared.cancelTextReply()
            try ChatTimeline.shared.deleteMessage(id: sent.id)
            let provider1 = AssistantProvider(name: "Тест один", endpoint: "https://example.com/v1", models: ["test"])
            let provider2 = AssistantProvider(name: "Тест два", endpoint: "https://example.org/v1", models: ["test"])
            try settings.upsertProvider(provider1, apiKey: nil)
            try settings.upsertProvider(provider2, apiKey: nil)
            try settings.selectModel(providerID: provider1.id, modelID: "test")
            try settings.selectModel(providerID: provider2.id, modelID: "test")
            let changedScope = PersonalData.contextScope(settings: settings)
            let secondText = "После смены провайдера \(UUID().uuidString)"
            guard VoiceSession.shared.sendText(secondText, attachments: [text]) else { throw ChatAttachmentError.unavailable }
            let changedContext = try ChatTimeline.shared.context(scope: changedScope)
            guard let second = changedContext.last, second.text == secondText, second.attachments == [text],
                  try PersonalData.shared.requireStore().getMessage(id: second.id)?.scope == changedScope else { throw ChatAttachmentError.unavailable }
            VoiceSession.shared.cancelTextReply()
            try ChatTimeline.shared.deleteMessage(id: second.id)
            try? settings.deleteProvider(id: provider1.id)
            try? settings.deleteProvider(id: provider2.id)
            var limitMessageIDs: [UUID] = []
            for _ in 0..<4 {
                let file = AssistantAttachment(name: "limit.txt", mimeType: "text/plain", data: Data(String(repeating: "a", count: 15_001).utf8))
                let item = AssistantMessage(role: .user, text: "Файл", attachments: [file])
                _ = try ChatTimeline.shared.accept(item, scope: "attachment-limit-smoke")
                limitMessageIDs.append(item.id)
            }
            do { _ = try ChatTimeline.shared.context(scope: "attachment-limit-smoke"); throw ChatAttachmentError.unavailable }
            catch ChatAttachmentError.contextTextTooLarge {}
            for id in limitMessageIDs { try ChatTimeline.shared.deleteMessage(id: id) }
            try "  \n".write(to: textURL, atomically: true, encoding: .utf8)
            do { _ = try importFile(url: textURL); throw ChatAttachmentError.unavailable }
            catch ChatAttachmentError.invalidText {}
            let empty = AssistantAttachment(name: "empty.txt", mimeType: "text/plain", data: Data())
            do { try persist([empty], messageID: UUID(), store: store); throw ChatAttachmentError.unavailable }
            catch ChatAttachmentError.invalidText {}
            try String(repeating: "я", count: maximumTextCharacters + 1).write(to: textURL, atomically: true, encoding: .utf8)
            do { _ = try importFile(url: textURL); throw ChatAttachmentError.unavailable }
            catch ChatAttachmentError.tooLarge {}
            try "PASS UTF16, RTF, text and empty PDF, image downsample, persistence, first send and provider-change scope, hydration, voice exclusion, delete and clear, interrupted-write, shared-reference and corrupt-manifest recovery, empty, per-file and total text limit rejection".write(to: output, atomically: true, encoding: .utf8)
        } catch { try? "FAIL \(error)".write(to: output, atomically: true, encoding: .utf8) }
    }
}
#endif
