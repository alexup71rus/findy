import ActivityKit
import AVFoundation
import Combine
import Speech
import UIKit

private struct ChatFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// High-frequency telemetry is separate from the conversation's observable
/// state, so audio never causes the whole transcript to remeasure at 10 Hz.
@MainActor
final class VoiceActivityMeter: ObservableObject {
    static let shared = VoiceActivityMeter()
    @Published private(set) var level: Double = 0

    func update(decibels: Float) {
        // The existing audio monitor keeps running for Siri and background
        // speech. Only this visible artwork's publication pauses in background.
        guard UIApplication.shared.applicationState == .active else { reset(); return }
        let target = min(1, max(0, (Double(decibels) + 55) / 40))
        let smoothed = level + (target - level) * (target > level ? 0.72 : 0.35)
        if abs(smoothed - level) >= 0.012 || (target == 0 && level < 0.02) {
            level = target == 0 && smoothed < 0.02 ? 0 : smoothed
        }
    }

    func reset() {
        if level != 0 { level = 0 }
    }
}

@MainActor
final class VoiceSession: NSObject, ObservableObject {
    static let shared = VoiceSession()

    @Published private(set) var status = "Сессия не запущена"
    @Published private(set) var isRunning = false
    @Published private(set) var isSendingText = false
    @Published private(set) var isGeneratingImage = false
    private var imageProgressID: UUID?
    @Published private(set) var lastError: String?
    @Published private(set) var transcript = ""
    @Published private(set) var lastReply = ""
    var messages: [AssistantMessage] { timeline.messages }
    @Published private(set) var streamingReply: AssistantMessage?
    @Published private(set) var routeSummary = ""
    @Published private(set) var microphoneStatus = "Не проверено"
    @Published private(set) var speechStatus = "Не проверено"
    @Published private(set) var onDeviceStatus = "Не проверено"
    @Published private(set) var activitiesStatus = "Не проверено"
    @Published var soundCuesEnabled = UserDefaults.standard.object(forKey: "soundCuesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundCuesEnabled, forKey: "soundCuesEnabled") }
    }

    enum Phase { case idle, starting, listening, thinking, speaking, stopping }
    @Published private(set) var phase: Phase = .idle {
        didSet {
            if phase == .thinking { beginVoiceWaitingMusic() }
            else { WaitingMusicPlayer.shared.stop() }
        }
    }
    private var sessionID: UUID?
    private var turnID: UUID?
    private var engine: AVAudioEngine?
    private var earcons: VoiceEarcons?
    private var cueID: UUID?
    private var hasBeenReady = false
    private var endCuePermitted = false
    private let shutdownWaiters = VoiceShutdownWaiters()
    private var bridge: AudioInputBridge?
    private var realtimeVoice: RealtimeVoiceSession?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var activity: Activity<ChatActivityAttributes>?
    private var activityMonitor: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var clock = SilenceClock(now: 0)
    private var listeningStartedAt: TimeInterval = 0
    private var speakingStartedAt: TimeInterval = 0
    private var firstBufferLogged = false
    private var pendingTranscript = ""
    private var observerTokens: [NSObjectProtocol] = []
    private var audioSessionActivated = false
    private var inputTapInstalled = false
    private var startupTask: Task<Void, Never>?
    private var handoffBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var responseTask: Task<Void, Never>?
    private var textResponseTask: Task<Void, Never>?
    private var textRequestID: UUID?
    private var activeConfiguration: AssistantConfiguration?
    private var activeAPIKey = ""
    private var activeUsesProviderVoice = false
    private let timeline = ChatTimeline.shared
    private var timelineObservation: AnyCancellable?
    private var activeScope = "local"
    private var responseStartedAt: TimeInterval = 0
    private var speakingTimeout: TimeInterval = 30
    private var silenceTimeoutSeconds: TimeInterval = 5
    private var silenceEndReason: String { "\(Int(silenceTimeoutSeconds)) секунд тишины" }
    private var finishAfterSpeech: String?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var log: SessionLog { .shared }

