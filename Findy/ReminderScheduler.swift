import Combine
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AssistantCore)
import AssistantCore
#endif
#if canImport(LocalData)
import LocalData
#endif

enum ReminderSchedulerError: Error, LocalizedError, Equatable, Sendable {
    case permissionRequired
    case permissionDenied
    case notFound
    case activeLimit
    case schedulingFailed
    case storageFailed
    case restorationFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Откройте Findy и разрешите уведомления в разделе «Напоминания»."
        case .permissionDenied:
            return "Уведомления Findy выключены. Включите их в настройках iPhone."
        case .notFound:
            return "Напоминание больше не найдено. Обновите список."
        case .activeLimit:
            return "Достигнут лимит активных напоминаний Findy. Завершите или удалите одно из них."
        case .schedulingFailed:
            return "iOS не удалось запланировать уведомление. Попробуйте ещё раз."
        case .storageFailed:
            return "Не удалось сохранить напоминание на iPhone."
        case .restorationFailed:
            return "Не удалось восстановить прежнее уведомление. Проверьте напоминание в списке."
        }
    }
}

/// All side effects are local. Mutations are serialized because function calls
/// and the reminders screen may otherwise schedule concurrently across awaits.
@MainActor
final class ReminderScheduler: ObservableObject {
    static let notificationCategoryIdentifier = "FINDY_REMINDER"
    static let reminderIDUserInfoKey = "reminderID"
    // A Findy policy, not a claim about the operating system's current quota.
    static let maximumPendingNotifications = 60

    @Published private(set) var reminders: [LocalReminder] = []
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var alertsEnabled = false
    @Published private(set) var soundsEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private let persistence: any ReminderPersisting
    private let notifications: any ReminderNotificationClient
    private let isForeground: @MainActor () -> Bool
    private let currentDate: @MainActor () -> Date
    private var mutationTail: Task<Void, Never>?
    private var queuedOperations = 0

    var canSendNotifications: Bool {
        if authorizationStatus == .authorized || authorizationStatus == .provisional { return true }
        #if os(iOS)
        return authorizationStatus == .ephemeral
        #else
        return false
        #endif
    }

    convenience init(store: LocalDataStore, center: UNUserNotificationCenter = .current()) {
        self.init(persistence: store, notifications: SystemReminderNotificationClient(center: center), isForeground: {
            #if canImport(UIKit)
            UIApplication.shared.applicationState == .active
            #else
            false
            #endif
        })
    }

    /// Injectable boundaries also allow transactional behavior to be verified
    /// without scheduling real notifications in development tests.
    init(persistence: any ReminderPersisting, notifications: any ReminderNotificationClient,
         isForeground: @escaping @MainActor () -> Bool, currentDate: @escaping @MainActor () -> Date = { Date() }) {
        self.persistence = persistence
        self.notifications = notifications
        self.isForeground = isForeground
        self.currentDate = currentDate
        do { reminders = try persistence.reminders(status: nil, limit: 10_000) }
        catch { lastError = ReminderSchedulerError.storageFailed.localizedDescription }
    }

