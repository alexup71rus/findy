import XCTest
import AssistantCore
@testable import ProviderSettings

private final class MemoryKeys: ProviderKeyStore {
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

final class ProviderSettingsTests: XCTestCase, @unchecked Sendable {
    func testPromptPresetMigrationAndPersistence() async throws {
        try await MainActor.run {
            let suite = "Findy.PresetTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            var provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1", models: ["model"])
            XCTAssertEqual(provider.promptPreset, .helpful)
            XCTAssertEqual(provider.customSystemPrompt, "")
            provider.systemPrompt = "Мой точный текст"
            try settings.upsertProvider(provider, apiKey: nil)
            provider.promptPreset = .helpful
            try settings.upsertProvider(provider, apiKey: nil)
            let restored = AssistantSettings(defaults: defaults, keyStore: keys)
            var loaded = try XCTUnwrap(restored.selectedProvider)
            XCTAssertEqual(loaded.customSystemPrompt, "Мой точный текст")
            XCTAssertEqual(restored.configuration.systemPrompt, AssistantConfiguration.defaultSystemPrompt)
            loaded.promptPreset = .custom
            try restored.upsertProvider(loaded, apiKey: nil)
            XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).configuration.systemPrompt, "Мой точный текст")

            let encoded = try JSONEncoder().encode(provider)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "promptPreset")
            object.removeValue(forKey: "customSystemPrompt")
            for prompt: String? in [nil, AssistantConfiguration.legacySystemPrompt, "Пользовательский текст", String(repeating: "я", count: 1501)] {
                object["systemPrompt"] = prompt
                let decoded = try JSONDecoder().decode(AssistantProvider.self, from: JSONSerialization.data(withJSONObject: object))
                let isDefault = prompt == nil || prompt == AssistantConfiguration.legacySystemPrompt
                XCTAssertEqual(decoded.promptPreset, isDefault ? .helpful : .custom)
                XCTAssertEqual(decoded.customSystemPrompt, isDefault ? "" : (prompt ?? ""))
                XCTAssertEqual(decoded.systemPrompt, isDefault ? AssistantConfiguration.defaultSystemPrompt : (prompt ?? ""))
            }
        }
    }

    func testCustomPromptAccepts1500CharactersAndRejects1501WithoutChangingSavedValue() async throws {
        try await MainActor.run {
            let suite = "Findy.PromptBoundary." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            let maximum = String(repeating: "я", count: 1499) + "👨‍👩‍👧‍👦"
            var provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1", models: ["model"], systemPrompt: maximum)
            try settings.upsertProvider(provider, apiKey: nil)
            XCTAssertEqual(AssistantLimits.systemPromptCharacters, 1500)
            XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).selectedProvider?.customSystemPrompt, maximum)
            provider.customSystemPrompt += "ю"
            XCTAssertThrowsError(try settings.upsertProvider(provider, apiKey: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("1500"))
            }
            XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).selectedProvider?.customSystemPrompt, maximum)
            XCTAssertEqual(AssistantLimits.inputCharacters, 500)
            XCTAssertEqual(AssistantLimits.memoryNoteCharacters, 500)
        }
    }

    func testBuiltinPresetsRoundTripAndUseTheirOwnEffectivePrompts() async throws {
        try await MainActor.run {
            let suite = "Findy.BuiltinPresets." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            var provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1", models: ["model"], systemPrompt: "Keep this custom prompt")
            try settings.upsertProvider(provider, apiKey: nil)
            var prompts = Set<String>()
            for preset in [SystemPromptPreset.helpful, .cynical, .motivating] {
                provider.promptPreset = preset
                try settings.upsertProvider(provider, apiKey: nil)
                let restored = AssistantSettings(defaults: defaults, keyStore: keys)
                let loaded = try XCTUnwrap(restored.selectedProvider)
                let effective = try XCTUnwrap(preset.builtinPrompt)
                XCTAssertEqual(loaded.promptPreset, preset)
                XCTAssertEqual(loaded.customSystemPrompt, "Keep this custom prompt")
                XCTAssertEqual(loaded.systemPrompt, effective)
                XCTAssertEqual(restored.configuration.systemPrompt, effective)
                XCTAssertEqual(loaded.configuration(for: "model").systemPrompt, effective)
                XCTAssertLessThanOrEqual(effective.count, AssistantLimits.systemPromptCharacters)
                prompts.insert(effective)
            }
            XCTAssertEqual(prompts.count, 3)
            provider.promptPreset = .custom
            try settings.upsertProvider(provider, apiKey: nil)
            XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).configuration.systemPrompt, "Keep this custom prompt")
        }
    }

    func testOnboardingCompletionPersistsOnlyInItsOwnSettingsSuite() async {
        await MainActor.run {
            let suite = "Findy.OnboardingTest." + UUID().uuidString
            let otherSuite = "Findy.OnboardingTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let otherDefaults = UserDefaults(suiteName: otherSuite)!
            defer {
                defaults.removePersistentDomain(forName: suite)
                otherDefaults.removePersistentDomain(forName: otherSuite)
            }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertFalse(settings.hasSeenOnboarding)
            settings.completeOnboarding()
            XCTAssertTrue(settings.hasSeenOnboarding)
            XCTAssertFalse(settings.isConfiguredForChat)
            XCTAssertTrue(AssistantSettings(defaults: defaults, keyStore: keys).hasSeenOnboarding)
            XCTAssertFalse(AssistantSettings(defaults: otherDefaults, keyStore: keys).hasSeenOnboarding)
        }
    }

    func testLegacyDemoFlagCannotConfigureChatOrOverrideARealConnection() async throws {
        try await MainActor.run {
            for legacyMode in [false, true] {
                let suite = "Findy.MigrationTest." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(legacyMode, forKey: "assistant.demoMode")
                let keys = MemoryKeys()
                let settings = AssistantSettings(defaults: defaults, keyStore: keys)
                XCTAssertFalse(settings.isConfiguredForChat)
                XCTAssertFalse(settings.providerSharingAllowed)
                XCTAssertEqual(settings.configurationSummary, "Выберите модель")
                let unconfigured = AssistantSettings(defaults: defaults, keyStore: keys)
                XCTAssertFalse(unconfigured.isConfiguredForChat)
                var provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1")
                try settings.upsertProvider(provider, apiKey: nil)
                XCTAssertFalse(settings.isConfiguredForChat)
                provider.models = ["local-model"]
                provider.systemPrompt = "Keep my instructions."
                try settings.upsertProvider(provider, apiKey: "fixture-key")
                settings.grantSharing(for: provider)
                let restored = AssistantSettings(defaults: defaults, keyStore: keys)
                XCTAssertTrue(restored.isConfiguredForChat)
                XCTAssertTrue(restored.providerSharingAllowed)
                XCTAssertEqual(restored.configurationSummary, "local-model · Local")
                XCTAssertEqual(restored.configuration.systemPrompt, "Keep my instructions.")
                XCTAssertEqual(restored.selectedProvider?.id, provider.id)
                XCTAssertEqual(try restored.apiKey(), "fixture-key")
            }
        }
    }

    func testPromptUpdatePersistsExactlyWithoutChangingSelectionCredentialsOrConsent() async throws {
        try await MainActor.run {
            let suite = "Findy.PromptTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            var provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1", models: ["first", "second"])
            try settings.upsertProvider(provider, apiKey: "fixture-key")
            try settings.selectModel(providerID: provider.id, modelID: "second")
            settings.grantSharing(for: provider)
            for prompt in ["  Отвечай кратко.\nСохраняй переносы.  ", ""] {
                provider.systemPrompt = prompt
                try settings.upsertProvider(provider, apiKey: nil)
                let restored = AssistantSettings(defaults: defaults, keyStore: keys)
                XCTAssertEqual(restored.selectedProvider?.systemPrompt, prompt)
                XCTAssertEqual(restored.configuration.systemPrompt, prompt)
                XCTAssertEqual(restored.selectedModel?.modelID, "second")
                XCTAssertEqual(try restored.apiKey(), "fixture-key")
                XCTAssertTrue(restored.providerSharingAllowed)
            }
        }
    }

    func testRemovingTheLastProviderRequiresSetupAfterRelaunch() async throws {
        try await MainActor.run {
            let suite = "Findy.SetupTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            let provider = AssistantProvider(name: "Local", endpoint: "http://127.0.0.1:11434/v1", models: ["local-model"])
            try settings.upsertProvider(provider, apiKey: nil)
            XCTAssertTrue(settings.isConfiguredForChat)
            try settings.deleteProvider(id: provider.id)
            XCTAssertFalse(settings.isConfiguredForChat)
            let restored = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertFalse(restored.isConfiguredForChat)
        }
    }

    func testSharingConsentIsPersistentAndBoundToProviderAndOrigin() async throws {
        try await MainActor.run {
            let suite = "Findy.ConsentTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            var first = AssistantProvider(name: "First", endpoint: "https://one.example/v1", apiStyle: .realtime, models: ["a", "b"])
            let other = AssistantProvider(name: "Other", endpoint: "https://one.example/v1", models: ["c"])
            try settings.upsertProvider(first, apiKey: nil)
            try settings.upsertProvider(other, apiKey: nil)
            XCTAssertFalse(settings.providerSharingAllowed)
            XCTAssertFalse(settings.providerSharingAllowed)
            settings.grantSharing(for: first)
            XCTAssertTrue(settings.providerSharingAllowed)
            XCTAssertFalse(settings.sharingAllowed(for: other))
            try settings.selectModel(providerID: first.id, modelID: "b")
            XCTAssertTrue(settings.providerSharingAllowed)
            first.endpoint = "https://two.example/v1"
            try settings.upsertProvider(first, apiKey: nil)
            XCTAssertFalse(settings.providerSharingAllowed)
            let restored = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertFalse(restored.providerSharingAllowed)
            first.endpoint = "https://one.example/v2"
            XCTAssertTrue(restored.sharingAllowed(for: first))
            restored.revokeSharing(for: first)
            XCTAssertFalse(AssistantSettings(defaults: defaults, keyStore: keys).sharingAllowed(for: first))
        }
    }

    func testVoiceModePersistenceAndUnsupportedFallback() async throws {
        try await MainActor.run {
            let suite = "Findy.VoiceModeTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            let realtime = AssistantProvider(name: "Realtime", endpoint: "https://one.example/v1", apiStyle: .realtime, models: ["a"])
            let text = AssistantProvider(name: "Text", endpoint: "https://two.example/v1", models: ["b"])
            try settings.upsertProvider(realtime, apiKey: nil)
            try settings.upsertProvider(text, apiKey: nil)
            XCTAssertTrue(settings.usesProviderVoice)
            settings.setVoiceMode(.system)
            XCTAssertFalse(AssistantSettings(defaults: defaults, keyStore: keys).usesProviderVoice)
            settings.setVoiceMode(.provider)
            try settings.selectModel(providerID: text.id, modelID: "b")
            XCTAssertFalse(settings.supportsProviderVoice)
            XCTAssertFalse(settings.usesProviderVoice)
            XCTAssertEqual(settings.voiceMode, .provider)
            try settings.selectModel(providerID: realtime.id, modelID: "a")
            XCTAssertTrue(settings.usesProviderVoice)
        }
    }

    func testVoiceAndRatePersistIndependentlyOfProvidersAndCanReturnToAutomatic() async throws {
        await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertNil(settings.speechVoiceIdentifier)
            XCTAssertEqual(settings.speechRate, 0.5)
            settings.setSpeechVoiceIdentifier(" voice-fixture ")
            settings.setSpeechRate(0.45)
            let restored = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertEqual(restored.speechVoiceIdentifier, "voice-fixture")
            XCTAssertEqual(restored.speechRate, 0.45)
            XCTAssertTrue(restored.providers.isEmpty)
            XCTAssertNil(restored.selectedModel)
            restored.setSpeechVoiceIdentifier(nil)
            XCTAssertNil(AssistantSettings(defaults: defaults, keyStore: keys).speechVoiceIdentifier)
            XCTAssertTrue(keys.values.isEmpty)
        }
    }

    func testSpeechRateBoundsAndInvalidStoredValuesAreSafe() async throws {
        await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            settings.setSpeechRate(-10)
            XCTAssertEqual(settings.speechRate, 0.4)
            settings.setSpeechRate(10)
            XCTAssertEqual(settings.speechRate, 0.6)
            settings.setSpeechRate(.nan)
            XCTAssertEqual(settings.speechRate, 0.6)
            defaults.set(Double.nan, forKey: "speech.rate")
            XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).speechRate, 0.5)
        }
    }

    func testSelectingAnotherProviderReplacesTheSingleSelectionAndPersistsIt() async throws {
        try await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            let first = AssistantProvider(name: "First", endpoint: "https://one.example/v1", models: ["alpha", "beta"])
            let second = AssistantProvider(name: "Second", endpoint: "http://192.168.1.9:11434/v1", models: ["gamma"])
            try settings.upsertProvider(first, apiKey: nil)
            try settings.upsertProvider(second, apiKey: nil)
            try settings.selectModel(providerID: second.id, modelID: "gamma")
            XCTAssertEqual(settings.selectedModel, AssistantModelSelection(providerID: second.id, modelID: "gamma"))
            XCTAssertEqual(settings.configuration.model, "gamma")
            XCTAssertEqual(try settings.apiKey(), "")
            let restored = AssistantSettings(defaults: defaults, keyStore: keys)
            XCTAssertEqual(restored.selectedModel, settings.selectedModel)
            XCTAssertThrowsError(try settings.selectModel(providerID: first.id, modelID: "absent"))
            XCTAssertEqual(settings.selectedModel?.providerID, second.id)
        }
    }

    func testDeletingSelectedModelAndProviderAlwaysLeavesAValidSelectionOrRequiresSetup() async throws {
        try await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AssistantSettings(defaults: defaults, keyStore: MemoryKeys())
            var first = AssistantProvider(name: "First", endpoint: "https://one.example/v1", models: [" alpha ", "beta", "alpha", ""])
            let second = AssistantProvider(name: "Second", endpoint: "https://two.example/v1", models: ["gamma"])
            try settings.upsertProvider(first, apiKey: nil)
            try settings.upsertProvider(second, apiKey: nil)
            XCTAssertEqual(settings.providers[0].models, ["alpha", "beta"])
            try settings.selectModel(providerID: first.id, modelID: "beta")
            first.models = []
            try settings.upsertProvider(first, apiKey: nil)
            XCTAssertEqual(settings.selectedModel?.providerID, second.id)
            try settings.deleteProvider(id: second.id)
            XCTAssertNil(settings.selectedModel)
        }
    }

    func testCredentialsAreIsolatedByProviderAndOriginAndAnonymousAuthIsAllowed() async throws {
        try await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            var first = AssistantProvider(name: "First", endpoint: "https://same.example/v1", models: ["alpha"])
            let other = AssistantProvider(name: "Other account", endpoint: first.endpoint, models: ["alpha"])
            try settings.upsertProvider(first, apiKey: "fixture-key")
            try settings.upsertProvider(other, apiKey: nil)
            XCTAssertEqual(try settings.apiKey(for: first), "fixture-key")
            XCTAssertEqual(try settings.apiKey(for: other), "")
            let oldOrigin = first
            first.endpoint = "https://changed.example/v1"
            try settings.upsertProvider(first, apiKey: nil)
            XCTAssertEqual(try settings.apiKey(for: first), "")
            XCTAssertEqual(try settings.apiKey(for: oldOrigin), "fixture-key")
            try settings.upsertProvider(first, apiKey: "new-fixture-key")
            try settings.deleteProvider(id: first.id)
            XCTAssertTrue(keys.values.isEmpty)
            XCTAssertEqual(settings.selectedModel?.providerID, other.id)
            XCTAssertEqual(try settings.apiKey(), "")
        }
    }

    func testInvalidOrUnpersistableCredentialsDoNotPartiallySaveProvider() async throws {
        try await MainActor.run {
            let suite = "Findy.SettingsTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = MemoryKeys()
            let settings = AssistantSettings(defaults: defaults, keyStore: keys)
            let provider = AssistantProvider(name: "First", endpoint: "https://one.example/v1", models: ["alpha"])
            XCTAssertThrowsError(try settings.upsertProvider(provider, apiKey: "fixture\nkey"))
            XCTAssertTrue(settings.providers.isEmpty)
            keys.failWrites = true
            XCTAssertThrowsError(try settings.upsertProvider(provider, apiKey: "fixture-key"))
            XCTAssertTrue(settings.providers.isEmpty)
            XCTAssertNil(settings.selectedModel)
        }
    }
}
