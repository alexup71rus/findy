// Standalone fake-client smoke. No notification center, microphone or network.
// swiftc -target arm64-apple-macos15.0 Sources/AssistantCore/AssistantMessage.swift \
//   Sources/AssistantCore/AssistantLimits.swift Sources/AssistantCore/ReminderScheduleRules.swift Sources/LocalData/*.swift \
//   Findy/ReminderScheduler.swift Tests/DeviceAudio/ReminderSchedulerSmoke.swift \
//   -lsqlite3 -o /tmp/findy-reminder-scheduler-smoke
import Foundation
import UserNotifications

private enum SmokeFailure: Error { case assertion(String), injected }

private final class MemoryReminders: ReminderPersisting {
    var values: [UUID: LocalReminder] = [:]
    var failingWrites = 0
    var omittedFromList = Set<UUID>()
    var onCommit: (() -> Void)?
    func upsertReminder(_ reminder: LocalReminder) throws -> LocalReminder {
        if failingWrites > 0 { failingWrites -= 1; throw SmokeFailure.injected }
        values[reminder.id] = reminder
        onCommit?()
        return reminder
    }
    func getReminder(id: UUID) throws -> LocalReminder? { values[id] }
    func reminders(status: LocalReminderStatus?, limit: Int) throws -> [LocalReminder] {
        Array(values.values.filter { !omittedFromList.contains($0.id) && (status == nil || $0.status == status) }.sorted { $0.dueAt < $1.dueAt }.prefix(limit))
    }
    func deleteReminder(id: UUID) throws {
        if failingWrites > 0 { failingWrites -= 1; throw SmokeFailure.injected }
        values[id] = nil
    }
}

