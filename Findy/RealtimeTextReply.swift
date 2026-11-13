import Foundation

/// Web search remains a tool of the selected Realtime model. Its Responses
/// helper uses the same provider and credential; it isn't another selected
/// conversational model. Only source titles and cleaned prose go to the voice
/// model. Full source URLs are kept separately for the chat UI.
enum RealtimeSearchTool {
    static func execute(_ call: RealtimeFunctionCall, configuration: AssistantConfiguration, apiKey: String) async throws -> AssistantReply {
        struct Arguments: Decodable { let query: String }
        guard call.name == "web_search", configuration.webSearchEnabled,
              let data = call.arguments.data(using: .utf8), data.count <= 16_384,
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            throw AssistantClientError.invalidResponse
        }
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000 else { throw AssistantClientError.emptyConversation }
        let search = AssistantConfiguration(
            endpoint: configuration.endpoint,
            model: configuration.webSearchModel,
            apiStyle: .responses,
            systemPrompt: "Выполни поиск в интернете по запросу. Дай краткий фактический ответ по найденным страницам с источниками. Не утверждай, что поиск выполнен, если инструмент не использовался. Ответь на языке запроса.",
            webSearchEnabled: true
        )
        let reply = try await AssistantClient().reply(
            configuration: search, apiKey: apiKey,
            messages: [AssistantMessage(role: .user, text: "Найди в интернете актуальную информацию: \(query)")]
        )
        guard reply.usedWebSearch else { throw AssistantClientError.failedResponse }
        return reply
    }

    static func output(_ reply: AssistantReply) throws -> String {
        struct Result: Encodable {
            let text: String
            let sourceTitles: [String]
            let searched: Bool
        }
        let result = Result(
            text: String(ConversationRules.spokenText(from: reply.text, sourceURLs: reply.sources.map(\.url)).prefix(16_000)),
            sourceTitles: reply.sources.prefix(12).map { ConversationRules.spokenText(from: $0.title) },
            searched: true
        )
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}

enum RealtimeTextReply {
    static func reply(
        configuration: AssistantConfiguration, apiKey: String, messages: [AssistantMessage],
        tools: [AssistantToolDefinition] = [], toolHandler: AssistantToolHandler? = nil,
        onUpdate: (@Sendable (AssistantReply) async -> Void)? = nil
    ) async throws -> AssistantReply {
        let selected = AssistantContext.recent(messages, limit: configuration.contextMessageCount)
        guard let last = selected.last, last.role == .user else { throw AssistantClientError.emptyConversation }
        try AssistantAttachmentWire.validate(selected, supportsImages: configuration.supportsImageInput)
        let conversation = RealtimeTextConversation(configuration: configuration, apiKey: apiKey, tools: tools, toolHandler: toolHandler, onUpdate: onUpdate)
        return try await withThrowingTaskGroup(of: AssistantReply.self) { group in
            group.addTask { try await conversation.run(history: Array(selected.dropLast()), message: last) }
            group.addTask {
                try await Task.sleep(for: .seconds(configuration.supportsImageGeneration ? 300 : 60))
                throw AssistantClientError.requestTimedOut
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                await conversation.stop()
                return result
            } catch {
                await conversation.stop()
                throw error
            }
        }
    }
}

