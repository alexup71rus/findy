import AVFoundation
import SwiftUI

@MainActor
struct SpeechSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = AssistantSettings.shared
    @ObservedObject private var catalog = SpeechVoiceCatalog.shared
    @ObservedObject private var preview = VoicePreviewPlayer.shared
    @ObservedObject private var session = VoiceSession.shared

    @State private var voiceError = ""
    @State private var voiceErrorTitle = "Не удалось выбрать голос"
    @State private var showingVoiceError = false

    private var usesProviderVoice: Bool { settings.usesProviderVoice }
    private var editingDisabled: Bool { session.isRunning || session.isSendingText }

    var body: some View {
        List {
            modeSection
            if usesProviderVoice {
                realtimeSections
            } else {
                localSections
            }
        }
        .navigationTitle("Озвучивание")
        .navigationBarTitleDisplayMode(.inline)
        .alert(voiceErrorTitle, isPresented: $showingVoiceError) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(voiceError)
        }
        .onChange(of: preview.errorMessage) { _, error in
            guard let error else { return }
            voiceErrorTitle = "Не удалось послушать голос"
            voiceError = error
            showingVoiceError = true
        }
        .onChange(of: showingVoiceError) { _, showing in
            if !showing { preview.stop() }
        }
        .onAppear {
            WaitingMusicPlayer.shared.stop()
            if usesProviderVoice { preview.stop() } else { catalog.refresh() }
        }
        .onDisappear { preview.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !usesProviderVoice { catalog.refresh() } else { preview.stop() }
        }
        .onChange(of: session.isRunning) { _, running in if running { preview.stop() } }
        .onChange(of: session.isSendingText) { _, sending in if sending { preview.stop() } }
        .onChange(of: settings.configuration) { _, _ in preview.stop() }
        .onChange(of: settings.selectedModel) { _, _ in preview.stop() }
        .onChange(of: settings.speechVoiceIdentifier) { _, _ in preview.stop() }
        .onChange(of: usesProviderVoice) { _, providerVoice in
            preview.stop()
            if !providerVoice { catalog.refresh() }
        }
    }

    private var modeSection: some View {
        Section {
            if settings.supportsProviderVoice {
                Picker("Озвучивание", selection: Binding(
                    get: { settings.voiceMode },
                    set: { mode in preview.stop(); settings.setVoiceMode(mode) }
                )) {
                    Text("iPhone").tag(AssistantVoiceMode.system)
                    Text("Провайдер").tag(AssistantVoiceMode.provider)
                }
                .pickerStyle(.segmented)
            } else {
                LabeledContent("Озвучивание", value: "iPhone")
            }
        } footer: {
            if !settings.supportsProviderVoice {
                Text("Голос модели доступен для подключений Realtime.")
            }
        }
        .disabled(editingDisabled)
    }

    private var localSections: some View {
        Group {
            Section {
                voiceChoice(
                    identifier: nil,
                    title: "Автоматически",
                    subtitle: "Лучший из установленных русских голосов"
                )
                if let selected = settings.speechVoiceIdentifier,
                   !catalog.voices.contains(where: { $0.identifier == selected }) {
                    Text("Выбранный голос сейчас недоступен. До его загрузки используется лучший установленный.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Озвучивание выполняется на iPhone. Провайдер получает текст и обрабатывает его по своему тарифу.")
            }

            Section("Установленные голоса · русский") {
                if catalog.voices.isEmpty {
                    Text("На устройстве не найден русский голос. Загрузите его в настройках iPhone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(catalog.voices, id: \.identifier) { voice in
                    voiceChoice(
                        identifier: voice.identifier,
                        title: voice.name,
                        subtitle: SpeechVoiceCatalog.qualityName(voice.quality)
                    )
                }
            }

            Section {
                HStack {
                    Text("Темп речи")
                    Spacer()
                    Text(settings.speechRate == 0.5 ? "Обычный" : (settings.speechRate < 0.5 ? "Медленнее" : "Быстрее"))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { settings.speechRate }, set: { settings.setSpeechRate($0) }),
                    in: 0.4...0.6,
                    step: 0.025
                ) {
                    Text("Темп речи")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                .onChange(of: settings.speechRate) { _, _ in preview.stop() }
                Button {
                    if preview.isSpeaking {
                        preview.stop()
                    } else {
                        preview.play(voiceIdentifier: settings.speechVoiceIdentifier, rate: settings.speechRate)
                    }
                } label: {
                    Label(preview.isSpeaking ? "Остановить пример" : "Послушать выбранный голос", systemImage: preview.isSpeaking ? "stop.fill" : "play.fill")
                }
            }
            .disabled(editingDisabled)

            Section {
                if !catalog.voices.isEmpty && !catalog.voices.contains(where: { $0.quality == .enhanced || $0.quality == .premium }) {
                    Text("Сейчас доступны только стандартные голоса. Более естественные варианты нужно один раз загрузить в iOS.")
                }
                Text("Настройки iPhone → Универсальный доступ → Чтение вслух → Голоса → Русский. Выберите и загрузите улучшенный или премиальный вариант. На прежних версиях iOS раздел может называться «Устный контент».")
                Text("После загрузки вернитесь в Findy: список обновится автоматически. Самостоятельно загружать системные голоса приложение не может.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Инструкция Apple", destination: URL(string: "https://support.apple.com/ru-ru/guide/iphone/iph96b214f0/27/ios/27")!)
            } header: {
                Text("Более естественное звучание")
            }
        }
    }

    private var realtimeSections: some View {
        Group {
            Section {
                Label("Голос модели", systemImage: "waveform")
                Text("Выбранная модель разговора: \(settings.configuration.model)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Аудио обрабатывается провайдером и оплачивается по его тарифу.")
            }

            Section {
                ForEach(OpenAIRealtimeVoiceOptions.names, id: \.self) { voice in
                    realtimeVoiceChoice(voice)
                }
                let selected = settings.configuration.realtimeVoice
                if !OpenAIRealtimeVoiceOptions.names.contains(selected) {
                    realtimeVoiceChoice(selected)
                }
            } header: {
                Text("Голоса модели")
            } footer: {
                Text("Выбор применяется к следующему голосовому разговору.")
            }
            .disabled(editingDisabled)
        }
    }

    private func realtimeVoiceChoice(_ voice: String) -> some View {
        let selected = settings.configuration.realtimeVoice == voice
        let title = OpenAIRealtimeVoiceOptions.title(for: voice)
        return HStack(spacing: 12) {
            Button {
                guard !editingDisabled, var provider = settings.selectedProvider else { return }
                preview.stop()
                provider.realtimeVoice = voice
                do {
                    try settings.upsertProvider(provider, apiKey: nil)
                } catch {
                    voiceErrorTitle = "Не удалось выбрать голос"
                    voiceError = error.localizedDescription
                    showingVoiceError = true
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Голос модели \(title)")
            .accessibilityValue(selected ? "Выбран" : "Не выбран")
            previewButton(identifier: VoicePreviewPlayer.providerIdentifier(voice), title: title) {
                preview.playProvider(voice: voice)
            }
        }
    }

    private func previewButton(identifier: String?, title: String, play: @escaping () -> Void) -> some View {
        let active = preview.isSpeaking && preview.playingVoiceIdentifier == identifier
        return Button {
            if active { preview.stop() } else { play() }
        } label: {
            ZStack {
                if active && preview.isLoading {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Image(systemName: "stop.fill").font(.system(size: 7)).accessibilityHidden(true)
                } else {
                    Image(systemName: active ? "stop.fill" : "speaker.wave.2")
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(active ? "Остановить пример голоса \(title)" : "Послушать голос \(title)")
        .accessibilityIdentifier("speech.preview." + (identifier ?? "automatic"))
        .accessibilityValue(active && preview.isLoading ? "Загрузка" : "")
        .accessibilityHint(active && preview.isLoading ? "Отменяет загрузку примера" : "")
    }

    private func voiceChoice(identifier: String?, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Button {
                preview.stop()
                settings.setSpeechVoiceIdentifier(identifier)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: settings.speechVoiceIdentifier == identifier ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(settings.speechVoiceIdentifier == identifier ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).foregroundStyle(.primary)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(subtitle)")
            .accessibilityValue(settings.speechVoiceIdentifier == identifier ? "Выбран" : "Не выбран")
            previewButton(identifier: catalog.resolve(identifier)?.identifier, title: title) {
                preview.play(voiceIdentifier: identifier, rate: settings.speechRate)
            }
        }
        .disabled(editingDisabled)
    }
}


// Verified against the OpenAI Realtime conversations documentation.
enum OpenAIRealtimeVoiceOptions {
    static let names = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    static func title(for voice: String) -> String {
        guard let first = voice.first else { return "Не выбран" }
        return first.uppercased() + voice.dropFirst()
    }
}