    @discardableResult
    func create(title: String, dueAt: Date) async throws -> LocalReminder {
        try await serialized { [self] in
            let schedule = try ReminderScheduleRules.validate(title: title, dueAt: dueAt, now: currentDate())
            try await ensurePermission()
            let pending = await notifications.pendingRequests()
            let pendingIDs = Set(pending.map(\.identifier))
            let existing: [LocalReminder]
            do { existing = try persistence.reminders(status: nil, limit: 10_000) }
            catch { throw ReminderSchedulerError.storageFailed }
            if var duplicate = existing.first(where: {
                $0.status != .completed && $0.title == schedule.title && $0.dueAt == schedule.dueAt
                    && pendingIDs.contains($0.notificationIdentifier)
            }) {
                if duplicate.status == .blocked {
                    try Task.checkCancellation()
                    duplicate.status = .scheduled
                    duplicate.updatedAt = currentDate()
                    do { duplicate = try persistence.upsertReminder(duplicate) }
                    catch { throw ReminderSchedulerError.storageFailed }
                }
                reloadList()
                return duplicate
            }
            guard pending.count < Self.maximumPendingNotifications else { throw ReminderSchedulerError.activeLimit }
            try Task.checkCancellation()
            let instant = currentDate()
            let reminder = LocalReminder(title: schedule.title, dueAt: schedule.dueAt, createdAt: instant, updatedAt: instant, status: .scheduled)
            let request = try makeRequest(reminder)
            do { try await notifications.add(request) }
            catch is CancellationError {
                notifications.removePending(ids: [reminder.notificationIdentifier])
                throw CancellationError()
            } catch {
                notifications.removePending(ids: [reminder.notificationIdentifier])
                throw ReminderSchedulerError.schedulingFailed
            }
            do {
                try Task.checkCancellation()
                let saved: LocalReminder
                do { saved = try persistence.upsertReminder(reminder) }
                catch { throw ReminderSchedulerError.storageFailed }
                // The action is committed. Later voice interruption must not
                // silently undo a successfully created reminder.
                reloadList()
                return saved
            } catch {
                notifications.removePending(ids: [reminder.notificationIdentifier])
                throw error
            }
        }
    }

