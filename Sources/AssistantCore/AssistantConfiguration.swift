import Foundation

public enum AssistantAPIStyle: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    case responses
    case realtime
}

public struct AssistantConfiguration: Codable, Equatable, Sendable {
    public static let defaultSystemPrompt = "Ты — Findy, дружелюбный голосовой помощник. Отвечай на языке пользователя, кратко и естественно, обычно в 1–3 предложениях. Не используй Markdown и не зачитывай ссылки. Если веб-поиск недоступен, не утверждай, что проверил актуальную информацию."

    public var endpoint: String
    public var model: String
    public var apiStyle: AssistantAPIStyle
    public var systemPrompt: String
    public var webSearchEnabled: Bool
    public var realtimeVoice: String
    public var webSearchModel: String
    public var contextMessageCount: Int

    public init(
        endpoint: String = "https://api.openai.com/v1",
        model: String = "",
        apiStyle: AssistantAPIStyle = .chatCompletions,
        systemPrompt: String = AssistantConfiguration.defaultSystemPrompt,
        webSearchEnabled: Bool = false,
        realtimeVoice: String = "marin",
        webSearchModel: String = "gpt-6-luna",
        contextMessageCount: Int = AssistantLimits.contextMessageDefault
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiStyle = apiStyle
        self.systemPrompt = systemPrompt
        self.webSearchEnabled = webSearchEnabled
        self.realtimeVoice = realtimeVoice
        self.webSearchModel = webSearchModel
        self.contextMessageCount = AssistantLimits.normalizedContextMessageCount(contextMessageCount)
    }

    public func validatedEndpoint() throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantClientError.missingModel
        }
        guard !webSearchEnabled || apiStyle != .chatCompletions else {
            throw AssistantClientError.unsupportedWebSearch
        }
        let route: String
        switch apiStyle {
        case .chatCompletions: route = "/chat/completions"
        case .responses: route = "/responses"
        case .realtime: route = "/realtime"
        }
        return try AssistantEndpoint.resolve(endpoint, route: route)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, model, apiStyle, systemPrompt, webSearchEnabled, realtimeVoice, webSearchModel, contextMessageCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        apiStyle = try values.decode(AssistantAPIStyle.self, forKey: .apiStyle)
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultSystemPrompt
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
        realtimeVoice = try values.decodeIfPresent(String.self, forKey: .realtimeVoice) ?? "marin"
        webSearchModel = try values.decodeIfPresent(String.self, forKey: .webSearchModel) ?? "gpt-6-luna"
        contextMessageCount = AssistantLimits.normalizedContextMessageCount(try values.decodeIfPresent(Int.self, forKey: .contextMessageCount) ?? AssistantLimits.contextMessageDefault)
    }
}

public struct AssistantProvider: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var endpoint: String
    public var apiStyle: AssistantAPIStyle
    public var models: [String]
    public var systemPrompt: String
    public var webSearchEnabled: Bool
    public var realtimeVoice: String
    public var webSearchModel: String

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        apiStyle: AssistantAPIStyle = .chatCompletions,
        models: [String] = [],
        systemPrompt: String = AssistantConfiguration.defaultSystemPrompt,
        webSearchEnabled: Bool = false,
        realtimeVoice: String = "marin",
        webSearchModel: String = "gpt-6-luna"
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiStyle = apiStyle
        self.models = models
        self.systemPrompt = systemPrompt
        self.webSearchEnabled = webSearchEnabled
        self.realtimeVoice = realtimeVoice
        self.webSearchModel = webSearchModel
    }

    public func configuration(for modelID: String) -> AssistantConfiguration {
        AssistantConfiguration(
            endpoint: endpoint,
            model: modelID,
            apiStyle: apiStyle,
            systemPrompt: systemPrompt,
            webSearchEnabled: webSearchEnabled,
            realtimeVoice: realtimeVoice,
            webSearchModel: webSearchModel
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, apiStyle, models, systemPrompt, webSearchEnabled, realtimeVoice, webSearchModel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        apiStyle = try values.decode(AssistantAPIStyle.self, forKey: .apiStyle)
        models = try values.decode([String].self, forKey: .models)
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? AssistantConfiguration.defaultSystemPrompt
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
        realtimeVoice = try values.decodeIfPresent(String.self, forKey: .realtimeVoice) ?? "marin"
        webSearchModel = try values.decodeIfPresent(String.self, forKey: .webSearchModel) ?? "gpt-6-luna"
    }
}

public struct AssistantModelSelection: Codable, Equatable, Sendable {
    public var providerID: UUID
    public var modelID: String

    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

enum AssistantEndpoint {
    static func resolve(_ endpoint: String, route: String) throws -> URL {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["http", "https"].contains(scheme) else {
            throw AssistantClientError.invalidEndpoint
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/realtime", "/models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        path += route
        components.percentEncodedPath = path
        guard let url = components.url else { throw AssistantClientError.invalidEndpoint }
        return url
    }
}

public enum AssistantClientError: Error, LocalizedError, Equatable, Sendable {
    case missingModel
    case invalidEndpoint
    case unsupportedWebSearch
    case unsupportedAPIStyle
    case invalidAPIKey
    case emptyConversation
    case inputTooLong
    case httpStatus(Int)
    case invalidResponse
    case emptyResponse
    case incompleteResponse
    case failedResponse
    case networkUnavailable
    case requestTimedOut

    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Укажите название модели в настройках подключения."
        case .invalidEndpoint:
            return "Укажите HTTP- или HTTPS-адрес API без логина, пароля, параметров и фрагмента."
        case .unsupportedWebSearch:
            return "Для веб-поиска выберите Responses или Realtime и сервис с поддержкой инструмента web_search."
        case .unsupportedAPIStyle:
            return "Для этой модели требуется подключение Realtime. Выберите соответствующий формат API."
        case .invalidAPIKey:
            return "Ключ API содержит недопустимые символы. Введите ключ заново."
        case .emptyConversation:
            return "Нет сообщения для отправки модели."
        case .inputTooLong:
            return "Сообщение слишком длинное. Сократите его до 500 символов."
        case .httpStatus(let status):
            switch status {
            case 300..<400:
                return "Сервис перенаправляет запрос (HTTP \(status)). Укажите конечный адрес API в настройках."
            case 401, 403:
                return "Сервис отклонил ключ API или доступ к модели (HTTP \(status)). Проверьте подключение."
            case 404:
                return "Адрес API или модель не найдены (HTTP 404). Проверьте настройки."
            case 408, 504:
                return "Сервис не успел ответить (HTTP \(status)). Повторите попытку."
            case 429:
                return "Сервис сообщил об ограничении запросов или баланса (HTTP 429)."
            case 500..<600:
                return "Ошибка на стороне сервиса (HTTP \(status)). Повторите попытку позже."
            default:
                return "Сервис отклонил запрос (HTTP \(status)). Проверьте модель и формат API."
            }
        case .invalidResponse:
            return "Ответ сервиса не соответствует выбранному формату API."
        case .emptyResponse:
            return "Модель вернула ответ без текста. Проверьте поддержку текстовых ответов."
        case .incompleteResponse:
            return "Сервис не завершил ответ модели. Повторите запрос."
        case .failedResponse:
            return "Сервис не смог сформировать ответ модели."
        case .networkUnavailable:
            return "Не удалось связаться с сервисом. Проверьте интернет и адрес API."
        case .requestTimedOut:
            return "Сервис не ответил вовремя. Повторите попытку."
        }
    }
}
