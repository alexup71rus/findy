import Combine
import Foundation
import EventKit
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
    case remindersPermissionDenied
    case remindersUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Откройте Findy и разрешите доступ к напоминаниям или уведомлениям."
        case .permissionDenied:
            return "Уведомления Findy выключены. Включите их в настройках iPhone."
        case .remindersPermissionDenied:
            return "Разрешите Findy доступ к напоминаниям в настройках iPhone."
        case .remindersUnavailable:
            return "Не удалось сохранить напоминание в приложении «Напоминания». Проверьте доступ и наличие списка напоминаний."
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

    private var nativeStore: EKEventStore?
    private var nativePersistence: LocalDataStore?
    @Published private(set) var nativeAuthorization: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    var usesNativeReminders: Bool { nativeStore != nil }
    var hasBlockedLegacyReminders: Bool {
        reminders.contains { $0.status == .blocked && $0.dueAt > currentDate() && (try? nativeIdentifier($0.id)) == nil }
    }
    var hasNativeAccess: Bool { nativeAuthorization == .fullAccess }
    @Published var advanceReminderEnabled: Bool = UserDefaults.standard.object(forKey: "reminderAdvanceEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(advanceReminderEnabled, forKey: "reminderAdvanceEnabled") }
    }

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
        self.nativeStore = EKEventStore()
        self.nativePersistence = store
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
    func create(title: String, dueAt: Date, advance: Bool? = nil) async throws -> LocalReminder {
        try await serialized { [self] in
            let schedule = try ReminderScheduleRules.validate(title: title, dueAt: dueAt, now: currentDate())
            if nativeStore != nil { return try await createNative(schedule, advance: advance) }
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
    func update(id: UUID, title: String, dueAt: Date, advance: Bool? = nil) async throws -> LocalReminder {
        try await serialized { [self] in
            let schedule = try ReminderScheduleRules.validate(title: title, dueAt: dueAt, now: currentDate())
            let original = try storedReminder(id)
            if try nativeIdentifier(id) != nil { return try await updateNative(original, schedule: schedule, advance: advance) }
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
            if try nativeIdentifier(id) != nil { try await finishNative(reminder, delete: false); return }
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
            if try nativeIdentifier(id) != nil { try await finishNative(reminder, delete: true); return }
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
            nativeAuthorization = EKEventStore.authorizationStatus(for: .reminder)
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
                if let identifier = try nativeIdentifier(reminder.id) {
                    guard hasNativeAccess, let nativeStore else {
                        if reminder.status != .completed && reminder.status != .blocked {
                            reminder.status = .blocked; reminder.updatedAt = now
                            do { _ = try persistence.upsertReminder(reminder) } catch { throw ReminderSchedulerError.storageFailed }
                        }
                        continue
                    }
                    guard let event = nativeStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
                        do {
                            try persistence.deleteReminder(id: reminder.id)
                            try nativePersistence?.setLocalState(nil, for: "eventkit." + reminder.id.uuidString)
                        } catch { throw ReminderSchedulerError.storageFailed }
                        continue
                    }
                    var changed = false
                    if let title = event.title, !title.isEmpty, title != reminder.title { reminder.title = title; changed = true }
                    if let components = event.dueDateComponents, let date = (components.calendar ?? Calendar.current).date(from: components), date != reminder.dueAt {
                        reminder.dueAt = date; changed = true
                    }
                    let status: LocalReminderStatus = event.isCompleted ? .completed : (event.dueDateComponents == nil ? .blocked : .scheduled)
                    if reminder.status != status { reminder.status = status; changed = true }
                    if changed {
                        reminder.updatedAt = now
                        do { _ = try persistence.upsertReminder(reminder) } catch { throw ReminderSchedulerError.storageFailed }
                    }
                    continue
                }
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
            if nativeStore != nil { try await ensureNativePermission(); return }
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

    func requestLegacyPermission() async throws {
        try await serialized { [self] in
            guard isForeground() else { throw ReminderSchedulerError.permissionRequired }
            try await ensurePermission()
        }
    }

    func openLegacyNotificationSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: usesNativeReminders ? UIApplication.openSettingsURLString : UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    func advanceAlarmEnabled(for reminder: LocalReminder) -> Bool? {
        guard hasNativeAccess, let identifier = try? nativeIdentifier(reminder.id),
              let event = nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder else { return nil }
        return hasAdvanceAlarm(event, dueAt: reminder.dueAt)
    }

    private func hasAdvanceAlarm(_ event: EKReminder, dueAt: Date) -> Bool {
        event.alarms?.contains { alarm in
            guard let date = alarm.absoluteDate else { return false }
            return abs(date.timeIntervalSince(dueAt.addingTimeInterval(-3600))) < 1
        } ?? false
    }

    private func nativeIdentifier(_ id: UUID) throws -> String? {
        guard let nativePersistence else { return nil }
        do { return try nativePersistence.localState(for: "eventkit." + id.uuidString).flatMap { String(data: $0, encoding: .utf8) } }
        catch { throw ReminderSchedulerError.storageFailed }
    }

    private func ensureNativePermission() async throws {
        guard let nativeStore else { throw ReminderSchedulerError.remindersUnavailable }
        nativeAuthorization = EKEventStore.authorizationStatus(for: .reminder)
        if nativeAuthorization == .notDetermined {
            guard isForeground() else { throw ReminderSchedulerError.permissionRequired }
            do { _ = try await nativeStore.requestFullAccessToReminders() }
            catch { throw ReminderSchedulerError.remindersUnavailable }
            nativeAuthorization = EKEventStore.authorizationStatus(for: .reminder)
        }
        guard hasNativeAccess else { throw ReminderSchedulerError.remindersPermissionDenied }
    }

    private func configure(_ event: EKReminder, schedule: ReminderSchedule, advance: Bool, explicit: Bool) {
        event.title = schedule.title
        event.dueDateComponents = ReminderScheduleRules.calendarComponents(for: schedule.dueAt)
        var dates = ReminderScheduleRules.alarmDates(dueAt: schedule.dueAt, now: currentDate(), advanceEnabled: advance)
        if explicit && advance && dates.count == 1 && schedule.dueAt.timeIntervalSince(currentDate()) > 3600 {
            dates.append(schedule.dueAt.addingTimeInterval(-3600))
        }
        event.alarms = dates.map { EKAlarm(absoluteDate: $0) }
    }

    private func createNative(_ schedule: ReminderSchedule, advance: Bool?) async throws -> LocalReminder {
        try await ensureNativePermission()
        guard let eventStore = nativeStore, let db = nativePersistence,
              let calendar = eventStore.defaultCalendarForNewReminders() else { throw ReminderSchedulerError.remindersUnavailable }
        let now = currentDate()
        _ = try ReminderScheduleRules.validate(title: schedule.title, dueAt: schedule.dueAt, now: now)
        let existing = try persistence.reminders(status: nil, limit: 10_000)
        for item in existing where item.status != .completed && item.title == schedule.title && item.dueAt == schedule.dueAt {
            if let identifier = try nativeIdentifier(item.id), let event = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder,
               !event.isCompleted, event.title == schedule.title, let components = event.dueDateComponents,
               let due = (components.calendar ?? Calendar.current).date(from: components), abs(due.timeIntervalSince(schedule.dueAt)) < 1 {
                if advance != nil || item.status == .blocked {
                    return try await updateNative(item, schedule: schedule, advance: advance)
                }
                return item
            }
        }
        try Task.checkCancellation()
        let reminder = LocalReminder(title: schedule.title, dueAt: schedule.dueAt, createdAt: now, updatedAt: now)
        let event = EKReminder(eventStore: eventStore)
        event.calendar = calendar
        configure(event, schedule: schedule, advance: advance ?? advanceReminderEnabled, explicit: advance != nil)
        do { try eventStore.save(event, commit: true) } catch { throw ReminderSchedulerError.remindersUnavailable }
        do {
            try db.setLocalState(Data(event.calendarItemIdentifier.utf8), for: "eventkit." + reminder.id.uuidString)
            let saved = try db.upsertReminder(reminder)
            reloadList()
            return saved
        } catch {
            try? eventStore.remove(event, commit: true)
            try? db.setLocalState(nil, for: "eventkit." + reminder.id.uuidString)
            throw ReminderSchedulerError.storageFailed
        }
    }

    private func nativeEvent(_ id: UUID) async throws -> EKReminder {
        try await ensureNativePermission()
        guard let identifier = try nativeIdentifier(id), let event = nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderSchedulerError.notFound
        }
        return event
    }

    private func updateNative(_ original: LocalReminder, schedule: ReminderSchedule, advance: Bool?) async throws -> LocalReminder {
        let event = try await nativeEvent(original.id)
        _ = try ReminderScheduleRules.validate(title: schedule.title, dueAt: schedule.dueAt, now: currentDate())
        let oldTitle = event.title
        let oldDue = event.dueDateComponents
        let oldAlarms = event.alarms
        let oldCompleted = event.isCompleted
        let hadAdvance = hasAdvanceAlarm(event, dueAt: original.dueAt)
        try Task.checkCancellation()
        configure(event, schedule: schedule, advance: advance ?? hadAdvance, explicit: advance != nil)
        if schedule.dueAt == original.dueAt && (advance == nil || advance == hadAdvance) {
            event.alarms = oldAlarms
        }
        event.isCompleted = false
        do { try nativeStore?.save(event, commit: true) } catch { throw ReminderSchedulerError.remindersUnavailable }
        var updated = original
        updated.title = schedule.title; updated.dueAt = schedule.dueAt; updated.updatedAt = currentDate(); updated.status = .scheduled
        do { let saved = try persistence.upsertReminder(updated); reloadList(); return saved }
        catch {
            event.title = oldTitle; event.dueDateComponents = oldDue; event.alarms = oldAlarms; event.isCompleted = oldCompleted
            do { try nativeStore?.save(event, commit: true) } catch { throw ReminderSchedulerError.restorationFailed }
            throw ReminderSchedulerError.storageFailed
        }
    }

    private func finishNative(_ reminder: LocalReminder, delete: Bool) async throws {
        let event: EKReminder
        do { event = try await nativeEvent(reminder.id) }
        catch ReminderSchedulerError.notFound where delete {
            try persistence.deleteReminder(id: reminder.id)
            try nativePersistence?.setLocalState(nil, for: "eventkit." + reminder.id.uuidString)
            reloadList()
            return
        }
        try Task.checkCancellation()
        if delete {
            do { try nativeStore?.remove(event, commit: true) } catch { throw ReminderSchedulerError.remindersUnavailable }
            do { try persistence.deleteReminder(id: reminder.id); try nativePersistence?.setLocalState(nil, for: "eventkit." + reminder.id.uuidString) }
            catch { throw ReminderSchedulerError.storageFailed }
        } else {
            event.isCompleted = true
            do { try nativeStore?.save(event, commit: true) } catch { throw ReminderSchedulerError.remindersUnavailable }
            var updated = reminder; updated.status = .completed; updated.updatedAt = currentDate()
            do { _ = try persistence.upsertReminder(updated) } catch { throw ReminderSchedulerError.storageFailed }
        }
        reloadList()
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

#if DEBUG && targetEnvironment(simulator)
@MainActor
extension ReminderScheduler {
    static func runNativeSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["FINDY_NATIVE_REMINDER_SMOKE"] == "1" else { return }
        let resultURL = URL.documentsDirectory.appending(path: "native-reminder-smoke.txt")
        let dbURL = URL.temporaryDirectory.appending(path: "native-reminder-smoke-\(UUID().uuidString).sqlite")
        var createdID: UUID?
        var smokeScheduler: ReminderScheduler?
        do {
            let db = try LocalDataStore(databaseURL: dbURL)
            let scheduler = ReminderScheduler(store: db)
            smokeScheduler = scheduler
            let now = Date()
            let due = Calendar.current.startOfDay(for: now).addingTimeInterval(2 * 86400 + 12 * 3600)
            let created = try await scheduler.create(title: "Findy isolated smoke \(UUID().uuidString)", dueAt: due, advance: true)
            createdID = created.id
            guard let key = try db.localState(for: "eventkit." + created.id.uuidString), let identifier = String(data: key, encoding: .utf8),
                  let event = scheduler.nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder,
                  event.alarms?.count == 2, scheduler.advanceAlarmEnabled(for: created) == true else { throw ReminderSchedulerError.remindersUnavailable }
            let duplicateOff = try await scheduler.create(title: created.title, dueAt: due, advance: false)
            guard duplicateOff.id == created.id, scheduler.advanceAlarmEnabled(for: duplicateOff) == false,
                  (scheduler.nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder)?.alarms?.count == 1 else { throw ReminderSchedulerError.remindersUnavailable }
            let duplicateOn = try await scheduler.create(title: created.title, dueAt: due, advance: true)
            guard duplicateOn.id == created.id, scheduler.advanceAlarmEnabled(for: duplicateOn) == true,
                  (scheduler.nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder)?.alarms?.count == 2 else { throw ReminderSchedulerError.remindersUnavailable }
            _ = try await scheduler.update(id: created.id, title: "Findy isolated smoke edited", dueAt: due, advance: true)
            guard let edited = scheduler.nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder,
                  edited.title == "Findy isolated smoke edited", edited.alarms?.count == 2 else { throw ReminderSchedulerError.remindersUnavailable }
            edited.title = "Findy isolated smoke external"
            try scheduler.nativeStore?.save(edited, commit: true)
            try await scheduler.refresh()
            guard scheduler.reminders.first?.title == "Findy isolated smoke external" else { throw ReminderSchedulerError.storageFailed }
            try await scheduler.complete(id: created.id)
            guard let completed = scheduler.nativeStore?.calendarItem(withIdentifier: identifier) as? EKReminder, completed.isCompleted else { throw ReminderSchedulerError.remindersUnavailable }
            try await scheduler.delete(id: created.id)
            createdID = nil
            guard scheduler.nativeStore?.calendarItem(withIdentifier: identifier) == nil, try db.getReminder(id: created.id) == nil else { throw ReminderSchedulerError.storageFailed }
            let deletedExternally = try await scheduler.create(title: "Findy isolated external delete", dueAt: due, advance: false)
            createdID = deletedExternally.id
            guard let externalKey = try db.localState(for: "eventkit." + deletedExternally.id.uuidString),
                  let externalIdentifier = String(data: externalKey, encoding: .utf8),
                  let externalEvent = scheduler.nativeStore?.calendarItem(withIdentifier: externalIdentifier) as? EKReminder else { throw ReminderSchedulerError.remindersUnavailable }
            try scheduler.nativeStore?.remove(externalEvent, commit: true)
            try await scheduler.refresh()
            guard try db.getReminder(id: deletedExternally.id) == nil,
                  try db.localState(for: "eventkit." + deletedExternally.id.uuidString) == nil else { throw ReminderSchedulerError.storageFailed }
            createdID = nil
            try "PASS create, duplicate advance off/on, update, external sync, complete, delete, external deletion sync".write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            if let createdID, let smokeScheduler { try? await smokeScheduler.delete(id: createdID) }
            try? "FAIL \(error) createdID=\(String(describing: createdID))".write(to: resultURL, atomically: true, encoding: .utf8)
        }
    }
}
#endif