@MainActor
private final class FakeNotifications: ReminderNotificationClient {
    var permission: UNAuthorizationStatus = .authorized
    var pending: [String: UNNotificationRequest] = [:]
    var authorizationRequests = 0
    var additions = 0
    var failAddNumber: Int?
    var cancelAfterAdd = false
    var delayPendingRead = false
    var removedDelivered = Set<String>()
    func settings() async -> ReminderNotificationSettings {
        ReminderNotificationSettings(authorizationStatus: permission, alertsEnabled: permission == .authorized, soundsEnabled: permission == .authorized)
    }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        permission = .authorized
        return true
    }
    func pendingRequests() async -> [UNNotificationRequest] {
        if delayPendingRead { try? await Task.sleep(for: .milliseconds(10)) }
        return Array(pending.values)
    }
    func add(_ request: UNNotificationRequest) async throws {
        additions += 1
        if failAddNumber == additions { throw SmokeFailure.injected }
        pending[request.identifier] = request
        if cancelAfterAdd { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func removePending(ids: [String]) { for id in ids { pending[id] = nil } }
    func removeDelivered(ids: [String]) { removedDelivered.formUnion(ids) }
}

@main
struct ReminderSchedulerSmoke {
    @MainActor
    static func main() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw SmokeFailure.assertion(message) }
        }
        func fixture(foreground: Bool = false) -> (MemoryReminders, FakeNotifications, ReminderScheduler) {
            let store = MemoryReminders()
            let notifications = FakeNotifications()
            let scheduler = ReminderScheduler(persistence: store, notifications: notifications, isForeground: { foreground })
            return (store, notifications, scheduler)
        }
        let dueAt = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(3600).timeIntervalSince1970))

        do {
            let (store, notifications, scheduler) = fixture()
            let reminder = try await scheduler.create(title: "Купить\nмолоко", dueAt: dueAt)
            let request = try unwrap(notifications.pending[reminder.notificationIdentifier], "Missing OS request")
            try check(store.values[reminder.id] == reminder && reminder.status == .scheduled, "Success wasn't persisted")
            try check(request.content.body == "Купить молоко" && request.content.sound != nil, "Notification content")
            try check(request.content.userInfo[ReminderScheduler.reminderIDUserInfoKey] as? String == reminder.id.uuidString, "Stable navigation identifier")
            let trigger = try unwrap(request.trigger as? UNCalendarNotificationTrigger, "Calendar trigger")
            try check(!trigger.repeats && trigger.nextTriggerDate() == reminder.dueAt, "Exact one-off instant")
            try check(!scheduler.isBusy && notifications.authorizationRequests == 0, "Wrong lifecycle")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            notifications.permission = .notDetermined
            do { _ = try await scheduler.create(title: "Магазин", dueAt: dueAt); throw SmokeFailure.assertion("Background permission unexpectedly granted") }
            catch let error as ReminderSchedulerError { try check(error == .permissionRequired, "Expected foreground instruction") }
            try check(store.values.isEmpty && notifications.pending.isEmpty && notifications.authorizationRequests == 0, "Background prompt or false task")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture(foreground: true)
            notifications.permission = .notDetermined
            let reminder = try await scheduler.create(title: "Магазин", dueAt: dueAt)
            try check(notifications.authorizationRequests == 1 && store.values[reminder.id] != nil, "Permission wasn't requested in context")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture(foreground: true)
            notifications.permission = .denied
            do { _ = try await scheduler.create(title: "Магазин", dueAt: dueAt); throw SmokeFailure.assertion("Denied permission accepted") }
            catch let error as ReminderSchedulerError { try check(error == .permissionDenied, "Wrong denied error") }
            try check(store.values.isEmpty && notifications.pending.isEmpty && notifications.authorizationRequests == 0, "Denied task was created")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            notifications.failAddNumber = 1
            do { _ = try await scheduler.create(title: "Магазин", dueAt: dueAt); throw SmokeFailure.assertion("Add error ignored") }
            catch let error as ReminderSchedulerError { try check(error == .schedulingFailed, "Wrong add error") }
            try check(store.values.isEmpty && notifications.pending.isEmpty, "OS failure falsely persisted")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            store.failingWrites = 1
            do { _ = try await scheduler.create(title: "Магазин", dueAt: dueAt); throw SmokeFailure.assertion("Storage error ignored") }
            catch let error as ReminderSchedulerError { try check(error == .storageFailed, "Wrong storage error") }
            try check(store.values.isEmpty && notifications.pending.isEmpty && notifications.additions == 1, "Uncommitted alarm survived")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let original = try await scheduler.create(title: "Было", dueAt: dueAt)
            store.failingWrites = 1
            do { _ = try await scheduler.update(id: original.id, title: "Стало", dueAt: dueAt.addingTimeInterval(3600)); throw SmokeFailure.assertion("Update storage error ignored") }
            catch let error as ReminderSchedulerError { try check(error == .storageFailed, "Wrong rollback error") }
            try check(store.values[original.id] == original, "Original database record was lost")
            let pending = try unwrap(notifications.pending[original.notificationIdentifier], "Original request not restored")
            try check(pending.content.body == "Было" && (pending.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == dueAt, "Original OS notification not restored")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let original = try await scheduler.create(title: "Было", dueAt: dueAt)
            store.failingWrites = 1
            notifications.failAddNumber = 3 // replacement=2, restoration=3
            do { _ = try await scheduler.update(id: original.id, title: "Стало", dueAt: dueAt.addingTimeInterval(3600)); throw SmokeFailure.assertion("Restoration error ignored") }
            catch let error as ReminderSchedulerError { try check(error == .restorationFailed, "Wrong restoration failure") }
            try check(store.values[original.id]?.status == .blocked && notifications.pending.isEmpty, "Failed restore left a wrong-time alarm active")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            notifications.cancelAfterAdd = true
            do { _ = try await scheduler.create(title: "Магазин", dueAt: dueAt); throw SmokeFailure.assertion("Cancellation ignored before commit") }
            catch is CancellationError {}
            try check(store.values.isEmpty && notifications.pending.isEmpty, "Cancelled uncommitted alarm survived")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            store.onCommit = { withUnsafeCurrentTask { $0?.cancel() } }
            let saved = try await scheduler.create(title: "Магазин", dueAt: dueAt)
            try check(store.values[saved.id] != nil && notifications.pending[saved.notificationIdentifier] != nil, "Voice interruption undid a committed action")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let first = try await scheduler.create(title: "Магазин", dueAt: dueAt)
            let duplicate = try await scheduler.create(title: "Магазин", dueAt: dueAt)
            let differentTime = try await scheduler.create(title: "Магазин", dueAt: dueAt.addingTimeInterval(60))
            try check(first.id == duplicate.id && differentTime.id != first.id && store.values.count == 2 && notifications.pending.count == 2, "Exact duplicate suppression")
            try await scheduler.complete(id: first.id)
            let recreated = try await scheduler.create(title: "Магазин", dueAt: dueAt)
            try check(recreated.id != first.id && store.values[first.id]?.status == .completed, "Completed reminders were incorrectly deduplicated")
            try await scheduler.delete(id: recreated.id)
            try check(store.values[recreated.id] == nil && notifications.pending[recreated.notificationIdentifier] == nil, "Delete didn't remove both stores")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            for _ in 0..<59 {
                let content = UNMutableNotificationContent()
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: dueAt), repeats: false))
                notifications.pending[request.identifier] = request
            }
            notifications.delayPendingRead = true
            let a = Task { @MainActor in try await scheduler.create(title: "Один", dueAt: dueAt) }
            let b = Task { @MainActor in try await scheduler.create(title: "Два", dueAt: dueAt) }
            let outcomes = await [a.result, b.result]
            let successCount = outcomes.filter { if case .success = $0 { return true }; return false }.count
            try check(successCount == 1 && notifications.pending.count == 60 && store.values.count == 1 && !scheduler.isBusy, "Concurrent operations exceeded the quota")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let absent = LocalReminder(title: "Будущее", dueAt: dueAt)
            let past = LocalReminder(title: "Прошлое", dueAt: Date().addingTimeInterval(-60))
            store.values[absent.id] = absent
            store.values[past.id] = past
            try await scheduler.refresh()
            try check(store.values[absent.id]?.status == .blocked && store.values[past.id]?.status == .scheduled, "Reconciliation falsely completed a past reminder")
            let content = UNMutableNotificationContent()
            content.body = absent.title
            content.categoryIdentifier = ReminderScheduler.notificationCategoryIdentifier
            content.userInfo = [ReminderScheduler.reminderIDUserInfoKey: absent.id.uuidString]
            notifications.pending[absent.notificationIdentifier] = UNNotificationRequest(identifier: absent.notificationIdentifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: dueAt), repeats: false))
            try await scheduler.refresh()
            try check(store.values[absent.id]?.status == .scheduled && notifications.authorizationRequests == 0, "Observed pending request wasn't reactivated")
            let pastContent = UNMutableNotificationContent()
            pastContent.body = past.title
            pastContent.categoryIdentifier = ReminderScheduler.notificationCategoryIdentifier
            pastContent.userInfo = [ReminderScheduler.reminderIDUserInfoKey: past.id.uuidString]
            notifications.pending[past.notificationIdentifier] = UNNotificationRequest(identifier: past.notificationIdentifier, content: pastContent,
                trigger: UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: past.dueAt), repeats: false))
            try await scheduler.refresh()
            try check(store.values[past.id]?.status == .scheduled && notifications.pending[past.notificationIdentifier] != nil, "A due pending snapshot was mistaken for a conflicting edit")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let original = try await scheduler.create(title: "Было", dueAt: dueAt)
            // Simulate a killed process after the OS edit, before SQLite commit.
            let content = UNMutableNotificationContent()
            content.body = "Стало"
            content.categoryIdentifier = ReminderScheduler.notificationCategoryIdentifier
            content.userInfo = [ReminderScheduler.reminderIDUserInfoKey: original.id.uuidString]
            notifications.pending[original.notificationIdentifier] = UNNotificationRequest(identifier: original.notificationIdentifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: dueAt.addingTimeInterval(3600)), repeats: false))
            try await scheduler.refresh()
            try check(store.values[original.id]?.title == "Было" && store.values[original.id]?.status == .blocked, "Interrupted edit was reported as scheduled")
            try check(notifications.pending[original.notificationIdentifier] == nil && notifications.authorizationRequests == 0, "Conflicting alarm survived or refresh prompted")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let orphan = try await scheduler.create(title: "Без записи", dueAt: dueAt)
            // Simulate a killed process between deleting SQLite and the OS alarm.
            store.values[orphan.id] = nil
            let unrelated = UNNotificationRequest(identifier: "unrelated", content: UNMutableNotificationContent(),
                trigger: UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: dueAt), repeats: false))
            notifications.pending[unrelated.identifier] = unrelated
            try await scheduler.refresh()
            try check(notifications.pending[orphan.notificationIdentifier] == nil && notifications.pending[unrelated.identifier] != nil, "Orphan recovery removed the wrong alarm")
            try check(store.values.isEmpty && notifications.authorizationRequests == 0, "Orphan recovery created data or prompted")
            passed += 1
        }
        do {
            let (store, notifications, scheduler) = fixture()
            let reminder = try await scheduler.create(title: "За пределами страницы", dueAt: dueAt)
            // A bounded archive page can omit an existing future reminder.
            store.omittedFromList.insert(reminder.id)
            try await scheduler.refresh()
            try check(notifications.pending[reminder.notificationIdentifier] != nil && store.values[reminder.id]?.status == .scheduled, "Bounded list was mistaken for a deleted reminder")
            passed += 1
        }
        print("PASS: \(passed) reminder scheduler scenarios; no real notifications, microphone or network used.")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SmokeFailure.assertion(message) }
        return value
    }
}
