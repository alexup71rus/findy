import AppIntents
import SwiftUI

@main
struct FindyApp: App {
    @UIApplicationDelegateAdaptor(FindyApplicationDelegate.self) private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = SessionLog.shared
        #if DEBUG
        DebugConnectionImport.runIfPresent()
        #if targetEnvironment(simulator)
        DebugUIFixtures.prepareIfRequested()
        #endif
        #endif
        FindyShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    #if DEBUG
                    await DebugRealtimeProbe.runMicrophoneGraphIfRequested()
                    await DebugRealtimeProbe.runIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    SessionLog.shared.record("app.scene", "phase=\(phase)")
                    if phase == .active {
                        VoiceSession.shared.refreshReadiness()
                        SpeechVoiceCatalog.shared.refresh()
                        Task { await PersonalData.shared.refresh() }
                    }
                }
        }
    }
}
