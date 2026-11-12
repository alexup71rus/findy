import AVFoundation
import Foundation

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
    @Published private(set) var playingVoiceIdentifier: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
        // A preview is playback only. The system manages its session, and the
        // live microphone session is never started to audition a voice.
        synthesizer.usesApplicationAudioSession = false
    }

    func play(voiceIdentifier: String?, rate: Double) {
        stop()
        guard !VoiceSession.shared.isRunning,
              let voice = SpeechVoiceCatalog.shared.resolve(voiceIdentifier) else { return }
        let utterance = AVSpeechUtterance(string: "Привет! Я Findy. Давайте поговорим. Этот голос работает прямо на вашем iPhone.")
        utterance.voice = voice
        utterance.rate = Float(rate)
        currentUtterance = utterance
        playingVoiceIdentifier = voice.identifier
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        currentUtterance = nil
        isSpeaking = false
        playingVoiceIdentifier = nil
        synthesizer.stopSpeaking(at: .immediate)
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
