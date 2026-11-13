import AVFoundation
import Foundation

/// Owns one native speech-to-speech connection. Siri eligibility and the audio
/// session belong to VoiceSession; this object starts only after that handoff.
@MainActor
final class RealtimeVoiceSession {
    private struct Record {
        let serverID: String
        let id = UUID()
        let role: AssistantMessage.Role
        var text = ""
        var isFinal = false
        var sources: [AssistantSource] = []
        var message: AssistantMessage { AssistantMessage(id: id, role: role, text: ConversationRules.displayText(from: text), sources: sources) }
    }

    let input: RealtimeAudioInput
    private let output: RealtimeAudioOutput
    private let client = RealtimeClient()
    private let configuration: AssistantConfiguration
    private let silenceTimeout: TimeInterval
    private let toolDefinitions: [AssistantToolDefinition]
    private var apiKey: String
    private let history: [AssistantMessage]
    private var records: [Record] = []
    private var sender: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var tools: [String: Task<Void, Never>] = [:]
    private var handledCalls = Set<String>()
    private var interruptedItems = Set<String>()
    private var responseItems = Set<String>()
    private var pendingSources: [AssistantSource] = []
    private var turn = UUID()
    private var responseID: String?
    private var responseActive = false
    private var userSpeaking = false
    private var ready = false
    private var stopped = false
    private var senderFailed = false
    private var firstInputLogged = false
    private var firstOutputLogged = false
    private var startedAt: TimeInterval = 0
    private var idleSince: TimeInterval?
    private var waitingSince: TimeInterval?
    private var speakingSince: TimeInterval?
    private var toolRounds = 0
    private var toolsAwaitingResponse = false
    private var readinessCuePending = false
    private var readinessTask: Task<Void, Never>?
    private var endState = VoiceEndState()
    private var endTask: Task<Void, Never>?
    private var fallbackItemID: String?
    private var fallbackUtterance = ""
    private var semanticItemID: String?
    private var semanticUtterance = ""
    private var currentResponseHasAudio = false
    private var farewellRequested = false
    private var ignoredFarewellResponseIDs = Set<String>()

