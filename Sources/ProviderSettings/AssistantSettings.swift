import Combine
import CoreFoundation
import Foundation
#if canImport(AssistantCore)
import AssistantCore
#endif

enum AssistantVoiceMode: String, CaseIterable, Sendable {
    case system
    case provider
}

@MainActor
final class AssistantSettings: ObservableObject {
    static let shared: AssistantSettings = {
        #if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["FINDY_UI_TEST_SESSION"], let id = UUID(uuidString: value),
           let defaults = UserDefaults(suiteName: "findy.ui-tests." + id.uuidString) {
            return AssistantSettings(defaults: defaults)
        }
        #endif
        return AssistantSettings()
    }()

    @Published private(set) var providers: [AssistantProvider]
    @Published private(set) var selectedModel: AssistantModelSelection?
    @Published private(set) var hasSeenOnboarding: Bool
    @Published private(set) var hasAPIKey = false
    @Published private(set) var speechVoiceIdentifier: String?
    @Published private(set) var speechRate: Double
    @Published private(set) var silenceTimeoutSeconds: Double
    @Published private(set) var contextMessageCount: Int
    @Published private(set) var voiceMode: AssistantVoiceMode

    @Published private var sharingGrants: Set<String>

    private let defaults: UserDefaults
    private let keyStore: any ProviderKeyStore
    private let providersKey = "assistant.providers"
    private let selectionKey = "assistant.selectedModel"

    init(defaults: UserDefaults = .standard, keyStore: any ProviderKeyStore = APIKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
        hasSeenOnboarding = defaults.bool(forKey: "app.hasSeenOnboarding")
        sharingGrants = Set(defaults.stringArray(forKey: "assistant.providerSharingGrants") ?? [])
        contextMessageCount = AssistantLimits.normalizedContextMessageCount((defaults.object(forKey: "assistant.contextMessageCount") as? Int) ?? AssistantLimits.contextMessageDefault)
        voiceMode = defaults.string(forKey: "voice.mode").flatMap(AssistantVoiceMode.init(rawValue:)) ?? .provider
        speechVoiceIdentifier = defaults.string(forKey: "speech.voiceIdentifier")
        let storedRate = defaults.object(forKey: "speech.rate") as? Double ?? 0.5
        speechRate = storedRate.isFinite ? min(0.6, max(0.4, storedRate)) : 0.5
        if let stored = defaults.object(forKey: "voice.silenceTimeout") as? NSNumber,
           CFGetTypeID(stored) != CFBooleanGetTypeID(),
           stored.doubleValue.isFinite,
           stored.doubleValue == 0 || (5.0...120.0).contains(stored.doubleValue) {
            silenceTimeoutSeconds = stored.doubleValue
        } else {
            silenceTimeoutSeconds = 5
        }
        providers = defaults.data(forKey: providersKey)
            .flatMap { try? JSONDecoder().decode([AssistantProvider].self, from: $0) } ?? []
        selectedModel = defaults.data(forKey: selectionKey)
            .flatMap { try? JSONDecoder().decode(AssistantModelSelection.self, from: $0) }
        if !selectionExists(selectedModel, in: providers) { selectedModel = firstSelection(in: providers) }
        refreshKeyStatus()
    }

    var selectedProvider: AssistantProvider? {
        guard let selection = selectedModel else { return nil }
        return providers.first { $0.id == selection.providerID && $0.models.contains(selection.modelID) }
    }

    var isConfiguredForChat: Bool { selectedProvider != nil }

    func completeOnboarding() {
        hasSeenOnboarding = true
        defaults.set(true, forKey: "app.hasSeenOnboarding")
    }

    var providerSharingAllowed: Bool {
        selectedProvider.map { sharingAllowed(for: $0) } == true
    }

    func sharingAllowed(for provider: AssistantProvider) -> Bool {
        guard let origin = credentialOrigin(for: provider) else { return false }
        return sharingGrants.contains(provider.id.uuidString.lowercased() + "|" + origin)
    }

    func grantSharing(for provider: AssistantProvider) {
        guard let origin = credentialOrigin(for: provider) else { return }
        sharingGrants.insert(provider.id.uuidString.lowercased() + "|" + origin)
        defaults.set(Array(sharingGrants).sorted(), forKey: "assistant.providerSharingGrants")
    }