private actor RealtimeTextConversation {
    let client = RealtimeClient()
    let configuration: AssistantConfiguration
    let apiKey: String
    let onUpdate: (@Sendable (AssistantReply) async -> Void)?
    let tools: [AssistantToolDefinition]
    let toolHandler: AssistantToolHandler?
    var completion: CheckedContinuation<AssistantReply, Error>?
    var pendingResult: Result<AssistantReply, Error>?
    var outputItems: [(String, String)] = []
    var sources: [AssistantSource] = []
    var usedSearch = false
    var toolTasks: [String: Task<Void, Never>] = [:]
    var handledCalls = Set<String>()
    var remainingToolRounds = 6
    var waitingForToolResponse = false
    var responseStartItemCount = 0
    var stopped = false

    init(configuration: AssistantConfiguration, apiKey: String, tools: [AssistantToolDefinition], toolHandler: AssistantToolHandler?, onUpdate: (@Sendable (AssistantReply) async -> Void)?) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.onUpdate = onUpdate
        self.tools = tools
        self.toolHandler = toolHandler
    }

    func run(history: [AssistantMessage], message: AssistantMessage) async throws -> AssistantReply {
        do {
            try await client.connect(configuration: configuration, apiKey: apiKey, history: history, outputAudio: false, tools: tools) { [weak self] event in
                await self?.receive(event)
            }
            try Task.checkCancellation()
            try await client.sendMessage(message)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result = pendingResult { continuation.resume(with: result) }
                    else if stopped { continuation.resume(throwing: CancellationError()) }
                    else { completion = continuation }
                }
            } onCancel: {
                Task { await self.stop() }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        for task in toolTasks.values { task.cancel() }
        toolTasks = [:]
        finish(.failure(CancellationError()))
        await client.close()
    }

    private var snapshot: AssistantReply {
        AssistantReply(text: outputItems.map(\.1).joined(separator: "\n"), sources: sources, usedWebSearch: usedSearch)
    }

    private func receive(_ event: RealtimeEvent) async {
        guard !stopped, pendingResult == nil else { return }
        switch event {
        case .responseStarted:
            responseStartItemCount = outputItems.count
        case .outputTranscript(let itemID, let text, _):
            if let index = outputItems.firstIndex(where: { $0.0 == itemID }) { outputItems[index].1 = text }
            else { outputItems.append((itemID, text)) }
            if tools.isEmpty { await onUpdate?(snapshot) }
        case .functionCall(let call):
            guard handledCalls.insert(call.callID).inserted else { return }
            guard remainingToolRounds > 0 else { finish(.failure(AssistantClientError.failedResponse)); return }
            remainingToolRounds -= 1
            toolTasks[call.callID] = Task { [weak self, configuration, apiKey, toolHandler] in
                do {
                    let result: AssistantToolResult
                    if let toolHandler { result = try await toolHandler(call) }
                    else {
                        let reply = try await RealtimeSearchTool.execute(call, configuration: configuration, apiKey: apiKey)
                        result = AssistantToolResult(output: try RealtimeSearchTool.output(reply), sources: reply.sources, usedWebSearch: reply.usedWebSearch)
                    }
                    try Task.checkCancellation()
                    await self?.completeTool(call, result: .success(result))
                } catch is CancellationError { return }
                catch { await self?.completeTool(call, result: .failure(error)) }
            }
        case .responseDone(let result):
            guard result.status == .completed else {
                finish(.failure(AssistantClientError.failedResponse)); return
            }
            if result.hasFunctionCalls {
                if !tools.isEmpty { outputItems.removeSubrange(responseStartItemCount...) }
                waitingForToolResponse = true
                await requestResponseAfterToolsIfReady()
                return
            }
            guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failure(AssistantClientError.emptyResponse)); return
            }
            if !tools.isEmpty { await onUpdate?(snapshot) }
            finish(.success(snapshot))
        case .failure(let error): finish(.failure(error))
        default: break
        }
    }

    private func completeTool(_ call: RealtimeFunctionCall, result: Result<AssistantToolResult, Error>) async {
        guard !stopped, pendingResult == nil else { return }
        do {
            let output: String
            switch result {
            case .success(let reply):
                usedSearch = usedSearch || reply.usedWebSearch
                for source in reply.sources where !sources.contains(where: { $0.url == source.url }) { sources.append(source) }
                output = reply.output
                if tools.isEmpty { await onUpdate?(snapshot) }
            case .failure:
                output = "{\"ok\":false,\"error\":\"Действие не выполнено. Сообщи об этом пользователю, не подтверждай успех.\"}"
            }
            guard !stopped, pendingResult == nil, !Task.isCancelled else { return }
            try await client.submitFunctionOutput(callID: call.callID, output: output)
            guard !stopped, pendingResult == nil, !Task.isCancelled else { return }
            toolTasks[call.callID] = nil
            await requestResponseAfterToolsIfReady()
        } catch { finish(.failure(error)) }
    }

    private func requestResponseAfterToolsIfReady() async {
        guard waitingForToolResponse, toolTasks.isEmpty, !stopped, pendingResult == nil else { return }
        waitingForToolResponse = false
        do { try await client.requestResponse() }
        catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<AssistantReply, Error>) {
        guard pendingResult == nil else { return }
        pendingResult = result
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        completion?.resume(with: result)
        completion = nil
    }
}
