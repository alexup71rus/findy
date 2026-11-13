import AVFoundation
import SwiftUI

/// Local playback never changes a running microphone session's category or route.
@MainActor
final class WaitingMusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = WaitingMusicPlayer()
    static let tracks = ["Лифт · Vanoss", "Лифт · 2", "Лифт · 3"]
    private static let files = ["waiting-1", "waiting-2", "waiting-3"]
    @Published var selection: Int = UserDefaults.standard.integer(forKey: "waitingMusicSelection") {
        didSet { UserDefaults.standard.set(selection, forKey: "waitingMusicSelection"); stop() }
    }
    @Published private(set) var previewing: Int?
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?
    private var ownsSession = false
    private var nextTrack = 0
    private var waiting = false
    private var observer: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason != .categoryChange else { return }
            Task { @MainActor in self?.stop() }
        }
    }

    func beginWaiting(voiceSession: Bool) {
        guard selection != 0, !waiting else { return }
        stop()
        waiting = true
        let index: Int
        switch selection {
        case 1...3: index = selection - 1
        case 4: index = nextTrack; nextTrack = (nextTrack + 1) % Self.tracks.count
        default: index = Int.random(in: Self.tracks.indices)
        }
        play(index, configureSession: !voiceSession)
    }

    func preview(_ index: Int) {
        if previewing == index { stop(); return }
        VoicePreviewPlayer.shared.stop()
        stop()
        previewing = index
        play(index, configureSession: true)
    }

    private func play(_ index: Int, configureSession: Bool) {
        errorMessage = nil
        guard Self.files.indices.contains(index), let url = Bundle.main.url(forResource: Self.files[index], withExtension: "mp3") else {
            errorMessage = "Музыка недоступна."; stop(); return
        }
        do {
            if configureSession {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                ownsSession = true
            }
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self
            audio.volume = 0.18
            audio.numberOfLoops = previewing == nil ? -1 : 0
            player = audio
            guard audio.play() else { throw CocoaError(.fileReadUnknown) }
        } catch {
            errorMessage = "Не удалось включить музыку: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        waiting = false
        previewing = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === player { self.stop() } }
    }
}

@MainActor
struct WaitingMusicSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var music = WaitingMusicPlayer.shared
    @ObservedObject private var session = VoiceSession.shared
    private var busy: Bool { session.isRunning || session.isSendingText || session.phase != .idle }
    var body: some View {
        List {
            Section {
                Picker("Музыка ожидания", selection: $music.selection) {
                    Text("Нет").tag(0)
                    ForEach(WaitingMusicPlayer.tracks.indices, id: \.self) { index in
                        Text(WaitingMusicPlayer.tracks[index]).tag(index + 1)
                    }
                    Text("По очереди").tag(4)
                    Text("Случайно").tag(5)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("waiting-music-selection")
            } footer: {
                Text("Тихо играет, пока Findy готовит ответ или ищет информацию. Перед голосовым ответом музыка останавливается. С голосом провайдера музыка играет только в наушниках, чтобы микрофон не принял её за речь. В режимах «По очереди» и «Случайно» новый трек выбирается для каждого ожидания.")
            }
            Section("Послушать") {
                ForEach(WaitingMusicPlayer.tracks.indices, id: \.self) { index in
                    Button { music.preview(index) } label: {
                        HStack {
                            Text(WaitingMusicPlayer.tracks[index])
                            Spacer()
                            Image(systemName: music.previewing == index ? "stop.fill" : "play.fill")
                        }
                    }
                    .accessibilityLabel(music.previewing == index ? "Остановить \(WaitingMusicPlayer.tracks[index])" : "Послушать \(WaitingMusicPlayer.tracks[index])")
                }
            }
            if let error = music.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .disabled(busy)
        .navigationTitle("Музыка ожидания")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if music.previewing != nil { music.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active && music.previewing != nil { music.stop() } }
        .onChange(of: busy) { _, busy in if busy && music.previewing != nil { music.stop() } }
    }
}
