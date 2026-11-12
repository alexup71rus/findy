import XCTest
@testable import ProviderSettings

private final class TimeoutSettingsMemoryKeys: ProviderKeyStore {
    var writeCount = 0
    func read(for account: String) throws -> String { "" }
    func containsKey(for account: String) throws -> Bool { false }
    func save(_ key: String, for account: String) throws { writeCount += 1 }
    func remove(for account: String) throws { writeCount += 1 }
    func removeAll(for providerID: UUID) throws { writeCount += 1 }
}

final class VoiceTimeoutSettingsTests: XCTestCase, @unchecked Sendable {
    func testSilenceTimeoutDefaultsToFiveSecondsWithoutCreatingAConnection() async throws {
        try await MainActor.run {
            try withFixture { settings, defaults, keys in
                XCTAssertEqual(settings.silenceTimeoutSeconds, 5)
                XCTAssertNil(defaults.object(forKey: "voice.silenceTimeout"))
                XCTAssertTrue(settings.providers.isEmpty)
                XCTAssertNil(settings.selectedModel)
                XCTAssertFalse(settings.isConfiguredForChat)
                XCTAssertEqual(keys.writeCount, 0)
            }
        }
    }

    func testPresetTimeoutsAndDisabledTimeoutRoundTripIndependentlyOfProviders() async throws {
        try await MainActor.run {
            try withFixture { settings, defaults, keys in
                for seconds in [5.0, 10, 15, 30, 60, 120, 0] {
                    settings.setSilenceTimeoutSeconds(seconds)
                    XCTAssertEqual(settings.silenceTimeoutSeconds, seconds)
                    XCTAssertEqual(defaults.double(forKey: "voice.silenceTimeout"), seconds)
                    let restored = AssistantSettings(defaults: defaults, keyStore: keys)
                    XCTAssertEqual(restored.silenceTimeoutSeconds, seconds)
                    XCTAssertTrue(restored.providers.isEmpty)
                    XCTAssertNil(restored.selectedModel)
                }
                XCTAssertEqual(keys.writeCount, 0)
            }
        }
    }

    func testFiniteTimeoutsClampToSupportedRangeWhileZeroRemainsDisabled() async throws {
        try await MainActor.run {
            try withFixture { settings, defaults, keys in
                for (input, expected) in [
                    (-100.0, 5.0),
                    (-Double.leastNonzeroMagnitude, 5.0),
                    (Double.leastNonzeroMagnitude, 5.0),
                    (4.9, 5.0),
                    (7.5, 7.5),
                    (121.0, 120.0),
                    (Double.greatestFiniteMagnitude, 120.0),
                    (0.0, 0.0)
                ] {
                    settings.setSilenceTimeoutSeconds(input)
                    XCTAssertEqual(settings.silenceTimeoutSeconds, expected)
                    XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).silenceTimeoutSeconds, expected)
                }
                XCTAssertEqual(keys.writeCount, 0)
            }
        }
    }

    func testNonfiniteSetterInputsDoNotReplaceTheSavedChoice() async throws {
        try await MainActor.run {
            try withFixture { settings, defaults, keys in
                settings.setSilenceTimeoutSeconds(30)
                for invalid in [Double.nan, .infinity, -.infinity] {
                    settings.setSilenceTimeoutSeconds(invalid)
                    XCTAssertEqual(settings.silenceTimeoutSeconds, 30)
                    XCTAssertEqual(defaults.double(forKey: "voice.silenceTimeout"), 30)
                    XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).silenceTimeoutSeconds, 30)
                }
                settings.setSilenceTimeoutSeconds(0)
                settings.setSilenceTimeoutSeconds(.nan)
                XCTAssertEqual(settings.silenceTimeoutSeconds, 0)
                XCTAssertEqual(AssistantSettings(defaults: defaults, keyStore: keys).silenceTimeoutSeconds, 0)
            }
        }
    }

    func testInvalidStoredValuesUseFiveSecondsIncludingBooleanFalse() async throws {
        try await MainActor.run {
            try withFixture { _, defaults, keys in
                let invalid: [Any] = [
                    Double.nan, Double.infinity, -Double.infinity,
                    -1.0, 4.0, 121.0,
                    "30", false, true, Data([1, 2, 3]), Date(timeIntervalSince1970: 0)
                ]
                for value in invalid {
                    defaults.set(value, forKey: "voice.silenceTimeout")
                    let restored = AssistantSettings(defaults: defaults, keyStore: keys)
                    XCTAssertEqual(restored.silenceTimeoutSeconds, 5, "Invalid stored timeout: \(type(of: value))")
                }
                XCTAssertEqual(keys.writeCount, 0)
            }
        }
    }

    @MainActor
    private func withFixture(_ body: (AssistantSettings, UserDefaults, TimeoutSettingsMemoryKeys) throws -> Void) throws {
        let suite = "Findy.VoiceTimeoutTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = TimeoutSettingsMemoryKeys()
        try body(AssistantSettings(defaults: defaults, keyStore: keys), defaults, keys)
    }
}