    func revokeSharing(for provider: AssistantProvider) {
        guard let origin = credentialOrigin(for: provider) else { return }
        sharingGrants.remove(provider.id.uuidString.lowercased() + "|" + origin)
        defaults.set(Array(sharingGrants).sorted(), forKey: "assistant.providerSharingGrants")
    }

    var supportsProviderVoice: Bool { isConfiguredForChat && configuration.apiStyle == .realtime }
    var usesProviderVoice: Bool { supportsProviderVoice && voiceMode == .provider }

    func setContextMessageCount(_ count: Int) {
        contextMessageCount = AssistantLimits.normalizedContextMessageCount(count)
        defaults.set(contextMessageCount, forKey: "assistant.contextMessageCount")
    }

    func setVoiceMode(_ mode: AssistantVoiceMode) {
        guard mode == .system || supportsProviderVoice else { return }
        voiceMode = mode
        defaults.set(mode.rawValue, forKey: "voice.mode")
    }

    var configuration: AssistantConfiguration {
        guard let provider = selectedProvider, let selection = selectedModel else { return AssistantConfiguration() }
        return configuration(for: provider, model: selection.modelID)
    }

    var configurationSummary: String {
        guard let provider = selectedProvider, let selection = selectedModel else { return "Выберите модель" }
        return "\(selection.modelID) · \(provider.name)"
    }

    func apiKey() throws -> String {
        guard let provider = selectedProvider else { return "" }
        return try apiKey(for: provider)
    }

    func apiKey(for provider: AssistantProvider) throws -> String {
        try keyStore.read(for: storageAccount(for: provider))
    }

    func hasAPIKey(for provider: AssistantProvider) -> Bool {
        guard let account = try? storageAccount(for: provider) else { return false }
        return (try? keyStore.containsKey(for: account)) ?? false
    }

    func credentialOrigin(for provider: AssistantProvider) -> String? {
        try? storageOrigin(for: provider)
    }

    func configuration(for provider: AssistantProvider, model: String) -> AssistantConfiguration {
        AssistantConfiguration(
            endpoint: provider.endpoint,
            model: model,
            apiStyle: provider.apiStyle,
            systemPrompt: provider.systemPrompt,
            webSearchEnabled: provider.webSearchEnabled,
            realtimeVoice: provider.realtimeVoice,
            webSearchModel: provider.webSearchModel,
            contextMessageCount: contextMessageCount
        )
    }

    /// One-time upgrade for an existing OpenAI connection. The
    /// credential stays in Keychain and is copied only to the same HTTPS origin.
    @discardableResult
    func installRealtimeConnectionIfNeeded() throws -> Bool {
        let marker = "assistant.realtimeUpgrade.v1"
        guard !defaults.bool(forKey: marker) else { return false }
        guard let original = selectedProvider,
              original.apiStyle != .realtime,
              try storageOrigin(for: original) == "https://api.openai.com" else { return false }
        let key = try apiKey(for: original)
        guard !key.isEmpty else { return false }
        let provider = AssistantProvider(
            name: "OpenAI Realtime",
            endpoint: "https://api.openai.com/v1",
            apiStyle: .realtime,
            models: ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"],
            systemPrompt: original.systemPrompt,
            webSearchEnabled: original.webSearchEnabled,
            realtimeVoice: "marin",
            webSearchModel: original.apiStyle == .responses ? configuration.model : "gpt-6-luna"
        )
        try upsertProvider(provider, apiKey: key)
        try selectModel(providerID: provider.id, modelID: "gpt-realtime-2.1-mini")
        defaults.set(true, forKey: marker)
        return true
    }