    var onState: ((VoiceSession.Phase, String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onMessage: ((AssistantMessage, Bool) throws -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var toolHandler: ((AssistantToolCall, String) async throws -> AssistantToolResult)?
    var instructionsProvider: (() throws -> String)?
    var onStop: ((String, Error?) async -> Void)?
    var onReadyAgain: (() async throws -> Void)?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(engine: AVAudioEngine, format: AVAudioFormat, configuration: AssistantConfiguration,
         apiKey: String, history: [AssistantMessage], silenceTimeout: TimeInterval, tools: [AssistantToolDefinition] = []) throws {
        input = try RealtimeAudioInput(format: format, initiallyMuted: true)
        output = RealtimeAudioOutput(engine: engine)
        self.configuration = configuration
        self.apiKey = apiKey
        self.history = AssistantContext.recent(history, limit: configuration.contextMessageCount)
        self.silenceTimeout = silenceTimeout
        toolDefinitions = tools
        output.onDrained = { [weak self] in self?.refreshPhase() }
    }

    func connect(onReady: (() async throws -> Void)? = nil) async throws {
        startedAt = now
        onState?(.starting, "Подключаю голос OpenAI…")
        try await client.connect(configuration: configuration, apiKey: apiKey, history: history, outputAudio: true, tools: toolDefinitions) { [weak self] event in
            await self?.receive(event)
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        SessionLog.shared.record("realtime.network.ready")
        // Start the sender before the readiness cue; capture remains muted
        // until the cue has finished, so the cue cannot reach server VAD.
        sender = Task { [weak self, client, input] in
            SessionLog.shared.record("realtime.sender.started")
            do {
                while !Task.isCancelled {
                    if let data = try input.drain() { try await client.appendAudio(data) }
                    else { try await Task.sleep(for: .milliseconds(15)) }
                }
            } catch is CancellationError { return }
            catch {
                guard let self else { return }
                self.senderFailed = true
                await self.end("Ошибка передачи голоса", error: error)
            }
        }
        try await onReady?()
        try Task.checkCancellation()
        guard !stopped, !senderFailed else { throw CancellationError() }
        input.setMuted(false)
        ready = true
        idleSince = now
        refreshPhase()
        SessionLog.shared.record("realtime.connected", "pcm=24000 tool=\(configuration.webSearchEnabled)")
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, !self.stopped else { return }
                let snapshot = self.input.snapshot()
                // Reuse the health monitor, never dispatch work from the audio
                // render callback. Output energy follows actual playback.
                self.onLevel?(self.output.isPlaying && !self.userSpeaking
                    ? self.output.playbackLevel() : snapshot.level)
                if !self.firstInputLogged, snapshot.buffers > 0 {
                    self.firstInputLogged = true
                    SessionLog.shared.record("realtime.input.firstBuffer", "levelDB=\(snapshot.level)")
                }
                if (snapshot.buffers == 0 && self.now - self.startedAt > 2)
                    || (snapshot.buffers > 0 && self.now - snapshot.lastBufferAt > 2) {
                    await self.end("Нет аудио", error: VoiceError(message: "Микрофон не отдаёт аудиобуферы."))
                    return
                }
                if self.silenceTimeout > 0, let idle = self.idleSince, self.now - idle >= self.silenceTimeout {
                    await self.end("\(Int(self.silenceTimeout)) секунд тишины")
                    return
                }
                if let waiting = self.waitingSince, self.now - waiting > 60 {
                    await self.end("Время ожидания ответа истекло", error: AssistantClientError.requestTimedOut)
                    return
                }
                if let speaking = self.speakingSince, self.now - speaking > 90 {
                    await self.end("Длительная запись", error: VoiceError(message: "Голосовая реплика превысила 90 секунд. Повторите запуск."))
                    return
                }
            }
        }
    }

    var canAcceptInput: Bool { !stopped && !senderFailed }
    var isUserSpeaking: Bool { userSpeaking }
    var canPlayReadyCue: Bool {
        canAcceptInput && !userSpeaking && !output.isPlaying && !responseActive && waitingSince == nil && tools.isEmpty
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        ready = false
        sender?.cancel()
        monitor?.cancel()
        readinessTask?.cancel()
        readinessTask = nil
        endTask?.cancel()
        endTask = nil
        endState.reset()
        for task in tools.values { task.cancel() }
        tools = [:]
        input.stop()
        output.stop()
        onState = nil
        onLevel = nil
        onMessage = nil
        onUserTranscript = nil
        toolHandler = nil
        instructionsProvider = nil
        onStop = nil
        onReadyAgain = nil
        apiKey = ""
        await client.close()
    }

    private func receive(_ event: RealtimeEvent) async {
        guard !stopped else { return }
        do {
            switch event {
            case .ready: break // connect() returns only after history is restored
            case .speechStarted(let itemID):
                endTask?.cancel()
                endTask = nil
                endState.reset()
                fallbackItemID = nil
                fallbackUtterance = ""
                semanticItemID = nil
                semanticUtterance = ""
                farewellRequested = false
                readinessCuePending = false
                interruptedItems.formUnion(responseItems)
                responseItems = []
                turn = UUID()
                userSpeaking = true
                speakingSince = now
                idleSince = nil
                waitingSince = nil
                pendingSources = []
                toolRounds = 0
                toolsAwaitingResponse = false
                for task in tools.values { task.cancel() }
                tools = [:]
                if let position = output.interrupt() {
                    interruptedItems.insert(position.itemID)
                    try await client.truncate(itemID: position.itemID, contentIndex: position.contentIndex, audioEndMilliseconds: position.milliseconds)
                    SessionLog.shared.record("realtime.output.interrupted", "heardMS=\(position.milliseconds)")
                }
                responseActive = false
                responseID = nil
                for index in records.indices where records[index].role == .assistant && !records[index].isFinal {
                    records[index].isFinal = true
                    if !records[index].text.isEmpty { try onMessage?(records[index].message, true) }
                }
                _ = try recordIndex(itemID, role: .user)
                onUserTranscript?("")
                if let instructionsProvider { try await client.updateInstructions(instructionsProvider()) }
                refreshPhase()
                SessionLog.shared.record("realtime.speech.started")
            case .speechStopped:
                userSpeaking = false
                speakingSince = nil
                waitingSince = now
                refreshPhase()
                SessionLog.shared.record("realtime.speech.stopped")
            case .inputTranscript(let itemID, let text, let final):
                let index = try recordIndex(itemID, role: .user)
                records[index].text = text
                records[index].isFinal = final
                onUserTranscript?(text)
                try onMessage?(records[index].message, final)
                if final {
                    if records.last(where: { $0.role == .user })?.serverID == itemID {
                        if VoiceConversationEnd.isStandaloneFarewell(text), !endState.pending {
                            fallbackItemID = itemID
                            fallbackUtterance = text
                            endState.request(preservingCurrentResponse: true)
                            refreshPhase()
                        } else if (fallbackItemID == itemID && !VoiceConversationEnd.isStandaloneFarewell(text)) ||
                                    (semanticItemID == itemID && semanticUtterance != text) {
                            fallbackItemID = nil
                            fallbackUtterance = ""
                            semanticItemID = nil
                            semanticUtterance = ""
                            farewellRequested = false
                            endTask?.cancel(); endTask = nil
                            endState.reset()
                        }
                    }
                    SessionLog.shared.record("realtime.input.transcribed", "characters=\(text.count)")
                }
            case .farewellResponseStarted(let id, let responseTurn):
                guard farewellRequested, responseTurn == turn.uuidString, !userSpeaking else {
                    ignoredFarewellResponseIDs.insert(id)
                    try await client.cancelResponse(id: id)
                    return
                }
                responseID = id
                responseItems = []
                currentResponseHasAudio = false
                responseActive = true
                waitingSince = now
                idleSince = nil
                refreshPhase()
            case .responseStarted(let id):
                responseID = id
                responseItems = []
                currentResponseHasAudio = false
                responseActive = true
                waitingSince = now
                idleSince = nil
                refreshPhase()
            case .outputItemStarted(let id, let itemID):
                if ignoredFarewellResponseIDs.contains(id) { interruptedItems.insert(itemID); return }
                if id == responseID {
                    responseItems.insert(itemID)
                    _ = try recordIndex(itemID, role: .assistant)
                }
            case .audioDelta(let itemID, let contentIndex, let pcm16):
                guard !interruptedItems.contains(itemID), !userSpeaking else { return }
                WaitingMusicPlayer.shared.stop()
                try output.append(pcm16, itemID: itemID, contentIndex: contentIndex)
                if !pcm16.isEmpty { currentResponseHasAudio = true; readinessCuePending = true }
                if !firstOutputLogged {
                    firstOutputLogged = true
                    SessionLog.shared.record("realtime.output.firstAudio", "bytes=\(pcm16.count)")
                }
                refreshPhase()
            case .audioDone: break // output completion is measured at the speaker
            case .outputTranscript(let itemID, let text, let final):
                guard !interruptedItems.contains(itemID) else { return }
                let index = try recordIndex(itemID, role: .assistant)
                records[index].text = text
                records[index].isFinal = final
                records[index].sources = pendingSources
                try onMessage?(records[index].message, final)
            case .functionCall(let call):
                guard handledCalls.insert(call.callID).inserted else { return }
                guard toolRounds < 6 else { throw VoiceError(message: "Модель превысила число действий в одной реплике.") }
                toolRounds += 1
                let generation = turn
                let userItemID = records.last(where: { $0.role == .user })?.serverID
                waitingSince = now
                tools[call.callID] = Task { [weak self, configuration, apiKey] in
                    do {
                        guard let self else { return }
                        let result: AssistantToolResult
                        if call.name == "end_voice_conversation" {
                            let request = try await self.userRequest(for: userItemID, generation: generation, wait: true)
                            if VoiceConversationEnd.allowsCall(arguments: call.arguments, latestUtterance: request) {
                                if self.fallbackItemID == nil {
                                    self.semanticItemID = userItemID
                                    self.semanticUtterance = request
                                    self.endState.request()
                                }
                                result = AssistantToolResult(output: "{\"ok\":true,\"message\":\"Коротко попрощайся. Разговор завершится после воспроизведения ответа.\"}")
                            } else {
                                result = AssistantToolResult(output: "{\"ok\":false,\"message\":\"Продолжай разговор; намерение завершить не подтверждено.\"}")
                            }
                        } else if let handler = self.toolHandler {
                            let request = try await self.userRequest(for: userItemID, generation: generation, wait: call.name != "web_search")
                            result = try await handler(call, request)
                        } else {
                            let reply = try await RealtimeSearchTool.execute(call, configuration: configuration, apiKey: apiKey)
                            result = AssistantToolResult(output: try RealtimeSearchTool.output(reply), sources: reply.sources, usedWebSearch: reply.usedWebSearch)
                        }
                        try Task.checkCancellation()
                        await self.completeTool(call, result: .success(result), generation: generation)
                    } catch is CancellationError { return }
                    catch { await self?.completeTool(call, result: .failure(error), generation: generation) }
                }
                SessionLog.shared.record("realtime.tool.started", "name=\(safeToolName(call.name))")
                refreshPhase()
            case .contextPruned(let removed, let retained):
                SessionLog.shared.record("realtime.context.pruned", "removed=\(removed) retainedMessages=\(retained)")
            case .responseDone(let result):
                if ignoredFarewellResponseIDs.remove(result.id) != nil { return }
                guard result.id == responseID else { return }
                responseActive = false
                if let usage = result.usage {
                    SessionLog.shared.record("realtime.response.completed", "status=\(result.status.rawValue) inputTokens=\(usage.inputTokens) outputTokens=\(usage.outputTokens) audioIn=\(usage.inputAudioTokens) audioOut=\(usage.outputAudioTokens) cached=\(usage.cachedInputTokens)")
                }
                if result.status == .failed || result.status == .incomplete {
                    throw result.error ?? RealtimeClientError.serverError
                }
                endState.responseCompleted(success: result.status == .completed, hasToolCalls: result.hasFunctionCalls)
                if result.hasFunctionCalls {
                    waitingSince = now
                    toolsAwaitingResponse = true
                    try await requestResponseAfterTools(generation: turn)
                } else { waitingSince = nil }
                refreshPhase()
                if records.count > 64 { records.removeFirst(records.count - 64) }
            case .failure(let error): throw error
            }
        } catch { await end("Ошибка Realtime", error: error) }
    }

    private func completeTool(_ call: RealtimeFunctionCall, result: Result<AssistantToolResult, Error>, generation: UUID) async {
        guard !stopped, turn == generation, !Task.isCancelled else { return }
        do {
            let output: String
            switch result {
            case .success(let reply):
                for source in reply.sources where !pendingSources.contains(where: { $0.url == source.url }) { pendingSources.append(source) }
                output = reply.output
                SessionLog.shared.record("realtime.tool.completed", "sources=\(reply.sources.count) webSearch=\(reply.usedWebSearch)")
            case .failure:
                output = "{\"ok\":false,\"error\":\"Действие не выполнено. Сообщи об этом пользователю, не подтверждай успех.\"}"
                SessionLog.shared.record("realtime.tool.failed")
            }
            try await client.submitFunctionOutput(callID: call.callID, output: output)
            guard !stopped, turn == generation, !Task.isCancelled else { return }
            tools[call.callID] = nil
            try await requestResponseAfterTools(generation: generation)
            refreshPhase()
        } catch {
            guard !stopped, turn == generation, !Task.isCancelled else { return }
            await end("Ошибка инструмента Realtime", error: error)
        }
    }

    private func requestResponseAfterTools(generation: UUID) async throws {
        guard toolsAwaitingResponse, tools.isEmpty, !stopped, turn == generation else { return }
        // Claim the continuation before any await, so response.done and the
        // last tool completion cannot both start a response.
        toolsAwaitingResponse = false
        if let instructionsProvider { try await client.updateInstructions(instructionsProvider()) }
        guard !stopped, turn == generation, !Task.isCancelled else { return }
        responseActive = true
        waitingSince = now
        try await client.requestResponse()
    }

    private func recordIndex(_ id: String, role: AssistantMessage.Role) throws -> Int {
        if let index = records.firstIndex(where: { $0.serverID == id }) { return index }
        records.append(Record(serverID: id, role: role))
        try onMessage?(records[records.count - 1].message, false)
        return records.count - 1
    }

    private func userRequest(for id: String?, generation: UUID, wait: Bool) async throws -> String {
        for _ in 0..<(wait ? 40 : 1) {
            try Task.checkCancellation()
            guard !stopped, turn == generation else { throw CancellationError() }
            if let record = records.last(where: { $0.serverID == id && $0.role == .user }), record.isFinal { return record.text }
            if wait { try await Task.sleep(for: .milliseconds(100)) }
        }
        return ""
    }

    private func safeToolName(_ value: String) -> String {
        ["web_search", "manage_memory", "manage_reminders", "end_voice_conversation"].contains(value) ? value : "unknown"
    }

    private func refreshPhase() {
        guard ready, canAcceptInput, readinessTask == nil else { return }
        if endState.shouldEnd(isPlaying: output.isPlaying, userSpeaking: userSpeaking, responseActive: responseActive),
           waitingSince == nil, tools.isEmpty {
            if endTask == nil {
                let generation = turn
                endTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let self, !self.stopped, self.turn == generation else { return }
                    self.endTask = nil
                    guard self.endState.shouldEnd(isPlaying: self.output.isPlaying, userSpeaking: self.userSpeaking, responseActive: self.responseActive),
                          self.waitingSince == nil, self.tools.isEmpty else { return }
                    if self.fallbackItemID != nil || self.semanticItemID != nil {
                        let saidFarewell = self.currentResponseHasAudio && self.records.contains {
                            self.responseItems.contains($0.serverID) && $0.role == .assistant && VoiceConversationEnd.containsFarewell($0.text)
                        }
                        if !saidFarewell {
                            guard !self.farewellRequested else {
                                await self.end("Не удалось попрощаться", error: VoiceError(message: "Сервис не воспроизвёл прощание выбранным голосом."))
                                return
                            }
                            let text = VoiceConversationEnd.farewell(for: self.fallbackItemID != nil ? self.fallbackUtterance : self.semanticUtterance)
                            self.farewellRequested = true
                            self.endState.request()
                            self.responseActive = true
                            self.waitingSince = self.now
                            do {
                                try await self.client.requestFarewell(text, turn: generation)
                                guard !self.stopped, self.turn == generation, !self.userSpeaking else { return }
                                self.refreshPhase()
                            } catch {
                                guard !self.stopped, self.turn == generation, !self.userSpeaking else { return }
                                await self.end("Не удалось попрощаться", error: VoiceError(message: "Сервис не воспроизвёл прощание выбранным голосом."))
                            }
                            return
                        }
                    }
                    await self.end("Разговор завершён")
                }
            }
            return
        }
        if userSpeaking {
            idleSince = nil
            onState?(.listening, "Слушаю")
        } else if output.isPlaying {
            idleSince = nil
            onState?(.speaking, "Отвечаю")
        } else if !tools.isEmpty {
            idleSince = nil
            onState?(.thinking, "Выполняю просьбу…")
        } else if responseActive || waitingSince != nil {
            idleSince = nil
            onState?(.thinking, "Думаю…")
        } else {
            if readinessCuePending, let onReadyAgain {
                readinessCuePending = false
                idleSince = nil
                onState?(.starting, "Готовлю микрофон…")
                readinessTask = Task { [weak self] in
                    do {
                        try await onReadyAgain()
                        guard let self, !self.stopped, !Task.isCancelled else { return }
                        self.readinessTask = nil
                        self.refreshPhase()
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let self, !self.stopped else { return }
                        self.readinessTask = nil
                        await self.end("Нет аудио", error: error)
                    }
                }
                return
            }
            if idleSince == nil { idleSince = now }
            onState?(.listening, "Слушаю")
        }
    }

    private func end(_ reason: String, error: Error? = nil) async {
        guard !stopped else { return }
        await onStop?(reason, error)
    }

    private struct VoiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