    private override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        timelineObservation = timeline.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        observeSystemEvents()
    }

    func refreshReadiness() {
        microphoneStatus = AVAudioApplication.shared.recordPermission == .granted ? "Разрешён" : "Нет разрешения"
        speechStatus = SFSpeechRecognizer.authorizationStatus() == .authorized ? "Разрешено" : "Нет разрешения"
        let localRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
        onDeviceStatus = localRecognizer?.supportsOnDeviceRecognition == true ? "Доступен" : "Недоступен на устройстве"
        activitiesStatus = ActivityAuthorizationInfo().areActivitiesEnabled ? "Разрешены" : "Выключены"
    }

    func requestPermissions() async {
        guard UIApplication.shared.applicationState == .active, !isRunning else { return }
        _ = await AVAudioApplication.requestRecordPermission()
        if !AssistantSettings.shared.usesProviderVoice {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { value in continuation.resume(returning: value) }
            }
        }
        refreshReadiness()
        log.record("permissions.checked", "microphone=\(AVAudioApplication.shared.recordPermission.rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) onDevice=\(SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))?.supportsOnDeviceRecognition == true)")
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func clearConversation() {
        guard !isRunning, !isSendingText else { return }
        do {
            let scope = PersonalData.contextScope(settings: AssistantSettings.shared)
            try timeline.resetContext(scope: scope)
            try AssistantToolExecutor.clearIntent(scope: scope)
        }
        catch { lastError = error.localizedDescription; return }
        streamingReply = nil
        transcript = ""
        lastReply = ""
        lastError = nil
        status = "Готов к разговору"
    }

    @discardableResult
    func sendText(_ input: String, attachments: [AssistantAttachment] = []) -> Bool {
        let entered = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!entered.isEmpty || !attachments.isEmpty), !isSendingText, phase != .stopping else { return false }
        guard attachments.count <= ChatAttachments.maximumCount else { lastError = ChatAttachmentError.tooMany.localizedDescription; return false }
        if attachments.contains(where: \.isImage) && !AssistantSettings.shared.configuration.supportsImageInput {
            lastError = AssistantAttachmentError.unsupportedImages.localizedDescription; return false
        }
        let text = entered.isEmpty ? "Посмотри вложения." : entered
        guard text.count <= AssistantLimits.inputCharacters else { lastError = AssistantClientError.inputTooLong.localizedDescription; return false }
        do { _ = try PersonalData.shared.requireStore() }
        catch { lastError = error.localizedDescription; return false }
        let identifier = UUID()
        let userMessage = AssistantMessage(role: .user, text: text, attachments: attachments)
        let messageScope = PersonalData.contextScope(settings: AssistantSettings.shared)
        do { try persistMessage(userMessage, scope: messageScope) }
        catch {
            if (try? PersonalData.shared.requireStore().getMessage(id: userMessage.id)) != nil { try? timeline.deleteMessage(id: userMessage.id) }
            lastError = error.localizedDescription
            return false
        }
        let replyID = UUID()
        textRequestID = identifier
        VoicePreviewPlayer.shared.stop()
        isSendingText = true
        lastError = nil
        textResponseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.textRequestID == identifier {
                    WaitingMusicPlayer.shared.stop()
                    self.isSendingText = false
                    self.textRequestID = nil
                    self.textResponseTask = nil
                    self.activeAPIKey = ""
                    self.activeConfiguration = nil
                }
            }
            do {
                if self.isRunning { await self.stop(reason: "Переход к переписке") }
                try Task.checkCancellation()
                guard self.textRequestID == identifier else { return }
                try self.prepareAssistantConnection()
                WaitingMusicPlayer.shared.beginWaiting(voiceSession: false)
                self.status = "Думаю…"
                self.log.record("text.message.accepted", "characters=\(text.count)")
                let reply = try await self.makeAssistantReply { [weak self] snapshot in
                    await self?.presentStreamingReply(snapshot, id: replyID, textRequest: identifier)
                }
                try Task.checkCancellation()
                guard self.textRequestID == identifier else { return }
                self.streamingReply = nil
                try self.persistMessage(AssistantMessage(id: replyID, role: .assistant, text: ConversationRules.displayText(from: reply.text), sources: reply.sources))
                self.lastReply = reply.text
                self.status = "Готов к разговору"
            } catch is CancellationError {
                return
            } catch {
                guard self.textRequestID == identifier else { return }
                self.commitStreamingReply()
                // Keep the accepted draft visible even if configuration failed
                // before a request could be made.
                if (try? PersonalData.shared.requireStore().getMessage(id: userMessage.id)) == nil { try? self.persistMessage(userMessage) }
                self.lastError = error.localizedDescription
                self.status = "Не удалось получить ответ"
                self.log.record("text.request.failed", SessionLog.describe(error))
            }
        }
        return true
    }

    func cancelTextReply() {
        guard isSendingText else { return }
        WaitingMusicPlayer.shared.stop()
        imageProgressID = nil
        isGeneratingImage = false
        commitStreamingReply()
        textRequestID = nil
        textResponseTask?.cancel()
        textResponseTask = nil
        isSendingText = false
        activeAPIKey = ""
        activeConfiguration = nil
        status = "Запрос отменён"
        log.record("text.request.cancelled")
    }

    func start(source: String, deferAudio: Bool = false) async throws {
        while phase == .stopping { try await shutdownWaiters.wait() }
        try Task.checkCancellation()
        guard !isRunning else {
            log.record("session.alreadyRunning", "source=\(source)")
            return
        }
        cancelTextReply()
        VoicePreviewPlayer.shared.stop()
        WaitingMusicPlayer.shared.stop()
        lastError = nil
        hasBeenReady = false
        transcript = ""
        lastReply = ""
        routeSummary = ""
        silenceTimeoutSeconds = AssistantSettings.shared.silenceTimeoutSeconds
        clock = SilenceClock(now: now, timeout: silenceTimeoutSeconds)
        phase = .starting
        isRunning = true
        status = "Запускаю микрофон…"
        let identifier = UUID()
        sessionID = identifier
        log.record("session.start", "id=\(identifier) source=\(source) process=\(log.processID)")

        do {
            try prepareAssistantConnection()
            refreshReadiness()
            let usesRealtime = activeUsesProviderVoice
            guard AVAudioApplication.shared.recordPermission == .granted else {
                throw ChatFailure(message: "Откройте Findy на разблокированном iPhone и разрешите микрофон.")
            }
            if !usesRealtime {
                guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    throw ChatFailure(message: "Откройте Findy на разблокированном iPhone и разрешите микрофон и распознавание речи.")
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
                      recognizer.locale.language.languageCode?.identifier == "ru",
                      recognizer.supportsOnDeviceRecognition else {
                    throw ChatFailure(message: "На этом iPhone недоступно локальное распознавание русского языка. Серверное распознавание отключено.")
                }
                guard recognizer.isAvailable else {
                    throw ChatFailure(message: "Системное распознавание речи сейчас недоступно.")
                }
                guard SpeechVoiceCatalog.shared.resolve(AssistantSettings.shared.speechVoiceIdentifier) != nil else {
                    throw ChatFailure(message: "На iPhone недоступен русский системный голос.")
                }
                self.recognizer = recognizer
            }
            let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
            guard activitiesEnabled || (!deferAudio && UIApplication.shared.applicationState == .active) else {
                throw ChatFailure(message: "Включите Live Activities для Findy в настройках iPhone. iOS требует их для записи через App Intent.")
            }
            if activitiesEnabled {
                // Remove an indicator left behind by a previous process termination.
                for previous in Activity<ChatActivityAttributes>.activities {
                    await previous.end(nil, dismissalPolicy: .immediate)
                }
                try checkCurrent(identifier)
                let activity = try Activity.request(
                    attributes: ChatActivityAttributes(sessionID: identifier.uuidString),
                    content: ActivityContent(state: .init(status: "Запускаю микрофон…"), staleDate: nil),
                    pushType: nil
                )
                self.activity = activity
                log.record("activity.started", "id=\(activity.id)")
                monitorActivity(activity, session: identifier)
            }
            try checkCurrent(identifier)

            if deferAudio {
                try scheduleAudioAfterIntent(identifier)
                return
            }
            try await activateAudioAndListen(identifier)
        } catch {
            if sessionID == identifier {
                lastError = "\(error.localizedDescription)\n\(SessionLog.describe(error))"
                log.record("session.failed", SessionLog.describe(error))
                await stop(reason: "Ошибка запуска")
            }
            throw error
        }
    }

    private func prepareAssistantConnection() throws {
        let settings = AssistantSettings.shared
        guard settings.isConfiguredForChat else {
            throw ChatFailure(message: "Приложение не настроено. Откройте Findy и выберите провайдера и модель.")
        }
        _ = try PersonalData.shared.requireStore()
        activeScope = PersonalData.contextScope(settings: settings)
        activeUsesProviderVoice = settings.usesProviderVoice
        var configuration = settings.configuration
        guard settings.providerSharingAllowed else {
            throw ChatFailure(message: "Откройте Findy на разблокированном iPhone и разрешите передачу данных выбранному провайдеру.")
        }
        _ = try configuration.validatedEndpoint()
        activeAPIKey = try settings.apiKey()
        // Legacy prompts remain unchanged in storage; only the sent copy is bounded.
        configuration.systemPrompt = try PersonalData.shared.instructions(base: AssistantLimits.clipped(configuration.systemPrompt, to: AssistantLimits.systemPromptCharacters))
        activeConfiguration = configuration
    }

    private func persistMessage(_ message: AssistantMessage, scope: String? = nil) throws {
        let scope = scope ?? activeScope
        _ = try timeline.accept(message, scope: scope)
        try AssistantToolExecutor.registerUserMessage(message, scope: scope)
    }

    private func scheduleAudioAfterIntent(_ identifier: UUID) throws {
        handoffBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Siri audio handoff") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == identifier else { return }
                self.log.record("audio.handoff.expired")
                await self.stop(reason: "Система завершила время запуска")
            }
        }
        guard handoffBackgroundTask != .invalid else {
            throw ChatFailure(message: "iOS не предоставила время для передачи микрофона после Siri.")
        }
        log.record("audio.handoff.scheduled", "delay=1s")
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionID == identifier {
                    self.endHandoffBackgroundTask()
                    self.startupTask = nil
                }
            }
            do {
                try await Task.sleep(for: .seconds(1))
                try self.checkCurrent(identifier)
                self.log.record("audio.handoff.activating")
                try await self.activateAudioAndListen(identifier)
            } catch {
                guard self.sessionID == identifier else { return }
                await self.fail(error, reason: "Ошибка запуска после Siri")
            }
        }
    }

    private func endHandoffBackgroundTask() {
        guard handoffBackgroundTask != .invalid else { return }
        let identifier = handoffBackgroundTask
        handoffBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func activateAudioAndListen(_ identifier: UUID) async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
        log.record("audio.configuration", "category=playAndRecord mode=default allowBluetoothHFP=true mixWithOthers=true")
        // Siri or a phone call may temporarily own the route. Retry only a
        // short, bounded handoff; never change category to bypass a denial.
        for attempt in 1...8 {
            try checkCurrent(identifier)
            do {
                log.record("audio.activation.request", "attempt=\(attempt) category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) options=\(audioSession.categoryOptions.rawValue) routePolicy=\(audioSession.routeSharingPolicy.rawValue) otherAudio=\(audioSession.isOtherAudioPlaying)")
                try audioSession.setActive(true)
                audioSessionActivated = true
                break
            } catch {
                log.record("audio.activation.failed", "attempt=\(attempt) \(SessionLog.describe(error))")
                let value = error as NSError
                let transient = value.domain == NSOSStatusErrorDomain && [1936290409, 560557684, 561017449, 561015905].contains(value.code)
                guard transient, attempt < 8 else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        try checkCurrent(identifier)

        if let bluetooth = audioSession.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            do {
                try audioSession.setPreferredInput(bluetooth)
                log.record("audio.preferredInput", "input=\(bluetooth.portType.rawValue)")
            } catch {
                // iOS can withdraw a headset between discovery and selection.
                // Let the system choose another available microphone.
                try? audioSession.setPreferredInput(nil)
                log.record("audio.preferredInput.unavailable")
            }
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if activeUsesProviderVoice,
           audioSession.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }),
           audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            do {
                try input.setVoiceProcessingEnabled(true)
                log.record("audio.voiceProcessing.enabled")
            } catch {
                log.record("audio.voiceProcessing.unavailable", SessionLog.describe(error))
            }
        }
        earcons = VoiceEarcons(engine: engine)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ChatFailure(message: "iOS не предоставила доступный формат микрофона.")
        }
        if let configuration = activeConfiguration, activeUsesProviderVoice {
            let realtime = try RealtimeVoiceSession(engine: engine, format: format, configuration: configuration,
                apiKey: activeAPIKey, history: timeline.context(scope: activeScope, limit: configuration.contextMessageCount, includeAttachments: false), silenceTimeout: silenceTimeoutSeconds,
                tools: PersonalTools.definitions + ContextTools.definitions)
            self.realtimeVoice = realtime
            realtime.onState = { [weak self] phase, status in
                guard let self, self.sessionID == identifier, self.isRunning else { return }
                if self.phase != phase || self.status != status {
                    self.phase = phase
                    self.status = status
                    self.updateActivity(status)
                }
            }
            realtime.onReadyAgain = { [weak self, weak realtime] in
                guard let self, let realtime, self.sessionID == identifier, self.isRunning else { throw CancellationError() }
                try await self.ensureAudioCapture(engine, format: format, session: identifier) {
                    let snapshot = realtime.input.snapshot()
                    return (snapshot.buffers, snapshot.lastBufferAt)
                }
                try self.checkCurrent(identifier)
                guard realtime.canPlayReadyCue else { return }
                try await self.playReadyCue(session: identifier, allowSuperseded: true)
                try self.checkCurrent(identifier)
            }
            realtime.onLevel = { [weak self] decibels in
                guard let self, self.sessionID == identifier, self.isRunning else { return }
                VoiceActivityMeter.shared.update(decibels: self.phase == .listening || self.phase == .speaking ? decibels : -160)
            }
            realtime.onMessage = { [weak self] message, final in
                guard let self, self.sessionID == identifier, self.isRunning else { return }
                if message.text.isEmpty || final { try self.persistMessage(message) }
                if message.role == .assistant {
                    if final {
                        if self.streamingReply?.id == message.id { self.streamingReply = nil }
                        self.lastReply = message.text
                    } else if !message.text.isEmpty { self.streamingReply = message }
                }
            }
            realtime.onUserTranscript = { [weak self] text in self?.transcript = text }
            let key = activeAPIKey
            let scope = activeScope
            realtime.toolHandler = { [weak self] call, request in
                if call.name == "web_search" { await self?.playCue(.search, session: identifier) }
                return try await AssistantToolExecutor.execute(call, userRequest: request, scope: scope, configuration: configuration, apiKey: key)
            }
            let basePrompt = AssistantLimits.clipped(AssistantSettings.shared.configuration.systemPrompt, to: AssistantLimits.systemPromptCharacters)
            realtime.instructionsProvider = { try PersonalData.shared.instructions(base: basePrompt) }
            realtime.onStop = { [weak self] reason, error in
                guard let self, self.sessionID == identifier, self.isRunning else { return }
                if let error { await self.fail(error, reason: reason) }
                else { await self.stop(reason: reason) }
            }
            let realtimeInput = realtime.input
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in realtimeInput.consume(buffer) }
        } else {
            let bridge = AudioInputBridge()
            self.bridge = bridge
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in bridge.consume(buffer) }
        }
        inputTapInstalled = true
        engine.prepare()
        try engine.start()

        recordRoute("audio.route.started")
        firstBufferLogged = false
        if let realtimeVoice {
            // Do not open the paid provider connection until the audio graph
            // has demonstrated that the microphone is producing buffers.
            let captureSnapshot = {
                let snapshot = realtimeVoice.input.snapshot()
                return (snapshot.buffers, snapshot.lastBufferAt)
            }
            try await ensureAudioCapture(engine, format: format, session: identifier, snapshot: captureSnapshot)
            try await realtimeVoice.connect { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.ensureAudioCapture(engine, format: format, session: identifier, snapshot: captureSnapshot)
                try await self.playReadyCue(session: identifier)
                try self.checkCurrent(identifier)
            }
            try checkCurrent(identifier)
            hasBeenReady = true
            log.record("session.listening", "id=\(identifier) sampleRate=\(format.sampleRate) engine=realtime")
        } else {
            guard let bridge else { throw ChatFailure(message: "Микрофон недоступен.") }
            try await ensureAudioCapture(engine, format: format, session: identifier) {
                let snapshot = bridge.snapshot()
                return (snapshot.buffers, snapshot.lastBufferTime)
            }
            beginListening(deferActivation: true)
            try await playReadyCue(session: identifier)
            try checkCurrent(identifier)
            hasBeenReady = true
            activateListening()
            startTimer(for: identifier)
            log.record("session.listening", "id=\(identifier) sampleRate=\(format.sampleRate) onDevice=true")
        }
    }

    private func ensureAudioCapture(_ engine: AVAudioEngine, format: AVAudioFormat, session: UUID,
                                    snapshot: () -> (Int, TimeInterval)) async throws {
        let initialCount = snapshot().0
        var restartCount = 0
        var lastRestart: TimeInterval = 0
        for _ in 0..<25 {
            try checkCurrent(session)
            let current = engine.inputNode.outputFormat(forBus: 0)
            guard current.sampleRate == format.sampleRate, current.channelCount == format.channelCount,
                  current.commonFormat == format.commonFormat, current.isInterleaved == format.isInterleaved else {
                throw ChatFailure(message: "Аудиомаршрут изменился во время запуска. Повторите запуск разговора.")
            }
            if !engine.isRunning, restartCount < 3, lastRestart == 0 || now - lastRestart >= 0.25 {
                restartCount += 1
                lastRestart = now
                do {
                    engine.prepare()
                    try engine.start()
                    log.record("audio.engine.restarted", "attempt=\(restartCount)")
                } catch {
                    log.record("audio.engine.restartFailed", SessionLog.describe(error))
                }
            }
            let (count, lastBufferAt) = snapshot()
            if engine.isRunning, count > initialCount, now - lastBufferAt < 1 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatFailure(message: "Микрофон не отдаёт аудиобуферы. Повторите запуск разговора.")
    }

    private func playReadyCue(session: UUID, allowSuperseded: Bool = false) async throws {
        let played = await playCue(.ready, session: session)
        try checkCurrent(session)
        if !played, allowSuperseded, let realtimeVoice, realtimeVoice.canAcceptInput, !realtimeVoice.canPlayReadyCue {
            // A new turn superseded the cue; refreshPhase will publish that turn.
            return
        }
        guard played else { throw ChatFailure(message: "Не удалось воспроизвести сигнал готовности.") }
    }

    @discardableResult
    private func playCue(_ kind: VoiceEarcons.Kind, session: UUID) async -> Bool {
        guard !Task.isCancelled, sessionID == session, isRunning else { return false }
        if kind == .search, phase != .speaking { beginVoiceWaitingMusic() }
        guard soundCuesEnabled, let earcons else { return true }
        if realtimeVoice?.isUserSpeaking == true { return true }
        let token = UUID()
        cueID = token
        switch kind {
        case .ready: log.record("audio.cue.ready")
        case .search: log.record("audio.cue.search")
        case .end: log.record("audio.cue.end")
        }
        realtimeVoice?.input.setMuted(true)
        let played = await withTaskCancellationHandler {
            await earcons.play(kind, onPlayedBack: { [weak self] in
                guard kind == .ready, let self, self.cueID == token,
                      self.sessionID == session, self.isRunning,
                      self.realtimeVoice?.canAcceptInput != false else { return }
                // Open both gates in the playback completion callback, before
                // resuming the awaiting task; no post-cue quiet interval.
                self.realtimeVoice?.input.setMuted(false)
                self.bridge?.resumeRecognition()
                self.log.record("audio.cue.ready.completed")
            })
        } onCancel: { [weak self, weak earcons] in
            Task { @MainActor in
                guard self?.cueID == token else { return }
                earcons?.stop()
            }
        }
        guard played, !Task.isCancelled, cueID == token, sessionID == session, isRunning,
              realtimeVoice?.canAcceptInput != false else { return false }
        if kind != .ready {
            // Keep the established search/end acoustic-tail protection.
            await Task.detached { try? await Task.sleep(for: .milliseconds(60)) }.value
            guard !Task.isCancelled, cueID == token, sessionID == session, isRunning else { return false }
            realtimeVoice?.input.setMuted(false)
        }
        cueID = nil
        return true
    }

    private func checkCurrent(_ identifier: UUID) throws {
        guard sessionID == identifier, isRunning, !Task.isCancelled else { throw CancellationError() }
    }



    private func recordRoute(_ event: String, details: String = "") {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        let outputs = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        routeSummary = "Вход: \(inputs)\nВыход: \(outputs)"
        let inputTypes = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputTypes = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        log.record(event, "\(details) input=\(inputTypes) output=\(outputTypes) category=\(session.category.rawValue) sampleRate=\(session.sampleRate)")
    }

    private func beginListening(resetSilenceClock: Bool = true, deferActivation: Bool = false) {
        guard isRunning, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        let turn = UUID()
        turnID = turn
        pendingTranscript = ""
        bridge?.listen(using: request, initiallyPaused: deferActivation)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.turnID == turn, self.request === request else { return }
                guard self.phase == .listening else {
                    // A recognition task can fail before the ready cue finishes.
                    // Do not announce readiness for a failed, gated request.
                    if let error {
                        self.log.record("speech.failed", SessionLog.describe(error))
                        await self.fail(error, reason: "Ошибка распознавания")
                    }
                    return
                }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if text != self.pendingTranscript {
                        self.pendingTranscript = text
                        self.transcript = text
                        self.clock.heardSpeech(at: self.now)
                    }
                    if final {
                        self.speakReply()
                        return
                    }
                }
                if let error {
                    self.log.record("speech.failed", SessionLog.describe(error))
                    if !self.pendingTranscript.isEmpty {
                        self.speakReply()
                    } else {
                        await self.fail(error, reason: "Ошибка распознавания")
                    }
                }
            }
        }
        if !deferActivation { activateListening(resetSilenceClock: resetSilenceClock) }
        log.record("speech.turn.started", "turn=\(turn) requiresOnDeviceRecognition=true")
    }

    private func activateListening(resetSilenceClock: Bool = true) {
        guard isRunning, request != nil else { return }
        bridge?.resumeRecognition()
        phase = .listening
        status = "Слушаю"
        listeningStartedAt = now
        if resetSilenceClock { clock.resumedListening(at: now) }
        updateActivity(status)
    }

    private func startTimer(for identifier: UUID) {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.sessionID == identifier, self.isRunning else { return }
                let snapshot = self.bridge?.snapshot()
                // System TTS does not expose samples here, so its artwork uses
                // phase movement only; microphone energy is shown while listening.
                VoiceActivityMeter.shared.update(decibels: self.phase == .listening ? snapshot?.level ?? -160 : -160)
                if !self.firstBufferLogged, let snapshot, snapshot.buffers > 0 {
                    self.firstBufferLogged = true
                    self.log.record("audio.firstBuffer", "levelDB=\(snapshot.level)")
                }
                switch self.phase {
                case .listening:
                    if let snapshot, snapshot.lastEnergyTime > 0 {
                        self.clock.heardSpeech(at: snapshot.lastEnergyTime)
                    }
                    if (!self.firstBufferLogged && self.now - self.listeningStartedAt > 2)
                        || (self.firstBufferLogged && self.now - (snapshot?.lastBufferTime ?? 0) > 2) {
                        await self.fail(ChatFailure(message: "Микрофон не отдаёт аудиобуферы."), reason: "Нет аудио")
                        return
                    }
                    if self.clock.shouldEndSession(at: self.now) {
                        await self.stop(reason: self.silenceEndReason)
                        return
                    }
                    if !self.pendingTranscript.isEmpty, self.clock.shouldFinishUtterance(at: self.now) {
                        self.speakReply()
                    } else if self.now - self.listeningStartedAt > 50 {
                        // Keep individual Speech requests below their practical
                        // duration limit, including in a noisy environment.
                        if !self.pendingTranscript.isEmpty {
                            self.speakReply()
                        } else {
                            self.turnID = nil
                            self.request?.endAudio()
                            self.recognitionTask?.cancel()
                            self.recognitionTask = nil
                            self.request = nil
                            self.beginListening(resetSilenceClock: false)
                        }
                    }
                case .thinking:
                    if self.now - self.responseStartedAt > 60 {
                        self.responseTask?.cancel()
                        self.responseTask = nil
                        self.lastError = "Сервис не ответил за минуту."
                        self.speak("Сервис не ответил вовремя. Попробуйте ещё раз.", finishReason: "Время ожидания ответа истекло")
                    }
                case .speaking:
                    if self.now - self.speakingStartedAt > self.speakingTimeout {
                        await self.fail(ChatFailure(message: "Системный голос не завершил ответ вовремя."), reason: "Тайм-аут синтеза")
                        return
                    }
                default: break
                }
            }
        }
    }

    private func speakReply() {
        guard isRunning, phase == .listening, !pendingTranscript.isEmpty else { return }
        let text = pendingTranscript
        phase = .thinking
        responseStartedAt = now
        bridge?.pauseRecognition()
        turnID = nil
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        let userMessage = AssistantMessage(role: .user, text: text)
        do { try persistMessage(userMessage) }
        catch { Task { await self.fail(error, reason: "Не удалось сохранить реплику") }; return }
        status = "Думаю…"
        updateActivity("Думаю…")
        log.record("speech.recognized", "characters=\(text.count)")
        guard let identifier = sessionID else { return }
        let replyID = UUID()
        responseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.makeAssistantReply(voiceSession: identifier) { [weak self] snapshot in
                    await self?.presentStreamingReply(snapshot, id: replyID, voiceSession: identifier)
                }
                try Task.checkCancellation()
                guard self.sessionID == identifier, self.isRunning, self.phase == .thinking else { return }
                self.responseTask = nil
                self.streamingReply = nil
                try self.persistMessage(AssistantMessage(id: replyID, role: .assistant, text: ConversationRules.displayText(from: reply.text), sources: reply.sources))
                self.speak(reply.text, sourceURLs: reply.sources.map(\.url))
            } catch is CancellationError {
                return
            } catch {
                guard self.sessionID == identifier, self.isRunning, self.phase == .thinking else { return }
                self.responseTask = nil
                self.commitStreamingReply()
                self.lastError = error.localizedDescription
                self.log.record("assistant.request.failed", SessionLog.describe(error))
                self.speak("Не получилось получить ответ. \(error.localizedDescription)", finishReason: "Ошибка подключения к модели")
            }
        }
    }

    private func presentStreamingReply(_ reply: AssistantReply, id: UUID, textRequest: UUID? = nil, voiceSession: UUID? = nil) {
        if let textRequest, textRequestID != textRequest { return }
        if let voiceSession, sessionID != voiceSession || !isRunning { return }
        guard !reply.text.isEmpty else { return }
        if textRequest != nil { WaitingMusicPlayer.shared.stop() }
        streamingReply = AssistantMessage(id: id, role: .assistant, text: ConversationRules.displayText(from: reply.text), sources: reply.sources)
    }

    private func commitStreamingReply() {
        if let streamingReply, !streamingReply.text.isEmpty,
           !messages.contains(where: { $0.id == streamingReply.id }) {
            do { try persistMessage(streamingReply) }
            catch { lastError = error.localizedDescription }
        }
        streamingReply = nil
    }

    private func beginVoiceWaitingMusic() {
        // Realtime keeps its mic open for barge-in. AVAudioPlayer is outside
        // the voice-processing engine, so speaker playback is not guaranteed
        // to be cancelled by its AEC reference. Local recognition is paused
        // during thinking; realtime music requires an isolated headphone route.
        if realtimeVoice != nil {
            let isolated = AVAudioSession.sharedInstance().currentRoute.outputs.allSatisfy {
                [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType)
            }
            guard isolated, !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty else { return }
        }
        WaitingMusicPlayer.shared.beginWaiting(voiceSession: true)
    }

    private func beginTextSearchMusic() {
        guard isSendingText, !Task.isCancelled else { return }
        WaitingMusicPlayer.shared.beginWaiting(voiceSession: false)
    }

    private func withImageProgress<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let identifier = UUID()
        imageProgressID = identifier
        isGeneratingImage = true
        defer {
            if imageProgressID == identifier {
                imageProgressID = nil
                isGeneratingImage = false
            }
        }
        return try await operation()
    }

    private func makeAssistantReply(voiceSession: UUID? = nil, onUpdate: (@Sendable (AssistantReply) async -> Void)? = nil) async throws -> AssistantReply {
        // The same history, provider, cancellation, and decoding path serves
        // typed messages and recognized speech. Audio is handled by the caller.
        guard let configuration = activeConfiguration else {
            throw ChatFailure(message: "Выберите провайдера и модель в настройках.")
        }
        let context = try timeline.context(scope: activeScope, limit: configuration.contextMessageCount, includeAttachments: voiceSession == nil)
        #if DEBUG && targetEnvironment(simulator)
        // Isolated UI automation has no provider traffic. This hook is absent
        // from device and release builds and still exercises preparation,
        // sharing consent, message persistence and the normal reply lifecycle.
        if ProcessInfo.processInfo.arguments.contains("--ui-local-replies"),
           let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"],
           UUID(uuidString: value) != nil {
            if context.last?.text == "imagefixture" {
                try await withImageProgress {
                    try await Task.sleep(for: .seconds(3))
                    try Task.checkCancellation()
                    try GeneratedImages.saveFixture(scope: activeScope)
                }
            }
            let reply = AssistantReply(text: ConversationRules.reply(to: context.last?.text ?? ""))
            let characters = Array(reply.text)
            for step in 1...20 {
                try Task.checkCancellation()
                let count = max(1, characters.count * step / 20)
                await onUpdate?(AssistantReply(text: String(characters.prefix(count))))
                try await Task.sleep(for: .milliseconds(ProcessInfo.processInfo.arguments.contains("--ui-slow-stream") ? 400 : 100))
            }
            return reply
        }
        #endif
        let key = activeAPIKey
        let requestMessages = context
        let userRequest = context.last(where: { $0.role == .user })?.text ?? ""
        let tools = PersonalData.shared.tools(for: userRequest, realtime: configuration.apiStyle == .realtime) + ContextTools.definitions + (voiceSession == nil && configuration.supportsImageGeneration ? [GeneratedImages.tool] : [])
        let scope = activeScope
        let handler: AssistantToolHandler = { [weak self] call in
            if call.name == "web_search" {
                if let voiceSession { await self?.playCue(.search, session: voiceSession) }
                else { await self?.beginTextSearchMusic() }
            }
            if call.name == "generate_image", let self {
                return try await self.withImageProgress {
                    try await AssistantToolExecutor.execute(call, userRequest: userRequest, scope: scope, configuration: configuration, apiKey: key)
                }
            }
            return try await AssistantToolExecutor.execute(call, userRequest: userRequest, scope: scope, configuration: configuration, apiKey: key)
        }
        let client = AssistantClient()
        let searchCue: (@Sendable () async -> Void)?
        if let voiceSession {
            searchCue = { [weak self] in await self?.playCue(.search, session: voiceSession) }
        } else {
            searchCue = { [weak self] in await self?.beginTextSearchMusic() }
        }
        log.record("assistant.request.started", "api=\(configuration.apiStyle.rawValue) searchEnabled=\(configuration.webSearchEnabled) contextMessages=\(requestMessages.count)")
        let reply = try await withThrowingTaskGroup(of: AssistantReply.self) { group in
            group.addTask {
                if configuration.apiStyle == .realtime {
                    return try await RealtimeTextReply.reply(configuration: configuration, apiKey: key, messages: requestMessages, tools: tools, toolHandler: handler, onUpdate: onUpdate)
                }
                return try await client.reply(configuration: configuration, apiKey: key, messages: requestMessages, tools: tools, toolHandler: handler, onWebSearchStarted: searchCue, onUpdate: onUpdate)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(configuration.supportsImageGeneration ? 300 : 60))
                throw AssistantClientError.requestTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
        try Task.checkCancellation()
        log.record("assistant.response.completed", "characters=\(reply.text.count) sources=\(reply.sources.count) webSearch=\(reply.usedWebSearch)")
        return reply
    }

    private func speak(_ text: String, sourceURLs: [URL] = [], finishReason: String? = nil) {
        guard isRunning else { return }
        let spoken = ConversationRules.spokenText(from: text, sourceURLs: sourceURLs)
        lastReply = text
        phase = .speaking
        speakingStartedAt = now
        speakingTimeout = max(30, Double(spoken.count) / 7 + 15)
        finishAfterSpeech = finishReason
        status = "Отвечаю"
        updateActivity("Отвечаю")
        log.record("tts.requested", "characters=\(spoken.count)")
        let utterance = AVSpeechUtterance(string: spoken)
        let settings = AssistantSettings.shared
        let voice = SpeechVoiceCatalog.shared.resolve(settings.speechVoiceIdentifier)
        utterance.voice = voice
        utterance.rate = Float(settings.speechRate)
        if let voice {
            log.record("tts.voice", "quality=\(voice.quality.rawValue) rate=\(settings.speechRate)")
        }
        self.utterance = utterance
        synthesizer.speak(utterance)
    }

    private func updateActivity(_ status: String) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: .init(status: status), staleDate: nil)) }
    }

    private func monitorActivity(_ activity: Activity<ChatActivityAttributes>, session: UUID) {
        activityMonitor = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.log.record("activity.state", "value=\(state)")
                if state == .dismissed || state == .ended {
                    await self.stop(reason: "Live Activity завершена")
                    return
                }
            }
        }
    }

    private func fail(_ error: Error, reason: String, playEndCue: Bool = true) async {
        lastError = "\(error.localizedDescription)\n\(SessionLog.describe(error))"
        log.record("session.failed", SessionLog.describe(error))
        await stop(reason: reason, playEndCue: playEndCue)
    }

    func stop(reason: String, playEndCue: Bool = true) async {
        guard isRunning else { return }
        let identifier = sessionID
        let shouldPlayEnd = playEndCue && hasBeenReady && soundCuesEnabled && audioSessionActivated
            && engine?.isRunning == true && !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
        endCuePermitted = shouldPlayEnd
        hasBeenReady = false
        shutdownWaiters.begin()
        phase = .stopping
        VoiceActivityMeter.shared.reset()
        isRunning = false
        sessionID = nil
        commitStreamingReply()
        responseTask?.cancel()
        responseTask = nil
        activeAPIKey = ""
        activeConfiguration = nil
        finishAfterSpeech = nil
        startupTask?.cancel()
        startupTask = nil
        endHandoffBackgroundTask()
        cueID = nil
        earcons?.stop()
        timerTask?.cancel()
        timerTask = nil
        activityMonitor?.cancel()
        activityMonitor = nil
        bridge?.pauseRecognition()
        turnID = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        let endingRealtime = realtimeVoice
        realtimeVoice = nil
        if let endingRealtime { await endingRealtime.stop() }
        if endCuePermitted, engine?.isRunning == true,
           !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty, let earcons {
            log.record("audio.cue.end")
            // A timer or Live Activity monitor can be stopping its own task.
            // This unstructured task is independent of that cancellation.
            let cue = Task { @MainActor in await earcons.play(.end, timeout: .milliseconds(350)) }
            _ = await cue.value
        }
        earcons?.stop()
        earcons = nil
        endCuePermitted = false
        if let engine {
            engine.stop()
            if inputTapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        inputTapInstalled = false
        engine = nil
        bridge = nil
        recognizer = nil
        if audioSessionActivated {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { log.record("audio.deactivation.failed", SessionLog.describe(error)) }
            audioSessionActivated = false
        }
        let endingActivity = activity
        activity = nil
        log.record("session.stopped", "id=\(identifier?.uuidString ?? "none") reason=\(reason)")
        if let endingActivity { await endingActivity.end(nil, dismissalPolicy: .immediate) }
        phase = .idle
        status = "Завершено: \(reason)"
        shutdownWaiters.finish()
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.activity == nil else { return }
                await self.stop(reason: "Для работы в фоне нужна Live Activity")
            }
        })
        observerTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.phase == .stopping, type == AVAudioSession.InterruptionType.began.rawValue {
                    self.endCuePermitted = false
                    self.earcons?.stop()
                    return
                }
                guard self.isRunning else { return }
                self.log.record("audio.interruption", "type=\(type.map(String.init) ?? "unknown")")
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    await self.stop(reason: "Аудио прервано системой", playEndCue: false)
                }
            }
        })
        observerTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.phase == .stopping, AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty {
                    self.endCuePermitted = false
                    self.earcons?.stop()
                    return
                }
                guard self.isRunning else { return }
                self.recordRoute("audio.route.changed", details: "code=\(reason.map(String.init) ?? "0")")
            }
        })
        for (name, event) in [
            (AVAudioSession.mediaServicesWereResetNotification, "audio.mediaServicesReset"),
            (Notification.Name.AVAudioEngineConfigurationChange, "audio.engineConfigurationChanged")
        ] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.phase == .stopping {
                        self.endCuePermitted = false
                        self.earcons?.stop()
                        return
                    }
                    guard self.isRunning, self.phase != .starting else { return }
                    self.log.record(event)
                    if name == .AVAudioEngineConfigurationChange, self.engine?.isRunning == true { return }
                    await self.fail(ChatFailure(message: "Аудиосистема изменила конфигурацию. Повторите запуск."), reason: event, playEndCue: false)
                }
            })
        }
        for (name, event) in [
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "app.protectedDataWillLock"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "app.protectedDataAvailable")
        ] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in SessionLog.shared.record(event) }
            })
        }
    }
}