    func upsertProvider(_ provider: AssistantProvider, apiKey: String?) throws {
        var saved = provider
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.endpoint = saved.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.name.isEmpty else { throw SettingsFailure(message: "Укажите название провайдера.") }
        let existingPrompt = providers.first(where: { $0.id == saved.id })?.systemPrompt
        guard saved.systemPrompt.count <= AssistantLimits.systemPromptCharacters || saved.systemPrompt == existingPrompt else {
            throw SettingsFailure(message: "Системная инструкция слишком длинная. Сократите её до 500 символов.")
        }
        var seen = Set<String>()
        saved.models = saved.models.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
        _ = try configuration(for: saved, model: saved.models.first ?? "provider-validation").validatedEndpoint()
        var updated = providers
        if let index = updated.firstIndex(where: { $0.id == saved.id }) {
            updated[index] = saved
        } else {
            updated.append(saved)
        }
        let data = try JSONEncoder().encode(updated)
        if let apiKey {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.rangeOfCharacter(from: .controlCharacters) == nil else { throw AssistantClientError.invalidAPIKey }
            try keyStore.save(value, for: storageAccount(for: saved))
        }
        providers = updated
        if !selectionExists(selectedModel, in: updated) { selectedModel = firstSelection(in: updated) }
        persist(providersData: data)
        refreshKeyStatus()
    }

    func deleteProvider(id: UUID) throws {
        guard providers.contains(where: { $0.id == id }) else { return }
        let updated = providers.filter { $0.id != id }
        let data = try JSONEncoder().encode(updated)
        try keyStore.removeAll(for: id)
        providers = updated
        if !selectionExists(selectedModel, in: updated) { selectedModel = firstSelection(in: updated) }
        persist(providersData: data)
        refreshKeyStatus()
    }

    func selectModel(providerID: UUID, modelID: String) throws {
        let selection = AssistantModelSelection(providerID: providerID, modelID: modelID)
        guard selectionExists(selection, in: providers) else {
            throw SettingsFailure(message: "Модель больше не найдена. Обновите список провайдера.")
        }
        selectedModel = selection
        persist()
        refreshKeyStatus()
    }

    func removeAPIKey() throws {
        guard let provider = selectedProvider else { return }
        try keyStore.remove(for: storageAccount(for: provider))
        refreshKeyStatus()
    }

    func setSpeechVoiceIdentifier(_ identifier: String?) {
        let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        speechVoiceIdentifier = value?.isEmpty == false ? value : nil
        if let value = speechVoiceIdentifier {
            defaults.set(value, forKey: "speech.voiceIdentifier")
        } else {
            defaults.removeObject(forKey: "speech.voiceIdentifier")
        }
    }

    func setSpeechRate(_ rate: Double) {
        guard rate.isFinite else { return }
        speechRate = min(0.6, max(0.4, rate))
        defaults.set(speechRate, forKey: "speech.rate")
    }

    func setSilenceTimeoutSeconds(_ seconds: Double) {
        guard seconds.isFinite else { return }
        silenceTimeoutSeconds = seconds == 0 ? 0 : min(120, max(5, seconds))
        defaults.set(silenceTimeoutSeconds, forKey: "voice.silenceTimeout")
    }

    private func persist(providersData: Data? = nil) {
        if let data = providersData ?? (try? JSONEncoder().encode(providers)) {
            defaults.set(data, forKey: providersKey)
        }
        if let selection = selectedModel, let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }

    private func refreshKeyStatus() {
        hasAPIKey = selectedProvider.map { hasAPIKey(for: $0) } ?? false
    }

    private func selectionExists(_ selection: AssistantModelSelection?, in providers: [AssistantProvider]) -> Bool {
        guard let selection else { return false }
        return providers.contains { $0.id == selection.providerID && $0.models.contains(selection.modelID) }
    }

    private func firstSelection(in providers: [AssistantProvider]) -> AssistantModelSelection? {
        for provider in providers {
            if let model = provider.models.first { return AssistantModelSelection(providerID: provider.id, modelID: model) }
        }
        return nil
    }

    private func storageAccount(for provider: AssistantProvider) throws -> String {
        provider.id.uuidString.lowercased() + "|" + (try storageOrigin(for: provider))
    }

    private func storageOrigin(for provider: AssistantProvider) throws -> String {
        var validation = configuration(for: provider, model: provider.models.first ?? "credential-origin")
        validation.webSearchEnabled = false
        let endpoint = try validation.validatedEndpoint()
        guard let scheme = endpoint.scheme?.lowercased(), let hostname = endpoint.host?.lowercased() else {
            throw SettingsFailure(message: "Не удалось определить адрес провайдера для сохранения ключа.")
        }
        let host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        let port = endpoint.port
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let suffix: String
        if let port, !defaultPort { suffix = ":\(port)" } else { suffix = "" }
        return "\(scheme)://\(host)\(suffix)"
    }
}

private struct SettingsFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
