import AppIntents
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AssistantSettings.shared
    @ObservedObject private var session = VoiceSession.shared
    @ObservedObject private var voiceCatalog = SpeechVoiceCatalog.shared
    @State private var expandedProviders = Set<UUID>()
    @State private var editingProvider: AssistantProvider?
    @State private var deletingProvider: AssistantProvider?
    @State private var actionError = ""
    @State private var showingError = false
    @State private var showingSpeechSettings = false
    @State private var showingGuide = false

    private var usesProviderVoice: Bool { settings.usesProviderVoice }
    private var isBusy: Bool { session.isRunning || session.isSendingText || session.phase != .idle }

    var body: some View {
        NavigationStack {
            List {
                providersSection
                systemPromptSection
                contextSection
                audioSection
                voiceSessionSection
                Section("Siri") {
                    AddChatShortcutButton(accessibilityIdentifier: "findy-shortcuts-link")
                    NavigationLink {
                        SiriHelpView()
                    } label: {
                        Label("Siri и AirPods", systemImage: "airpods")
                    }
                }
                Section {
                    Button {
                        showingGuide = true
                    } label: {
                        Label("Как пользоваться", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings-guide")
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Дополнительно", systemImage: "ellipsis.circle")
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingSpeechSettings) { SpeechSettingsView() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $editingProvider) { ProviderEditorView(provider: $0) }
            .fullScreenCover(isPresented: $showingGuide) {
                OnboardingView(
                    onClose: { showingGuide = false },
                    onConfigure: { showingGuide = false }
                )
            }
            .confirmationDialog("Удалить провайдера?", isPresented: Binding(
                get: { deletingProvider != nil },
                set: { if !$0 { deletingProvider = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    guard let provider = deletingProvider else { return }
                    perform { try settings.deleteProvider(id: provider.id) }
                    deletingProvider = nil
                }
            } message: {
                if let provider = deletingProvider { Text("Подключение «\(provider.name)» и его сохранённый ключ будут удалены.") }
            }
            .alert("Не удалось изменить подключение", isPresented: $showingError) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(actionError)
            }
            .onAppear {
                session.refreshReadiness()
                if let selected = settings.selectedModel { expandedProviders.insert(selected.providerID) }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--edit-selected-provider") {
                    editingProvider = settings.selectedProvider
                }
                if ProcessInfo.processInfo.arguments.contains("--show-speech-settings") {
                    showingSpeechSettings = true
                }
                #endif
            }
        }
    }

    private var providersSection: some View {
        Section {
            ForEach(settings.providers) { provider in
                DisclosureGroup(isExpanded: expansionBinding(for: provider.id)) {
                    if provider.models.isEmpty {
                        Text("Добавьте модели в настройках провайдера.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(provider.models, id: \.self) { model in
                        modelRow(model, provider: provider)
                    }
                    Button {
                        editingProvider = provider
                    } label: {
                        Label("Изменить подключение", systemImage: "slider.horizontal.3")
                    }
                    .disabled(session.isRunning || session.isSendingText)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name).font(.body.weight(.medium))
                            Text("Моделей: \(provider.models.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Изменить", systemImage: "pencil") { editingProvider = provider }
                            Button("Удалить провайдера", systemImage: "trash", role: .destructive) {
                                deletingProvider = provider
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(session.isRunning || session.isSendingText)
                        .accessibilityLabel("Настройки провайдера \(provider.name)")
                    }
                }
            }
            Button {
                editingProvider = AssistantProvider(name: "", endpoint: "")
            } label: {
                Label("Добавить провайдера", systemImage: "plus.circle.fill")
            }
            .disabled(session.isRunning || session.isSendingText)
        } header: {
            Text("Провайдеры и модели")
        } footer: {
            if settings.selectedModel == nil {
                Text("Добавьте провайдера и выберите модель для общения с нейросетью.")
            } else {
                Text("Выбранная модель используется для текста и голоса.")
            }
            if session.isRunning || session.isSendingText {
                Text("Подключение можно изменить после завершения разговора или ответа.")
            }
        }
    }

    private func modelRow(_ model: String, provider: AssistantProvider) -> some View {
        let selected = settings.selectedModel?.providerID == provider.id && settings.selectedModel?.modelID == model
        return Button {
            perform {
                try settings.selectModel(providerID: provider.id, modelID: model)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(model)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isRunning || session.isSendingText)
        .accessibilityLabel("\(model), \(provider.name)")
        .accessibilityValue(selected ? "Выбрана" : "Не выбрана")
    }

    private var systemPromptSection: some View {
        Section {
            if let provider = settings.selectedProvider {
                NavigationLink {
                    SystemPromptEditorView(prompt: provider.systemPrompt, providerName: provider.name) { prompt in
                        guard var current = settings.providers.first(where: { $0.id == provider.id }) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        current.systemPrompt = prompt
                        try settings.upsertProvider(current, apiKey: nil)
                    }
                } label: {
                    Label("Системный промпт", systemImage: "text.alignleft")
                }
                .disabled(session.isRunning || session.isSendingText)
                .accessibilityIdentifier("system-prompt-settings")
            } else {
                Label("Системный промпт", systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
                    .disabled(true)
                    .accessibilityIdentifier("system-prompt-settings")
            }
        } footer: {
            Text("Для выбранного провайдера")
        }
    }

    private var contextSection: some View {
        Section {
            Picker("Сообщений в контексте", selection: Binding(
                get: { settings.contextMessageCount },
                set: { if !isBusy { settings.setContextMessageCount($0) } }
            )) {
                ForEach(Array(stride(from: AssistantLimits.contextMessageMinimum,
                                     through: AssistantLimits.contextMessageMaximum,
                                     by: AssistantLimits.contextMessageStep)), id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(isBusy)
            .accessibilityIdentifier("context-message-count")
        } header: {
            Text("Контекст")
        } footer: {
            Text("Последние сообщения для ответа модели. Вся история остаётся на iPhone.")
        }
    }

    private var audioSection: some View {
        Section {
            NavigationLink {
                SpeechSettingsView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Озвучивание", systemImage: "speaker.wave.2")
                    Text(usesProviderVoice ? "Провайдер · \(OpenAIRealtimeVoiceOptions.title(for: settings.configuration.realtimeVoice))" : "iPhone · \(voiceCatalog.summary(settings.speechVoiceIdentifier))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Только Bluetooth-микрофон", isOn: $session.requireBluetooth)
                .disabled(session.isRunning || session.isSendingText)
            Toggle("Звуковые сигналы", isOn: $session.soundCuesEnabled)
                .disabled(session.isRunning || session.isSendingText)
        } header: {
            Text("Аудио")
        } footer: {
            Text("Если выключено, можно использовать встроенный микрофон iPhone.")
            if usesProviderVoice {
                Text("Аудио передаётся провайдеру и оплачивается по тарифу выбранной модели.")
            }
        }
    }

    private var voiceSessionSection: some View {
        Section {
            Picker("Завершать после тишины", selection: Binding(
                get: { settings.silenceTimeoutSeconds },
                set: { settings.setSilenceTimeoutSeconds($0) }
            )) {
                ForEach([5.0, 10, 15, 30, 60, 120], id: \.self) { seconds in
                    Text("\(Int(seconds)) секунд").tag(seconds)
                }
                Text("Не завершать автоматически").tag(0.0)
                if settings.silenceTimeoutSeconds > 0,
                   ![5.0, 10, 15, 30, 60, 120].contains(settings.silenceTimeoutSeconds) {
                    Text("\(settings.silenceTimeoutSeconds.formatted(.number.precision(.fractionLength(0...1)))) секунд")
                        .tag(settings.silenceTimeoutSeconds)
                }
            }
            .disabled(session.isRunning || session.isSendingText)
        } header: {
            Text("Голосовая сессия")
        } footer: {
            Text("Применяется к следующему голосовому разговору.")
        }
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(id) },
            set: { expanded in
                if expanded { expandedProviders.insert(id) } else { expandedProviders.remove(id) }
            }
        )
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch {
            actionError = error.localizedDescription
            showingError = true
        }
    }
}

@MainActor
private struct AdvancedSettingsView: View {
    @ObservedObject private var settings = AssistantSettings.shared
    @ObservedObject private var session = VoiceSession.shared
    @ObservedObject private var timeline = ChatTimeline.shared
    @State private var confirmingDelete = false
    @State private var confirmingReset = false
    @State private var confirmingRevoke = false
    @State private var actionError = ""
    @State private var showingError = false

    private var isBusy: Bool { session.isRunning || session.isSendingText || session.phase != .idle }
    private var usesProviderVoice: Bool { settings.usesProviderVoice }

    var body: some View {
        List {
            if let provider = settings.selectedProvider {
                Section {
                    LabeledContent("Передача данных", value: settings.providerSharingAllowed ? "Разрешена" : "Не разрешена")
                    if settings.providerSharingAllowed {
                        Button("Отозвать разрешение", role: .destructive) { confirmingRevoke = true }
                            .disabled(isBusy)
                    }
                } header: { Text(provider.name) } footer: {
                    Text("Сообщения и память отправляются выбранному сервису, а с голосом провайдера — также аудио. После отзыва потребуется новое разрешение перед отправкой.")
                }
            }
            Section("Доступ") {
                LabeledContent("Микрофон", value: session.microphoneStatus)
                if !usesProviderVoice {
                    LabeledContent("Распознавание речи", value: session.speechStatus)
                    LabeledContent("Русский на устройстве", value: session.onDeviceStatus)
                }
                LabeledContent("Live Activities", value: session.activitiesStatus)
                Button(usesProviderVoice ? "Разрешить микрофон" : "Разрешить микрофон и речь") {
                    Task { await session.requestPermissions() }
                }
                .disabled(isBusy)
                Button("Открыть настройки iPhone") { session.openSettings() }
            }
            Section {
                Button("Сбросить контекст разговора") { confirmingReset = true }
                    .disabled(isBusy)
            } footer: {
                Text("Помощник начнёт учитывать разговор с этого места. Все сообщения останутся в чате.")
            }
            Section {
                Button("Удалить историю сообщений", role: .destructive) { confirmingDelete = true }
                    .disabled(isBusy || timeline.totalCount == 0)
            } footer: {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                Text("Findy \(version) (\(build))")
            }
        }
        .navigationTitle("Дополнительно")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Отозвать разрешение на передачу данных?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Отозвать разрешение", role: .destructive) {
                guard !isBusy, let provider = settings.selectedProvider else { return }
                settings.revokeSharing(for: provider)
            }
        }
        .confirmationDialog("Сбросить контекст разговора?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Сбросить контекст") {
                guard !isBusy else { return }
                session.clearConversation()
            }
        } message: {
            Text("Сообщения сохранятся. Для следующих ответов помощник будет учитывать только новые сообщения.")
        }
        .confirmationDialog("Удалить всю историю сообщений?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Удалить историю", role: .destructive) {
                guard !isBusy else { return }
                do { try timeline.deleteHistory() }
                catch { actionError = error.localizedDescription; showingError = true }
            }
        } message: {
            Text("Это действие нельзя отменить. Память и напоминания сохранятся.")
        }
        .alert("Не удалось удалить историю", isPresented: $showingError) {
            Button("Понятно", role: .cancel) {}
        } message: { Text(actionError) }
        .onAppear { session.refreshReadiness() }
    }
}
