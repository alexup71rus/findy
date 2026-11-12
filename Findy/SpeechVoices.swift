import AVFoundation
import Foundation
import UIKit

@MainActor
final class SpeechVoiceCatalog: ObservableObject {
    static let shared = SpeechVoiceCatalog()

    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        voices = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language.lowercased().split(separator: "-").first == "ru"
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.voiceTraits.contains(.isPersonalVoice)
            }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                return nameOrder == .orderedSame ? $0.identifier < $1.identifier : nameOrder == .orderedAscending
            }
    }

    func resolve(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        if voices.isEmpty { refresh() }
        if let identifier, let voice = voices.first(where: { $0.identifier == identifier }) {
            return voice
        }
        return voices.first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    func summary(_ identifier: String?) -> String {
        let voice = identifier.flatMap { id in voices.first { $0.identifier == id } } ?? voices.first
        guard let voice else { return "Нет установленного русского голоса" }
        let prefix = identifier == nil ? "Авто · " : ""
        return "\(prefix)\(voice.name) · \(Self.qualityName(voice.quality))"
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Премиум"
        case .enhanced: return "Улучшенный"
        case .default: return "Стандартный"
        @unknown default: return "Системный"
        }
    }
}

@MainActor
final class VoicePreviewPlayer: NSObject, ObservableObject {
    static let shared = VoicePreviewPlayer()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isLoading = false
    @Published private(set) var playingVoiceIdentifier: String?
    @Published private(set) var errorMessage: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var token: UUID?
    private var client: RealtimeClient?
    private var requestTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var output: RealtimeAudioOutput?
    private var ownsAudioSession = false
    private var responseFinished = false
    private var receivedAudio = false
    private var sourceConfiguration: AssistantConfiguration?
    private var sourceProviderID: UUID?
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
        // System speech manages its own playback-only audio session.
        synthesizer.usesApplicationAudioSession = false
        for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            })
        }
    }

    private var canPlay: Bool {
        !VoiceSession.shared.isRunning && !VoiceSession.shared.isSendingText
            && UIApplication.shared.applicationState == .active
    }

    static func providerIdentifier(_ voice: String) -> String { "provider:" + voice }
    private static func phrase(_ name: String) -> String { "Привет! Я \(name). Чем займёмся?" }

    func play(voiceIdentifier: String?, rate: Double) {
        stop()
        guard canPlay else { return }
        let catalog = SpeechVoiceCatalog.shared
        let voice = voiceIdentifier.flatMap { id in catalog.voices.first { $0.identifier == id } }
            ?? (voiceIdentifier == nil ? catalog.resolve(nil) : nil)
        guard let voice else {
            errorMessage = "Этот голос недоступен. Загрузите его в настройках iPhone."
            return
        }
        let utterance = AVSpeechUtterance(string: Self.phrase(voice.name))
        utterance.voice = voice
        utterance.rate = Float(rate)
        currentUtterance = utterance
        playingVoiceIdentifier = voice.identifier
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func playProvider(voice: String) {
        stop()
        let settings = AssistantSettings.shared
        guard canPlay, settings.usesProviderVoice, settings.selectedProvider != nil else { return }
        SessionLog.shared.record("voice.preview.started")
        sourceConfiguration = settings.configuration
        sourceProviderID = settings.selectedProvider?.id
        var configuration = settings.configuration
        configuration.realtimeVoice = voice
        let apiKey: String
        do { apiKey = try settings.apiKey() }
        catch { fail(error.localizedDescription); return }
        let client = RealtimeClient()
        let token = UUID()
        self.client = client
        self.token = token
        playingVoiceIdentifier = Self.providerIdentifier(voice)
        isSpeaking = true
        isLoading = true
        let phrase = Self.phrase(OpenAIRealtimeVoiceOptions.title(for: voice))
        requestTask = Task { [weak self] in
            do {
                try await client.connect(configuration: configuration, apiKey: apiKey, outputAudio: true, voicePreview: true) { [weak self] event in
                    await self?.receive(event, token: token)
                }
                try Task.checkCancellation()
                guard let self, self.isCurrent(token) else { await client.close(); return }
                try await client.requestVoicePreview(phrase)
            } catch is CancellationError { return }
            catch {
                guard let self, self.isCurrent(token) else { return }
                self.fail("Не удалось послушать голос. " + error.localizedDescription)
            }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard let self, self.isCurrent(token) else { return }
            self.fail("Пример голоса не загрузился вовремя. Попробуйте ещё раз.")
        }
    }

    /// Invalidates callbacks before closing the socket. A stopped or replaced
    /// preview can never schedule more audio, even while connecting.
    func stop() {
        token = nil
        requestTask?.cancel()
        requestTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let endingClient = client
        client = nil
        if let endingClient { Task { await endingClient.close() } }
        output?.stop()
        output = nil
        engine?.stop()
        engine = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isLoading = false
        playingVoiceIdentifier = nil
        errorMessage = nil
        sourceConfiguration = nil
        sourceProviderID = nil
        responseFinished = false
        receivedAudio = false
    }

    private func isCurrent(_ token: UUID) -> Bool {
        guard self.token == token else { return false }
        let settings = AssistantSettings.shared
        guard canPlay, settings.usesProviderVoice,
              sourceConfiguration == settings.configuration,
              sourceProviderID == settings.selectedProvider?.id else {
            stop()
            return false
        }
        return true
    }

    private func receive(_ event: RealtimeEvent, token: UUID) {
        guard isCurrent(token) else { return }
        do {
            switch event {
            case .audioDelta(let itemID, let index, let data):
                if output == nil { try preparePlayback(token: token) }
                try output?.append(data, itemID: itemID, contentIndex: index)
                if !receivedAudio { SessionLog.shared.record("voice.preview.firstAudio") }
                receivedAudio = true
                isLoading = false
            case .responseDone(let completion):
                guard completion.status == .completed, !completion.hasFunctionCalls, receivedAudio else {
                    fail("Провайдер не вернул пример голоса. Попробуйте ещё раз.")
                    return
                }
                responseFinished = true
                let endingClient = client
                client = nil
                if let endingClient { Task { await endingClient.close() } }
                if output?.isPlaying != true { completePreview() }
            case .functionCall:
                fail("Провайдер не вернул пример голоса. Попробуйте ещё раз.")
            case .failure(let error):
                fail("Не удалось послушать голос. " + error.localizedDescription)
            default: break
            }
        } catch {
            fail("Не удалось воспроизвести пример голоса.")
        }
    }

    private func preparePlayback(token: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        ownsAudioSession = true
        let engine = AVAudioEngine()
        let output = RealtimeAudioOutput(engine: engine)
        output.onDrained = { [weak self] in
            guard let self, self.isCurrent(token), self.responseFinished else { return }
            self.completePreview()
        }
        self.engine = engine
        self.output = output
        engine.prepare()
        try engine.start()
    }

    private func completePreview() {
        SessionLog.shared.record("voice.preview.completed")
        stop()
    }

    private func fail(_ message: String) {
        SessionLog.shared.record("voice.preview.failed")
        stop()
        errorMessage = message
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        currentUtterance = nil
        isSpeaking = false
        playingVoiceIdentifier = nil
    }
}

extension VoicePreviewPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }
}
