import SwiftUI

@MainActor
struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AssistantSettings.shared
    @ObservedObject private var session = VoiceSession.shared
    @State private var draft: AssistantProvider
    private let originalSystemPrompt: String
    @State private var draftKey = ""
    @State private var newModel = ""
    @State private var removeSavedKey = false
    @State private var isLoadingModels = false
    @State private var isTesting = false
    @State private var resultMessage: String?
    @State private var resultSucceeded = false
    @State private var networkTask: Task<Void, Never>?
    @State private var saveError = ""
    @State private var showingSaveError = false
    @State private var showingSharingConsent = false

    init(provider: AssistantProvider) {
        _draft = State(initialValue: provider)
        originalSystemPrompt = provider.customSystemPrompt
    }

    private var editingDisabled: Bool { session.isRunning || session.isSendingText || isTesting || isLoadingModels }
    private var invalidPromptDraft: Bool {
        draft.customSystemPrompt.count > AssistantLimits.systemPromptCharacters && draft.customSystemPrompt != originalSystemPrompt
    }
    private var hasSavedKey: Bool { !removeSavedKey && settings.hasAPIKey(for: draft) }
    private var testModel: String? {
        if let selected = settings.selectedModel,
           selected.providerID == draft.id, draft.models.contains(selected.modelID) {
            return selected.modelID
        }
        return draft.models.first
    }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                credentialSection
                modelsSection
                if draft.apiStyle == .realtime { realtimeVoiceSection }
                if draft.configuration(for: "validation").supportsImageGeneration { imageSection }
                behaviorSection
                connectionSection
            }
            .navigationTitle("Подключение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                        .disabled(editingDisabled || invalidPromptDraft)
                }
            }
            .alert("Не удалось сохранить", isPresented: $showingSaveError) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text(saveError)
            }
            .alert("Разрешить передачу данных?", isPresented: $showingSharingConsent) {
                Button("Отмена", role: .cancel) {}
                Button("Разрешить") { settings.grantSharing(for: draft); testConnection() }
            } message: {
                Text("\(draft.name) · \(URL(string: draft.endpoint)?.host ?? draft.endpoint)\n\nДля проверки сервис получит короткое тестовое сообщение. При разговоре ему будут передаваться сообщения и сохранённая память, а в режиме «Провайдер» — также аудио. Обработка данных определяется условиями сервиса. Разрешение можно отозвать в настройках.")
            }
            .onDisappear { networkTask?.cancel() }
            .onChange(of: draft.apiStyle) { _, style in
                if style == .chatCompletions { draft.webSearchEnabled = false }
            }
            .onChange(of: draft.endpoint) { old, _ in
                var previous = draft
                previous.endpoint = old
                if settings.credentialOrigin(for: previous) != settings.credentialOrigin(for: draft) {
                    draftKey = ""
                    removeSavedKey = false
                }
            }
            .onChange(of: draft) { _, _ in resultMessage = nil }
            .onChange(of: draftKey) { _, _ in resultMessage = nil }
        }
    }

    private var providerSection: some View {
        Section {
            TextField("Название провайдера", text: $draft.name)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Название провайдера")
            VStack(alignment: .leading, spacing: 6) {
                Text("Адрес API").font(.caption).foregroundStyle(.secondary)
                TextField("https://api.openai.com/v1", text: $draft.endpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Адрес API")
            }
            Picker("Формат API", selection: $draft.apiStyle) {
                Text("Chat Completions").tag(AssistantAPIStyle.chatCompletions)
                Text("Responses").tag(AssistantAPIStyle.responses)
                Text("Realtime").tag(AssistantAPIStyle.realtime)
            }
            Button("Подставить адрес OpenAI") {
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = "OpenAI" }
                draft.endpoint = "https://api.openai.com/v1"
            }
        } header: {
            Text("Провайдер")
        } footer: {
            if draft.apiStyle == .realtime {
                Text("С голосом провайдера сервис получает аудио. С голосом iPhone отправляется текст. Режим выбирается в настройках озвучивания.")
            } else {
                Text("Укажите адрес сервиса или полный URL метода. Текст отправляется выбранному сервису; распознавание и голос — на iPhone.")
            }
        }
        .disabled(editingDisabled)
    }

    private var credentialSection: some View {
        Section {
            SecureField(hasSavedKey ? "Ключ сохранён · введите для замены" : "API key, если требуется", text: $draftKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Секретный ключ API")
            if hasSavedKey {
                Label("Ключ сохранён для этого подключения", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Удалить сохранённый ключ", role: .destructive) {
                    removeSavedKey = true
                    draftKey = ""
                }
            } else if removeSavedKey && draftKey.isEmpty {
                Text("Ключ будет удалён при сохранении.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Ключ API")
        } footer: {
            Text("Необязателен для сервисов без авторизации. Хранится в связке ключей iPhone и привязан к провайдеру и адресу сервиса.")
        }
        .disabled(editingDisabled)
    }

    private var modelsSection: some View {
        Section {
            ForEach(draft.models, id: \.self) { model in
                HStack(spacing: 12) {
                    Text(model).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(role: .destructive) {
                        draft.models.removeAll { $0 == model }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(minWidth: 30, minHeight: 30)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Убрать модель \(model)")
                }
            }
            HStack(spacing: 12) {
                TextField(draft.apiStyle == .realtime ? "Название модели Realtime" : "Название модели", text: $newModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addModel)
                Button("Добавить", action: addModel)
                    .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(action: loadModels) {
                HStack(spacing: 10) {
                    if isLoadingModels { ProgressView() }
                    Label(isLoadingModels ? "Загружаю модели…" : "Загрузить модели сервиса", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("Модели")
        } footer: {
            Text("Загрузите список из API или добавьте названия вручную. Основную модель можно выбрать в списке провайдеров после сохранения.")
            if draft.apiStyle == .realtime {
                Text("Для этого формата нужна модель с поддержкой Realtime API.")
            }
        }
        .disabled(editingDisabled)
    }

    private var imageSection: some View {
        Section {
            Picker("Модель изображений", selection: $draft.imageModel) {
                Text("GPT Image 2.5 Flare").tag("gpt-image-2.5-flare")
                Text("GPT Image 2.5 Sunburst").tag("gpt-image-2.5-sunburst")
                Text("GPT Image 2").tag("gpt-image-2")
                Text("GPT Image 1.5").tag("gpt-image-1.5")
                if !["gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2", "gpt-image-1.5"].contains(draft.imageModel) {
                    Text(draft.imageModel).tag(draft.imageModel)
                }
            }
        } header: { Text("Изображения") }
        footer: { Text("Создание изображений по запросу в чате оплачивается по тарифу OpenAI.") }
        .disabled(editingDisabled)
    }

    private var realtimeVoiceSection: some View {
        Section {
            Picker("Голос модели", selection: $draft.realtimeVoice) {
                ForEach(OpenAIRealtimeVoiceOptions.names, id: \.self) { voice in
                    Text(OpenAIRealtimeVoiceOptions.title(for: voice)).tag(voice)
                }
                if !OpenAIRealtimeVoiceOptions.names.contains(draft.realtimeVoice) {
                    Text(draft.realtimeVoice).tag(draft.realtimeVoice)
                }
            }
        } header: {
            Text("Голос")
        } footer: {
            Text("Используется при выборе озвучивания «Провайдер». Аудио оплачивается по тарифу сервиса.")
        }
        .disabled(editingDisabled)
    }

    private var behaviorSection: some View {
        Section {
            if draft.apiStyle == .responses || draft.apiStyle == .realtime {
                Toggle("Поиск в интернете", isOn: $draft.webSearchEnabled)
                if draft.apiStyle == .realtime {
                    if draft.webSearchEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Модель для поиска").font(.caption).foregroundStyle(.secondary)
                            TextField("gpt-6-luna", text: $draft.webSearchModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Вспомогательная модель Responses для веб-поиска")
                        }
                        Text("Дополнительная модель Responses выполняет поиск через тот же сервис. Основная модель разговора остаётся выбранной в списке провайдеров; поиск оплачивается отдельно.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Использует web_search. Сервис и выбранная модель должны поддерживать этот инструмент.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                SystemPromptEditorView(provider: draft) { preset, customPrompt in
                    draft.promptPreset = preset
                    draft.customSystemPrompt = customPrompt
                }
            } label: {
                Label("Системный промпт", systemImage: "text.alignleft")
            }
            .accessibilityIdentifier("provider-system-prompt-settings")
        } header: {
            Text("Ответы")
        } footer: {
            if invalidPromptDraft {
                Text("Сократите системный промпт до \(AssistantLimits.systemPromptCharacters) символов, чтобы сохранить подключение.")
                    .foregroundStyle(.red)
            }
            if draft.apiStyle == .chatCompletions {
                Text("Для встроенного веб-поиска выберите Responses или Realtime с поисковой моделью Responses.")
            }
        }
        .disabled(editingDisabled)
    }

    private var connectionSection: some View {
        Section {
            Button(action: testConnection) {
                HStack(spacing: 10) {
                    if isTesting { ProgressView() }
                    Text(isTesting ? "Проверяю подключение…" : "Проверить подключение")
                }
            }
            .disabled(editingDisabled || testModel == nil)
            if let resultMessage {
                Label(resultMessage, systemImage: resultSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(resultSucceeded ? Color.green : Color.red)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        } footer: {
            if let model = testModel {
                Text("Отправляет короткий запрос модели \(model) с текущими настройками. Изменения сохраняются кнопкой «Сохранить».")
            } else {
                Text("Добавьте хотя бы одну модель для проверки подключения.")
            }
        }
    }

    private func addModel() {
        let value = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !draft.models.contains(value) { draft.models.append(value) }
        newModel = ""
    }

    private func save() {
        if draft.apiStyle == .realtime, draft.webSearchEnabled,
           draft.webSearchModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveError = "Укажите модель Responses для поиска."
            showingSaveError = true
            return
        }
        do {
            addModel()
            let enteredKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String? = !enteredKey.isEmpty ? enteredKey : (removeSavedKey ? "" : nil)
            try settings.upsertProvider(draft, apiKey: key)
            draftKey = ""
            dismiss()
        } catch {
            saveError = error.localizedDescription
            showingSaveError = true
        }
    }

    private func loadModels() {
        resultMessage = nil
        isLoadingModels = true
        let provider = draft
        let enteredKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let deletingKey = removeSavedKey
        networkTask = Task { @MainActor in
            do {
                let key = !enteredKey.isEmpty ? enteredKey : (deletingKey ? "" : try settings.apiKey(for: provider))
                let models = try await AssistantClient().availableModels(endpoint: provider.endpoint, apiStyle: provider.apiStyle, apiKey: key)
                try Task.checkCancellation()
                var seen = Set(draft.models)
                draft.models.append(contentsOf: models.filter { seen.insert($0).inserted })
                resultSucceeded = !models.isEmpty
                resultMessage = models.isEmpty ? "Сервис вернул пустой список. Можно добавить модели вручную." : "Получено моделей: \(models.count)"
            } catch is CancellationError {
                resultMessage = nil
            } catch {
                if !Task.isCancelled {
                    resultSucceeded = false
                    resultMessage = error.localizedDescription
                }
            }
            isLoadingModels = false
            networkTask = nil
        }
    }

    private func testConnection() {
        guard let model = testModel else { return }
        do { _ = try settings.configuration(for: draft, model: model).validatedEndpoint() }
        catch { resultSucceeded = false; resultMessage = error.localizedDescription; return }
        guard settings.sharingAllowed(for: draft) else { showingSharingConsent = true; return }
        resultMessage = nil
        isTesting = true
        let provider = draft
        let enteredKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let deletingKey = removeSavedKey
        networkTask = Task { @MainActor in
            do {
                let configuration = settings.configuration(for: provider, model: model)
                _ = try configuration.validatedEndpoint()
                let key = !enteredKey.isEmpty ? enteredKey : (deletingKey ? "" : try settings.apiKey(for: provider))
                let messages = [AssistantMessage(role: .user, text: "Ответь одним словом: готов.")]
                if configuration.apiStyle == .realtime {
                    _ = try await RealtimeTextReply.reply(configuration: configuration, apiKey: key, messages: messages, onUpdate: { _ in })
                } else {
                    _ = try await AssistantClient().reply(configuration: configuration, apiKey: key, messages: messages)
                }
                try Task.checkCancellation()
                resultSucceeded = true
                resultMessage = "Подключение работает"
            } catch is CancellationError {
                resultMessage = nil
            } catch {
                if !Task.isCancelled {
                    resultSucceeded = false
                    resultMessage = error.localizedDescription
                }
            }
            isTesting = false
            networkTask = nil
        }
    }
}