    @discardableResult
    func update(id: UUID, title: String, dueAt: Date) async throws -> LocalReminder {
        try await serialized { [self] in
            let schedule = try ReminderScheduleRules.validate(title: title, dueAt: dueAt, now: currentDate())
            let original = try storedReminder(id)
            try await ensurePermission()
            let pending = await notifications.pendingRequests()
            let previousRequest = pending.first { $0.identifier == original.notificationIdentifier }
            if previousRequest == nil, pending.count >= Self.maximumPendingNotifications { throw ReminderSchedulerError.activeLimit }
            try Task.checkCancellation()
            var updated = original
            updated.title = schedule.title
            updated.dueAt = schedule.dueAt
            updated.updatedAt = currentDate()
            updated.status = .scheduled
            let request = try makeRequest(updated)
            do { try await notifications.add(request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ReminderSchedulerError.schedulingFailed }
            do {
                try Task.checkCancellation()
                let saved: LocalReminder
                do { saved = try persistence.upsertReminder(updated) }
                catch { throw ReminderSchedulerError.storageFailed }
                notifications.removeDelivered(ids: [updated.notificationIdentifier])
                reloadList()
                return saved
            } catch {
                do {
                    if let previousRequest { try await notifications.add(previousRequest) }
                    else { notifications.removePending(ids: [updated.notificationIdentifier]) }
                } catch {
                    // We cannot claim that the original notification survived a
                    // failure of both independent persistence systems.
                    notifications.removePending(ids: [updated.notificationIdentifier])
                    var blocked = original
                    blocked.status = .blocked
                    blocked.updatedAt = currentDate()
                    _ = try? persistence.upsertReminder(blocked)
                    reloadList()
                    throw ReminderSchedulerError.restorationFailed
                }
                throw error
            }
        }
    }

    func complete(id: UUID) async throws {
        try await serialized { [self] in
            var reminder = try storedReminder(id)
            try Task.checkCancellation()
            reminder.status = .completed
            reminder.updatedAt = currentDate()
            do { _ = try persistence.upsertReminder(reminder) }
            catch { throw ReminderSchedulerError.storageFailed }
            notifications.removePending(ids: [reminder.notificationIdentifier])
            notifications.removeDelivered(ids: [reminder.notificationIdentifier])
            reloadList()
        }
    }

    func delete(id: UUID) async throws {
        try await serialized { [self] in
            let reminder = try storedReminder(id)
            try Task.checkCancellation()
            do { try persistence.deleteReminder(id: id) }
            catch { throw ReminderSchedulerError.storageFailed }
            notifications.removePending(ids: [reminder.notificationIdentifier])
            notifications.removeDelivered(ids: [reminder.notificationIdentifier])
            reloadList()
        }
    }

    /// Safe on launch/foreground: observes authorization and reconciles status,
    /// but never prompts for permission or silently creates a new reminder.
    func refresh() async throws {
        try await serialized { [self] in
            apply(await notifications.settings())
            let pending = await notifications.pendingRequests()
            var stored: [LocalReminder]
            do { stored = try persistence.reminders(status: nil, limit: 10_000) }
            catch { throw ReminderSchedulerError.storageFailed }
            var storedIDs = Set(stored.map(\.notificationIdentifier))
            // The visible list is bounded. Resolve missing IDs individually so
            // a long archive cannot make a valid alarm look like an orphan.
            for request in pending where request.content.categoryIdentifier == Self.notificationCategoryIdentifier && !storedIDs.contains(request.identifier) {
                guard let id = UUID(uuidString: request.identifier) else { continue }
                do {
                    if let reminder = try persistence.getReminder(id: id) {
                        stored.append(reminder)
                        storedIDs.insert(reminder.notificationIdentifier)
                    }
                } catch { throw ReminderSchedulerError.storageFailed }
            }
            // A process interruption between the OS write and SQLite commit can
            // leave a notification without its record. Do not deliver an action
            // the app cannot show or cancel. Leave other categories untouched.
            let orphanIDs = pending.filter {
                $0.content.categoryIdentifier == Self.notificationCategoryIdentifier && !storedIDs.contains($0.identifier)
            }.map(\.identifier)
            notifications.removePending(ids: orphanIDs)
            let pendingByID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            let now = currentDate()
            for var reminder in stored {
                if reminder.status == .completed {
                    notifications.removePending(ids: [reminder.notificationIdentifier])
                    notifications.removeDelivered(ids: [reminder.notificationIdentifier])
                } else {
                    let request = pendingByID[reminder.notificationIdentifier]
                    // An interrupted edit can leave a replacement at a new
                    // time while SQLite still has the old title/date. Existence
                    // alone must not turn that conflicting alarm into success.
                    let matches = request.map { matchesStoredReminder($0, reminder: reminder) } ?? false
                    if request != nil && !matches {
                        notifications.removePending(ids: [reminder.notificationIdentifier])
                    }
                    // A past row with no pending request may have been delivered;
                    // do not call it blocked or completed without evidence. A
                    // conflicting pending alarm still needs to be stopped.
                    guard reminder.dueAt > now || (request != nil && !matches) else { continue }
                    let expected: LocalReminderStatus = canSendNotifications && matches ? .scheduled : .blocked
                    guard reminder.status != expected else { continue }
                    try Task.checkCancellation()
                    reminder.status = expected
                    reminder.updatedAt = now
                    do { _ = try persistence.upsertReminder(reminder) }
                    catch { throw ReminderSchedulerError.storageFailed }
                }
            }
            reloadList()
        }
    }

    func requestPermission() async throws {
        try await serialized { [self] in
            guard isForeground() else { throw ReminderSchedulerError.permissionRequired }
            apply(await notifications.settings())
            guard authorizationStatus != .denied else { throw ReminderSchedulerError.permissionDenied }
            if authorizationStatus == .notDetermined || authorizationStatus == .provisional {
                do { _ = try await notifications.requestAuthorization() }
                catch is CancellationError { throw CancellationError() }
                catch { throw ReminderSchedulerError.schedulingFailed }
                apply(await notifications.settings())
            }
            guard canSendNotifications else { throw ReminderSchedulerError.permissionDenied }
        }
    }

    func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func ensurePermission() async throws {
        apply(await notifications.settings())
        if authorizationStatus == .notDetermined {
            guard isForeground() else { throw ReminderSchedulerError.permissionRequired }
            do { _ = try await notifications.requestAuthorization() }
            catch is CancellationError { throw CancellationError() }
            catch { throw ReminderSchedulerError.schedulingFailed }
            apply(await notifications.settings())
        }
        guard canSendNotifications else { throw ReminderSchedulerError.permissionDenied }
    }

    private func apply(_ settings: ReminderNotificationSettings) {
        authorizationStatus = settings.authorizationStatus
        alertsEnabled = settings.alertsEnabled
        soundsEnabled = settings.soundsEnabled
    }

    private func makeRequest(_ reminder: LocalReminder) throws -> UNNotificationRequest {
        // Recheck after the permission dialog, which may have taken longer than
        // the remaining time until the requested reminder.
        let schedule = try ReminderScheduleRules.validate(title: reminder.title, dueAt: reminder.dueAt, now: currentDate())
        let content = UNMutableNotificationContent()
        content.title = "Напоминание"
        content.body = schedule.title
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategoryIdentifier
        content.userInfo = [Self.reminderIDUserInfoKey: reminder.id.uuidString]
        let trigger = UNCalendarNotificationTrigger(dateMatching: ReminderScheduleRules.calendarComponents(for: schedule.dueAt), repeats: false)
        guard let next = trigger.nextTriggerDate(), abs(next.timeIntervalSince(schedule.dueAt)) < 1 else {
            throw ReminderScheduleError.invalidDate
        }
        return UNNotificationRequest(identifier: reminder.notificationIdentifier, content: content, trigger: trigger)
    }

    private func matchesStoredReminder(_ request: UNNotificationRequest, reminder: LocalReminder) -> Bool {
        guard request.content.categoryIdentifier == Self.notificationCategoryIdentifier,
              request.content.body == reminder.title,
              request.content.userInfo[Self.reminderIDUserInfoKey] as? String == reminder.id.uuidString,
              let trigger = request.trigger as? UNCalendarNotificationTrigger,
              !trigger.repeats else { return false }
        // Resolve the stored absolute components instead of nextTriggerDate:
        // the alarm can become due between the pending snapshot and this check.
        let components = trigger.dateComponents
        guard components.year != nil, components.month != nil, components.day != nil,
              components.hour != nil, components.minute != nil, components.second != nil,
              let zone = components.timeZone else { return false }
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let scheduled = calendar.date(from: components) else { return false }
        return abs(scheduled.timeIntervalSince(reminder.dueAt)) < 1
    }

    private func storedReminder(_ id: UUID) throws -> LocalReminder {
        do {
            guard let result = try persistence.getReminder(id: id) else { throw ReminderSchedulerError.notFound }
            return result
        } catch let error as ReminderSchedulerError { throw error }
        catch { throw ReminderSchedulerError.storageFailed }
    }

    private func reloadList() {
        do { reminders = try persistence.reminders(status: nil, limit: 10_000) }
        catch { lastError = ReminderSchedulerError.storageFailed.localizedDescription }
    }

    private func serialized<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let preceding = mutationTail
        queuedOperations += 1
        isBusy = true
        lastError = nil
        let work = Task { @MainActor in
            await preceding?.value
            try Task.checkCancellation()
            return try await operation()
        }
        mutationTail = Task { @MainActor in _ = try? await work.value }
        defer {
            queuedOperations -= 1
            isBusy = queuedOperations > 0
        }
        do {
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

protocol ReminderPersisting: AnyObject {
    func upsertReminder(_ reminder: LocalReminder) throws -> LocalReminder
    func getReminder(id: UUID) throws -> LocalReminder?
    func reminders(status: LocalReminderStatus?, limit: Int) throws -> [LocalReminder]
    func deleteReminder(id: UUID) throws
}

extension LocalDataStore: ReminderPersisting {}

struct ReminderNotificationSettings {
    let authorizationStatus: UNAuthorizationStatus
    let alertsEnabled: Bool
    let soundsEnabled: Bool
}

@MainActor
protocol ReminderNotificationClient: AnyObject {
    func settings() async -> ReminderNotificationSettings
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(ids: [String])
    func removeDelivered(ids: [String])
}

@MainActor
private final class SystemReminderNotificationClient: ReminderNotificationClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter) { self.center = center }
    func settings() async -> ReminderNotificationSettings {
        let settings = await center.notificationSettings()
        return ReminderNotificationSettings(authorizationStatus: settings.authorizationStatus,
            alertsEnabled: settings.alertSetting == .enabled, soundsEnabled: settings.soundSetting == .enabled)
    }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}
