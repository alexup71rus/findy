import Foundation

public struct AssistantMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let sources: [AssistantSource]
    public let attachments: [AssistantAttachment]
    public var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    public init(id: UUID = UUID(), role: Role, text: String, sources: [AssistantSource] = [], attachments: [AssistantAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.attachments = attachments
    }
    private enum CodingKeys: String, CodingKey { case id, role, text, sources, attachments }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        sources = try values.decodeIfPresent([AssistantSource].self, forKey: .sources) ?? []
        attachments = try values.decodeIfPresent([AssistantAttachment].self, forKey: .attachments) ?? []
    }
}

public struct AssistantAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data
    public var isImage: Bool { mimeType == "image/jpeg" || mimeType == "image/png" }
    public init(id: UUID = UUID(), name: String, mimeType: String, data: Data) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.data = data
    }
}

public enum AssistantAttachmentError: Error, LocalizedError, Equatable, Sendable {
    case tooMany, tooLarge, invalid, unsupportedImages
    public var errorDescription: String? {
        switch self {
        case .tooMany: "Можно прикрепить не более трёх файлов к сообщению."
        case .tooLarge: "Вложения слишком большие. Уменьшите их размер или сократите контекст разговора."
        case .invalid: "Не удалось прочитать вложение. Поддерживаются PNG, JPEG и текст UTF-8."
        case .unsupportedImages: "Включите поддержку изображений у провайдера или выберите OpenAI."
        }
    }
}

// Attachments are sent only as user content; text files are clearly marked as data.
public enum AssistantAttachmentWire {
    static let maxContextBytes = 10 * 1024 * 1024
    public static func validate(_ messages: [AssistantMessage], supportsImages: Bool) throws {
        var total = 0
        var totalTextCharacters = 0
        for message in messages {
            guard message.attachments.count <= 3 else { throw AssistantAttachmentError.tooMany }
            guard message.role == .user || message.attachments.isEmpty else { throw AssistantAttachmentError.invalid }
            for attachment in message.attachments {
                guard !attachment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      attachment.name.count <= 255, !attachment.name.contains("\n"), !attachment.name.contains("\r"),
                      !attachment.data.isEmpty else { throw AssistantAttachmentError.invalid }
                total += attachment.data.count
                guard total <= maxContextBytes else { throw AssistantAttachmentError.tooLarge }
                if attachment.isImage {
                    guard supportsImages else { throw AssistantAttachmentError.unsupportedImages }
                    guard attachment.data.count <= 2 * 1024 * 1024 else { throw AssistantAttachmentError.tooLarge }
                    let bytes = [UInt8](attachment.data.prefix(8))
                    let png = bytes == [137,80,78,71,13,10,26,10]
                    let jpeg = bytes.count >= 3 && Array(bytes.prefix(3)) == [255,216,255]
                    guard (attachment.mimeType == "image/png" && png) || (attachment.mimeType == "image/jpeg" && jpeg) else { throw AssistantAttachmentError.invalid }
                } else if attachment.mimeType == "text/plain", let text = String(data: attachment.data, encoding: .utf8) {
                    guard text.count <= 20_000 else { throw AssistantAttachmentError.tooLarge }
                    totalTextCharacters += text.count
                    guard totalTextCharacters <= 60_000 else { throw AssistantAttachmentError.tooLarge }
                } else { throw AssistantAttachmentError.invalid }
            }
        }
    }
    static func text(_ attachment: AssistantAttachment) -> String {
        "[Начало содержимого файла: \(attachment.name)]\n" + String(decoding: attachment.data, as: UTF8.self) + "\n[Конец содержимого файла: \(attachment.name)]"
    }
    static func dataURL(_ attachment: AssistantAttachment) -> String {
        "data:\(attachment.mimeType);base64," + attachment.data.base64EncodedString()
    }
}

public struct AssistantSource: Codable, Equatable, Sendable, Identifiable {
    public let title: String
    public let url: URL
    public var id: URL { url }

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case title, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(URL.self, forKey: .url)
        guard Self.isSafe(value) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Expected an HTTP(S) source URL")
        }
        url = value
        title = try container.decode(String.self, forKey: .title)
    }

    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}

public struct AssistantReply: Equatable, Sendable {
    public let text: String
    public let sources: [AssistantSource]
    public let usedWebSearch: Bool

    public init(text: String, sources: [AssistantSource] = [], usedWebSearch: Bool = false) {
        self.text = text
        self.sources = sources
        self.usedWebSearch = usedWebSearch
    }
}
