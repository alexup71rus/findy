import XCTest
import AssistantCore
@testable import ProviderSettings

private final class RealtimeMigrationMemoryKeys: ProviderKeyStore {
    var values: [String: String] = [:]
    var failWrites = false

    func read(for account: String) throws -> String { values[account] ?? "" }
    func containsKey(for account: String) throws -> Bool { values[account] != nil }
    func save(_ key: String, for account: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        if key.isEmpty { values.removeValue(forKey: account) } else { values[account] = key }
    }
    func remove(for account: String) throws { values.removeValue(forKey: account) }
    func removeAll(for providerID: UUID) throws {
        values = values.filter { !$0.key.hasPrefix(providerID.uuidString.lowercased() + "|") }
    }
}

final class RealtimeSettingsTests: XCTestCase, @unchecked Sendable {
    func testContextCountPersistsAndPropagatesToConfiguration() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                XCTAssertEqual(fixture.settings.contextMessageCount, 15)
                let provider = AssistantProvider(name: "Test", endpoint: "https://example.test/v1", models: ["model"])
                try fixture.settings.upsertProvider(provider, apiKey: nil)
                fixture.settings.setContextMessageCount(27)
                XCTAssertEqual(fixture.settings.contextMessageCount, 25)
                XCTAssertEqual(fixture.settings.configuration.contextMessageCount, 25)
                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                XCTAssertEqual(restored.contextMessageCount, 25)
                XCTAssertEqual(restored.configuration.contextMessageCount, 25)
                restored.setContextMessageCount(500)
                XCTAssertEqual(restored.contextMessageCount, 50)
            }
        }
    }

    func testRealtimeUpgradePreservesInactiveCustomPrompt() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                var original = AssistantProvider(name: "OpenAI", endpoint: "https://api.openai.com/v1", models: ["model"], systemPrompt: "Сохранённая инструкция")
                original.promptPreset = .helpful
                try fixture.settings.upsertProvider(original, apiKey: "key")
                XCTAssertTrue(try fixture.settings.installRealtimeConnectionIfNeeded())
                let upgraded = try XCTUnwrap(fixture.settings.selectedProvider)
                XCTAssertEqual(upgraded.promptPreset, .helpful)
                XCTAssertEqual(upgraded.customSystemPrompt, original.customSystemPrompt)
                XCTAssertEqual(upgraded.systemPrompt, AssistantConfiguration.defaultSystemPrompt)
            }
        }
    }

    func testUpgradeCopiesTheSelectedOpenAICredentialAndKeepsTheOriginalProvider() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                let original = AssistantProvider(
                    name: "My OpenAI account",
                    endpoint: "https://api.openai.com:443/v1/responses",
                    apiStyle: .responses,
                    models: ["gpt-6-luna", "gpt-6.1-sol"],
                    systemPrompt: "Keep my existing instructions.",
                    webSearchEnabled: true,
                    imageModel: "gpt-image-2",
                    imageInputEnabled: true
                )
                let otherAccount = AssistantProvider(
                    name: "Other OpenAI account",
                    endpoint: "https://api.openai.com/v1",
                    models: ["another-text-model"]
                )
                try fixture.settings.upsertProvider(original, apiKey: "selected-fixture-key")
                try fixture.settings.upsertProvider(otherAccount, apiKey: "unselected-fixture-key")
                try fixture.settings.selectModel(providerID: original.id, modelID: "gpt-6.1-sol")

                XCTAssertTrue(try fixture.settings.installRealtimeConnectionIfNeeded())

                let realtime = try XCTUnwrap(fixture.settings.selectedProvider)
                XCTAssertNotEqual(realtime.id, original.id)
                XCTAssertEqual(realtime.apiStyle, .realtime)
                XCTAssertEqual(fixture.settings.providers.first(where: { $0.id == original.id }), original)
                XCTAssertEqual(fixture.settings.providers.first(where: { $0.id == otherAccount.id }), otherAccount)
                XCTAssertEqual(fixture.settings.providers.filter { $0.apiStyle == .realtime }.count, 1)
                XCTAssertEqual(fixture.settings.selectedModel, AssistantModelSelection(providerID: realtime.id, modelID: "gpt-realtime-2.1-mini"))
                XCTAssertEqual(fixture.settings.configuration.model, "gpt-realtime-2.1-mini")
                XCTAssertEqual(fixture.settings.configuration.realtimeVoice, "marin")
                XCTAssertEqual(fixture.settings.configuration.webSearchModel, "gpt-6.1-sol")
                XCTAssertEqual(realtime.systemPrompt, original.systemPrompt)
                XCTAssertTrue(realtime.webSearchEnabled)
                XCTAssertEqual(realtime.imageModel, "gpt-image-2")
                XCTAssertTrue(realtime.imageInputEnabled)
                XCTAssertTrue(fixture.settings.configuration.imageInputEnabled)
                XCTAssertEqual(try fixture.settings.apiKey(), "selected-fixture-key")
                XCTAssertEqual(try fixture.settings.apiKey(for: original), "selected-fixture-key")
                XCTAssertEqual(try fixture.settings.apiKey(for: otherAccount), "unselected-fixture-key")

                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                XCTAssertEqual(restored.selectedModel, fixture.settings.selectedModel)
                XCTAssertEqual(restored.providers, fixture.settings.providers)
                XCTAssertEqual(try restored.apiKey(), "selected-fixture-key")
            }
        }
    }

    func testSuccessfulUpgradeDoesNotOverrideAManualModelSwitchAfterRelaunch() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                let original = try configuredOpenAI(in: fixture)
                XCTAssertTrue(try fixture.settings.installRealtimeConnectionIfNeeded())
                let providersAfterUpgrade = fixture.settings.providers
                try fixture.settings.selectModel(providerID: original.id, modelID: "gpt-6-luna")

                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                XCTAssertFalse(try restored.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(restored.providers, providersAfterUpgrade)
                XCTAssertEqual(restored.selectedModel, AssistantModelSelection(providerID: original.id, modelID: "gpt-6-luna"))
                XCTAssertEqual(restored.configuration.apiStyle, .responses)
            }
        }
    }

    func testCredentialWriteFailureLeavesUpgradeAtomicAndRetryable() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                _ = try configuredOpenAI(in: fixture)
                let originalProviders = fixture.settings.providers
                let originalSelection = fixture.settings.selectedModel
                let originalConfiguration = fixture.settings.configuration
                let originalKeys = fixture.keys.values
                let persistedBefore = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
                fixture.keys.failWrites = true

                XCTAssertThrowsError(try fixture.settings.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(fixture.settings.providers, originalProviders)
                XCTAssertEqual(fixture.settings.selectedModel, originalSelection)
                XCTAssertEqual(fixture.settings.configuration, originalConfiguration)
                XCTAssertEqual(fixture.keys.values, originalKeys)
                XCTAssertEqual(
                    NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]),
                    NSDictionary(dictionary: persistedBefore)
                )
                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                XCTAssertEqual(restored.providers, originalProviders)
                XCTAssertEqual(restored.selectedModel, originalSelection)

                fixture.keys.failWrites = false
                XCTAssertTrue(try restored.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(restored.providers.filter { $0.apiStyle == .realtime }.count, 1)
                XCTAssertEqual(restored.configuration.model, "gpt-realtime-2.1-mini")
                XCTAssertEqual(try restored.apiKey(), "migration-fixture-key")
            }
        }
    }

    func testCustomAndNonHTTPSOriginsAreNotUpgradedOrGivenCopiedCredentials() async throws {
        try await MainActor.run {
            for endpoint in [
                "https://proxy.example/openai/v1",
                "https://api.openai.com.evil.example/v1",
                "https://evil.example/api.openai.com/v1",
                "http://api.openai.com/v1",
                "https://api.openai.com:8443/v1",
                "https://openai.com/v1",
                "https://api.openai.com./v1"
            ] {
                try withFixture { fixture in
                    let original = AssistantProvider(name: "OpenAI", endpoint: endpoint, apiStyle: .responses, models: ["custom-model"])
                    try fixture.settings.upsertProvider(original, apiKey: "custom-fixture-key")
                    let originalSelection = fixture.settings.selectedModel
                    let keysBefore = fixture.keys.values
                    let persistedBefore = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]

                    XCTAssertFalse(try fixture.settings.installRealtimeConnectionIfNeeded(), endpoint)
                    XCTAssertEqual(fixture.settings.providers, [original], endpoint)
                    XCTAssertEqual(fixture.settings.selectedModel, originalSelection, endpoint)
                    XCTAssertEqual(fixture.keys.values, keysBefore, endpoint)
                    XCTAssertEqual(
                        NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]),
                        NSDictionary(dictionary: persistedBefore),
                        endpoint
                    )
                }
            }
        }
    }

    func testMissingCredentialSkipsUpgradeWithoutMarkingItComplete() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                let original = AssistantProvider(name: "Anonymous", endpoint: "https://api.openai.com/v1", models: ["text-model"])
                try fixture.settings.upsertProvider(original, apiKey: nil)
                let selection = fixture.settings.selectedModel

                XCTAssertFalse(try fixture.settings.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(fixture.settings.providers, [original])
                XCTAssertEqual(fixture.settings.selectedModel, selection)
                XCTAssertTrue(fixture.keys.values.isEmpty)

                try fixture.settings.upsertProvider(original, apiKey: "later-fixture-key")
                XCTAssertTrue(try fixture.settings.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(try fixture.settings.apiKey(), "later-fixture-key")
            }
        }
    }

    func testAnAlreadyRealtimeProviderIsLeftAlone() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                let native = AssistantProvider(name: "Existing native", endpoint: "https://api.openai.com/v1", apiStyle: .realtime, models: ["gpt-realtime-2.1"], realtimeVoice: "cedar")
                try fixture.settings.upsertProvider(native, apiKey: "native-fixture-key")
                try fixture.settings.selectModel(providerID: native.id, modelID: "gpt-realtime-2.1")
                let providersBefore = fixture.settings.providers
                let keysBefore = fixture.keys.values
                XCTAssertFalse(try fixture.settings.installRealtimeConnectionIfNeeded())
                XCTAssertEqual(fixture.settings.providers, providersBefore)
                XCTAssertEqual(fixture.settings.selectedModel, AssistantModelSelection(providerID: native.id, modelID: "gpt-realtime-2.1"))
                XCTAssertEqual(fixture.settings.configuration.realtimeVoice, "cedar")
                XCTAssertEqual(fixture.keys.values, keysBefore)
            }
        }
    }

    func testRealtimeVoiceAndSearchModelRoundTripWithoutReplacingTheSelectedConversationModel() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                var native = AssistantProvider(
                    name: "Native",
                    endpoint: "https://api.openai.com/v1",
                    apiStyle: .realtime,
                    models: ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"],
                    webSearchEnabled: true,
                    realtimeVoice: "cedar",
                    webSearchModel: "gpt-6-luna"
                )
                let other = AssistantProvider(name: "Other", endpoint: "https://other.example/v1", models: ["text-model"])
                try fixture.settings.upsertProvider(native, apiKey: "voice-fixture-key")
                try fixture.settings.upsertProvider(other, apiKey: nil)
                try fixture.settings.selectModel(providerID: native.id, modelID: "gpt-realtime-2.1")
                native.realtimeVoice = "verse"
                native.webSearchModel = "gpt-6-astra"
                try fixture.settings.upsertProvider(native, apiKey: nil)

                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                XCTAssertEqual(restored.selectedModel, AssistantModelSelection(providerID: native.id, modelID: "gpt-realtime-2.1"))
                XCTAssertEqual(restored.configuration.model, "gpt-realtime-2.1")
                XCTAssertEqual(restored.configuration.apiStyle, .realtime)
                XCTAssertEqual(restored.configuration.realtimeVoice, "verse")
                XCTAssertEqual(restored.configuration.webSearchModel, "gpt-6-astra")
                XCTAssertTrue(restored.configuration.webSearchEnabled)
                XCTAssertEqual(restored.selectedProvider, native)
                XCTAssertEqual(try restored.apiKey(), "voice-fixture-key")
            }
        }
    }

    func testPreviouslyStoredProviderJSONWithoutRealtimeFieldsLoadsWithDefaults() async throws {
        try await MainActor.run {
            try withFixture { fixture in
                let id = UUID()
                let legacy: [[String: Any]] = [[
                    "id": id.uuidString,
                    "name": "Existing provider",
                    "endpoint": "https://api.openai.com/v1",
                    "apiStyle": "responses",
                    "models": ["gpt-6-luna"],
                    "systemPrompt": "Preserve this prompt.",
                    "webSearchEnabled": true
                ]]
                fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "assistant.providers")
                let selection = AssistantModelSelection(providerID: id, modelID: "gpt-6-luna")
                fixture.defaults.set(try JSONEncoder().encode(selection), forKey: "assistant.selectedModel")
                fixture.defaults.set(false, forKey: "assistant.demoMode")

                let restored = AssistantSettings(defaults: fixture.defaults, keyStore: fixture.keys)
                let provider = try XCTUnwrap(restored.selectedProvider)
                XCTAssertEqual(restored.providers.count, 1)
                XCTAssertEqual(provider.id, id)
                XCTAssertEqual(provider.apiStyle, .responses)
                XCTAssertEqual(provider.systemPrompt, "Preserve this prompt.")
                XCTAssertTrue(provider.webSearchEnabled)
                XCTAssertEqual(provider.realtimeVoice, "marin")
                XCTAssertEqual(provider.webSearchModel, "gpt-6-luna")
                XCTAssertEqual(restored.configuration.realtimeVoice, "marin")
                XCTAssertEqual(restored.configuration.webSearchModel, "gpt-6-luna")
                XCTAssertEqual(restored.selectedModel, selection)
                XCTAssertTrue(fixture.keys.values.isEmpty)
            }
        }
    }

    @MainActor
    private func configuredOpenAI(in fixture: MigrationFixture) throws -> AssistantProvider {
        let original = AssistantProvider(name: "OpenAI", endpoint: "https://api.openai.com/v1", apiStyle: .responses, models: ["gpt-6-luna"])
        try fixture.settings.upsertProvider(original, apiKey: "migration-fixture-key")
        return original
    }

    @MainActor
    private func withFixture(_ body: (MigrationFixture) throws -> Void) throws {
        let suite = "Findy.RealtimeSettingsTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = RealtimeMigrationMemoryKeys()
        try body(MigrationFixture(
            suite: suite,
            defaults: defaults,
            keys: keys,
            settings: AssistantSettings(defaults: defaults, keyStore: keys)
        ))
    }
}

private struct MigrationFixture {
    let suite: String
    let defaults: UserDefaults
    let keys: RealtimeMigrationMemoryKeys
    let settings: AssistantSettings
}
