import UIKit
import UserNotifications

@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var showingReminders = false
    @Published var selectedReminderID: UUID?

    func openReminder(id: UUID?) {
        selectedReminderID = id
        showingReminders = true
    }
}

@MainActor
final class FindyApplicationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.content.userInfo["reminderID"] as? String
        let id = identifier.flatMap(UUID.init(uuidString:))
        await MainActor.run { AppNavigation.shared.openReminder(id: id) }
    }
}
