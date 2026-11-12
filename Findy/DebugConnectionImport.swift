#if DEBUG
import Foundation

/// Installs an explicitly supplied development credential once. The payload is
/// copied through Xcode's device container service, consumed, and deleted.
@MainActor
enum DebugConnectionImport {
    private struct Payload: Decodable {
        let configuration: AssistantConfiguration
        let apiKey: String
    }

    static func runIfPresent() {
        let url = URL.applicationSupportDirectory.appending(path: "connection-import.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
            let settings = AssistantSettings.shared
            let existing = settings.providers.first { $0.name == "OpenAI" && $0.endpoint == payload.configuration.endpoint }
            let id = existing?.id ?? UUID()
            let models = Array(Set((existing?.models ?? []) + [payload.configuration.model, "gpt-6.1-sol", "gpt-6-astra"]))
                .sorted()
            let provider = AssistantProvider(
                id: id,
                name: "OpenAI",
                endpoint: payload.configuration.endpoint,
                apiStyle: payload.configuration.apiStyle,
                models: models,
                systemPrompt: payload.configuration.systemPrompt,
                webSearchEnabled: payload.configuration.webSearchEnabled
            )
            try settings.upsertProvider(provider, apiKey: payload.apiKey)
            try settings.selectModel(providerID: id, modelID: payload.configuration.model)
            SessionLog.shared.record("provider.import.completed", "name=OpenAI model=\(payload.configuration.model)")
        } catch {
            // Credential material and imported JSON never enter the log.
            SessionLog.shared.record("provider.import.failed")
        }
    }
}
#endif
