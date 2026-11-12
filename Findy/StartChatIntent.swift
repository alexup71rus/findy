import AppIntents

struct StartChatIntent: AudioRecordingIntent, AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Чат"
    static var description = IntentDescription(
        "Начать голосовой разговор с выбранной моделью. Сначала настройте подключение и разрешения в Findy."
    )
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        SessionLog.shared.record("intent.received", "intent=StartChatIntent")
        try await VoiceSession.shared.start(source: "AppIntent", deferAudio: true)
        SessionLog.shared.record("intent.completed")
        // A spoken Siri dialog here would compete with the app for the audio route.
        return .result()
    }
}

struct FindyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartChatIntent(),
            phrases: [
                "Чат в \(.applicationName)",
                "Начни чат в \(.applicationName)"
            ],
            shortTitle: "Чат",
            systemImageName: "mic.fill"
        )
    }
}