extension VoiceSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.utterance === utterance else { return }
            self.recordRoute("tts.started")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.utterance === utterance else { return }
            self.utterance = nil
            let session = self.sessionID
            self.log.record("tts.finished")
            if let reason = self.finishAfterSpeech {
                self.finishAfterSpeech = nil
                await self.stop(reason: reason)
                return
            }
            // Ignore the output tail, then create a fresh recognition request.
            try? await Task.sleep(for: .milliseconds(200))
            guard self.isRunning, self.sessionID == session, self.phase == .speaking else { return }
            guard let session, let engine = self.engine, let bridge = self.bridge else { return }
            do {
                let format = engine.inputNode.outputFormat(forBus: 0)
                try await self.ensureAudioCapture(engine, format: format, session: session) {
                    let snapshot = bridge.snapshot()
                    return (snapshot.buffers, snapshot.lastBufferTime)
                }
                guard self.isRunning, self.sessionID == session, self.phase == .speaking else { return }
                self.beginListening(deferActivation: true)
                try await self.playReadyCue(session: session)
                guard self.isRunning, self.sessionID == session, self.phase == .speaking else { return }
                self.activateListening()
            } catch is CancellationError { return }
            catch { await self.fail(error, reason: "Нет аудио") }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning, self.utterance === utterance else { return }
            await self.fail(ChatFailure(message: "Синтез речи прерван системой."), reason: "Ответ прерван")
        }
    }
}
