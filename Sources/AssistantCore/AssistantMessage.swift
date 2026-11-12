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

    public init(id: UUID = UUID(), role: Role, text: String, sources: [AssistantSource] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
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
