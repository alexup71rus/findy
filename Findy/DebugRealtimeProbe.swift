#if DEBUG
import AVFoundation
import Foundation

/// An explicit Xcode launch argument checks the real device's saved connection
/// without exporting its Keychain credential or starting its microphone.
@MainActor
enum DebugRealtimeProbe {
    private static var ran = false
    private static var microphoneProbeRan = false

    /// Explicit diagnostic only: observes callback counts, never stores or
    /// transmits samples, and does not call a model or a network service.
    static func runMicrophoneGraphIfRequested() async {
        guard !microphoneProbeRan, ProcessInfo.processInfo.arguments.contains("--microphone-graph-probe") else { return }
        microphoneProbeRan = true
        guard AVAudioApplication.shared.recordPermission == .granted else {
            SessionLog.shared.record("audio.probe.noPermission")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }),
                  session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                SessionLog.shared.record("audio.probe.notBuiltin")
                return
            }
            SessionLog.shared.record("audio.probe.started", "sampleRate=\(session.sampleRate)")
            for (event, action) in [
                ("audio.probe.engine.baseline", 0),
                ("audio.probe.engine.restart", 1),
                ("audio.probe.engine.finiteCue", 2),
                ("audio.probe.engine.settle", 3)
            ] {
                do {
                    guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }),
                          session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                        SessionLog.shared.record("audio.probe.notBuiltin")
                        break
                    }
                    try await microphoneProbe(event: event, action: action)
                } catch {
                    SessionLog.shared.record(event + ".failed", SessionLog.describe(error))
                }
            }
            SessionLog.shared.record("audio.probe.completed")
        } catch {
            SessionLog.shared.record("audio.probe.failed", SessionLog.describe(error))
        }
    }

    private static func microphoneProbe(event: String, action: Int) async throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        if action == 3 { try await Task.sleep(for: .milliseconds(300)) }
        // Match the production output graph: one player for cues and one for
        // streamed PCM. Neither player is scheduled or started in this probe.
        let cues = AVAudioPlayerNode()
        let output = AVAudioPlayerNode()
        engine.attach(cues)
        engine.attach(output)
        let playback = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.connect(cues, to: engine.mainMixerNode, format: playback)
        engine.connect(output, to: engine.mainMixerNode, format: playback)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ProbeError.invalidFormat }
        let converter = try RealtimeAudioInput(format: format, initiallyMuted: true)
        let counts = MicrophoneProbeCounts()
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in counts.changed() }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            counts.raw()
            converter.consume(buffer)
            counts.converted()
        }
        defer {
            engine.stop()
            input.removeTap(onBus: 0)
            converter.stop()
            NotificationCenter.default.removeObserver(observer)
        }
        engine.prepare()
        if action == 2 {
            let signal = VoiceEarcons.waveform(.ready)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: AVAudioFrameCount(signal.count)),
                  let samples = buffer.floatChannelData?.pointee else { throw ProbeError.invalidFormat }
            buffer.frameLength = AVAudioFrameCount(signal.count)
            for (index, sample) in signal.enumerated() { samples[index] = sample }
            cues.scheduleBuffer(buffer, completionHandler: nil)
        }
        try engine.start()
        let runningInitially = engine.isRunning
        if action == 2 { cues.play() }
        if action == 1 {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(250))
                if !engine.isRunning { engine.prepare(); try engine.start() }
            }
            try await Task.sleep(for: .seconds(1))
        } else {
            try await Task.sleep(for: .seconds(2))
        }
        let snapshot = counts.snapshot()
        let flags = (input.isVoiceProcessingEnabled ? 1 : 0)
            | (engine.outputNode.isVoiceProcessingEnabled ? 2 : 0)
            | (input.isVoiceProcessingInputMuted ? 4 : 0)
            | (input.isVoiceProcessingBypassed ? 8 : 0)
            | (engine.isRunning ? 16 : 0)
            | (runningInitially ? 32 : 0)
        SessionLog.shared.record(event, "count=\(snapshot.raw) chunks=\(snapshot.converted) removed=\(snapshot.changes) sampleRate=\(format.sampleRate) code=\(flags) options=\(AVAudioSession.sharedInstance().categoryOptions.rawValue)")
    }

    private enum ProbeError: Error { case invalidFormat }

    private final class MicrophoneProbeCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var rawCount = 0
        private var convertedCount = 0
        private var changeCount = 0
        func raw() { lock.lock(); rawCount += 1; lock.unlock() }
        func converted() { lock.lock(); convertedCount += 1; lock.unlock() }
        func changed() { lock.lock(); changeCount += 1; lock.unlock() }
        func snapshot() -> (raw: Int, converted: Int, changes: Int) {
            lock.lock(); defer { lock.unlock() }
            return (rawCount, convertedCount, changeCount)
        }
    }

    static func runIfRequested() async {
        guard !ran, ProcessInfo.processInfo.arguments.contains("--realtime-self-test") else { return }
        ran = true
        let settings = AssistantSettings.shared
        guard settings.isConfiguredForChat, settings.providerSharingAllowed, settings.configuration.apiStyle == .realtime else { return }
        do {
            let configuration = settings.configuration
            let key = try settings.apiKey()
            var simple = configuration
            simple.webSearchEnabled = false
            let updates = ProbeUpdates()
            SessionLog.shared.record("realtime.probe.started", "model=\(simple.model) voice=\(simple.realtimeVoice)")
            let text = try await RealtimeTextReply.reply(configuration: simple, apiKey: key,
                messages: [.init(role: .user, text: "Ответь двумя словами: Проверка прошла.")], onUpdate: { snapshot in
                    await updates.receive(snapshot)
                })
            let count = await updates.count
            guard count > 0, !text.text.isEmpty else { throw AssistantClientError.emptyResponse }
            SessionLog.shared.record("realtime.probe.text.pass", "updates=\(count) characters=\(text.text.count)")

            let audio = try await audioProbe(configuration: simple, apiKey: key)
            SessionLog.shared.record("realtime.probe.audio.pass", "chunks=\(audio.chunks) pcmBytes=\(audio.bytes) transcriptCharacters=\(audio.characters)")

            if configuration.webSearchEnabled {
                let search = try await RealtimeTextReply.reply(configuration: configuration, apiKey: key,
                    messages: [.init(role: .user, text: "Используй инструмент web_search: найди на официальном сайте Apple текущие модели iPhone. Ответь кратко, назови одну модель и источник.")])
                guard search.usedWebSearch, !search.sources.isEmpty else { throw AssistantClientError.failedResponse }
                SessionLog.shared.record("realtime.probe.search.pass", "sources=\(search.sources.count) characters=\(search.text.count)")
            }
            SessionLog.shared.record("realtime.probe.completed")
        } catch {
            SessionLog.shared.record("realtime.probe.failed", SessionLog.describe(error))
        }
    }

    private static func audioProbe(configuration: AssistantConfiguration, apiKey: String) async throws -> AudioProbe.State {
        let client = RealtimeClient()
        let collector = AudioProbe()
        do {
            try await client.connect(configuration: configuration, apiKey: apiKey, outputAudio: true) { event in
                await collector.receive(event)
            }
            try await client.sendText("Скажи по-русски ровно: Привет! Я Findy.")
            for _ in 0..<300 {
                try await Task.sleep(for: .milliseconds(100))
                let state = await collector.state
                if let error = state.error { throw error }
                if state.done {
                    guard state.chunks > 0, state.bytes > 0, state.characters > 0 else { throw AssistantClientError.emptyResponse }
                    await client.close()
                    return state
                }
            }
            throw AssistantClientError.requestTimedOut
        } catch {
            await client.close()
            throw error
        }
    }

    private actor ProbeUpdates {
        var count = 0
        func receive(_ reply: AssistantReply) { if !reply.text.isEmpty { count += 1 } }
    }

    private actor AudioProbe {
        struct State: Sendable {
            var chunks = 0
            var bytes = 0
            var characters = 0
            var done = false
            var error: RealtimeClientError?
        }
        var state = State()
        func receive(_ event: RealtimeEvent) {
            switch event {
            case .audioDelta(_, _, let data): state.chunks += 1; state.bytes += data.count
            case .outputTranscript(_, let text, _): state.characters = text.count
            case .responseDone(let result):
                state.done = result.status == .completed
                if !state.done { state.error = result.error ?? .serverError }
            case .failure(let error): state.error = error
            default: break
            }
        }
    }
}
#endif
