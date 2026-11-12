import SwiftUI
import UserNotifications

@MainActor
struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = PersonalData.shared

    var body: some View {
        NavigationStack {
            Group {
                if let scheduler = data.reminders {
                    ReminderListView(scheduler: scheduler)
                } else {
                    List { Text(data.lastError ?? "Не удалось открыть напоминания.").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Напоминания")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

@MainActor
private struct ReminderListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var scheduler: ReminderScheduler
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var editor: ReminderEditorRequest?
    @State private var deleting: LocalReminder?
    @State private var error = ""
    @State private var showingError = false
    @State private var completedExpanded = false
    @State private var hasRefreshed = false

    private var upcoming: [LocalReminder] { scheduler.reminders.filter { $0.status != .completed && $0.dueAt > Date() } }
    private var earlier: [LocalReminder] { scheduler.reminders.filter { $0.status != .completed && $0.dueAt <= Date() } }
    private var completed: [LocalReminder] { scheduler.reminders.filter { $0.status == .completed } }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if hasRefreshed && (!scheduler.canSendNotifications || !scheduler.alertsEnabled) { permissionSection }
                if let lastError = scheduler.lastError {
                    Section { Text(lastError).foregroundStyle(.red) }
                }
                if scheduler.reminders.isEmpty {
                    Section {
                        if scheduler.isBusy { ProgressView() }
                        else {
                            Text("Напоминаний пока нет").font(.headline)
                            Text("Добавьте напоминание или попросите Findy напомнить вам о чём-нибудь.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if !upcoming.isEmpty {
                        Section("Предстоящие") { ForEach(upcoming) { reminderRow($0) } }
                    }
                    if !earlier.isEmpty {
                        Section("Ранее") { ForEach(earlier) { reminderRow($0) } }
                    }
                    if !completed.isEmpty {
                        Section {
                            DisclosureGroup("Завершённые · \(completed.count)", isExpanded: $completedExpanded) {
                                ForEach(completed) { reminderRow($0) }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = ReminderEditorRequest(reminder: nil) } label: {
                        Label("Добавить напоминание", systemImage: "plus")
                    }
                    .disabled(scheduler.isBusy)
                }
            }
            .sheet(item: $editor) { ReminderEditorView(scheduler: scheduler, reminder: $0.reminder) }
            .confirmationDialog("Удалить напоминание?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    guard let reminder = deleting else { return }
                    run { try await scheduler.delete(id: reminder.id) }
                    deleting = nil
                }
            }
            .alert("Не удалось выполнить действие", isPresented: $showingError) {
                Button("Понятно", role: .cancel) {}
            } message: { Text(error) }
            .task {
                await refresh()
                await revealNotification(using: proxy)
            }
            .refreshable { await refresh() }
            .onChange(of: navigation.selectedReminderID) { _, _ in
                Task { await revealNotification(using: proxy) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
        }
    }

    private var permissionSection: some View {
        Section {
            Label(scheduler.canSendNotifications ? "Баннеры Findy выключены" : "Уведомления не разрешены", systemImage: "bell.slash")
                .font(.subheadline.weight(.medium))
            if scheduler.authorizationStatus == .notDetermined {
                Button("Разрешить уведомления") {
                    run {
                        try await scheduler.requestPermission()
                        try await scheduler.refresh()
                    }
                }
            } else {
                Button("Открыть настройки уведомлений") { scheduler.openSettings() }
            }
        } footer: {
            if scheduler.reminders.contains(where: { $0.status == .blocked && $0.dueAt > Date() }) {
                Text("После разрешения уведомлений выберите «Запланировать» в меню напоминания с отметкой «Не запланировано».")
            }
        }
        .disabled(scheduler.isBusy)
    }

    private func reminderRow(_ reminder: LocalReminder) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                run { try await scheduler.complete(id: reminder.id) }
            } label: {
                Image(systemName: reminder.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.status == .completed ? Color.secondary : Color.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(scheduler.isBusy || reminder.status == .completed)
            .accessibilityLabel(reminder.status == .completed ? "Завершено" : "Завершить: \(reminder.title)")

            VStack(alignment: .leading, spacing: 5) {
                Text(reminder.title)
                    .foregroundStyle(reminder.status == .completed ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reminder.dueAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if reminder.status == .blocked {
                    Label("Не запланировано", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if reminder.status != .completed && reminder.dueAt <= Date() {
                    Text("Время прошло").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Изменить", systemImage: "pencil") { editor = ReminderEditorRequest(reminder: reminder) }
                if reminder.status == .blocked && reminder.dueAt > Date() {
                    Button("Запланировать", systemImage: "bell.badge") {
                        run { _ = try await scheduler.update(id: reminder.id, title: reminder.title, dueAt: reminder.dueAt) }
                    }
                }
                if reminder.status != .completed {
                    Button("Завершить", systemImage: "checkmark") { run { try await scheduler.complete(id: reminder.id) } }
                }
                Button("Удалить", systemImage: "trash", role: .destructive) { deleting = reminder }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(scheduler.isBusy)
            .accessibilityLabel("Действия: \(reminder.title)")
        }
        .padding(.vertical, 5)
        .id(reminder.id)
        .listRowBackground(navigation.selectedReminderID == reminder.id ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
        .swipeActions(edge: .trailing) {
            Button("Удалить", role: .destructive) { deleting = reminder }
                .disabled(scheduler.isBusy)
        }
    }

    private func refresh() async {
        do { try await scheduler.refresh() }
        catch { self.error = error.localizedDescription; showingError = true }
        hasRefreshed = true
    }

    private func revealNotification(using proxy: ScrollViewProxy) async {
        guard let id = navigation.selectedReminderID else { return }
        guard let reminder = scheduler.reminders.first(where: { $0.id == id }) else {
            error = "Напоминание больше не найдено."
            showingError = true
            return
        }
        if reminder.status == .completed { completedExpanded = true }
        await Task.yield()
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch { self.error = error.localizedDescription; showingError = true }
        }
    }
}

private struct ReminderEditorRequest: Identifiable {
    let id = UUID()
    let reminder: LocalReminder?
}

@MainActor
private struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var scheduler: ReminderScheduler
    let reminder: LocalReminder?
    @State private var title: String
    @State private var dueAt: Date
    @State private var isSaving = false
    @State private var error = ""
    @State private var showingError = false
    private let earliest = Date()

    init(scheduler: ReminderScheduler, reminder: LocalReminder?) {
        self.scheduler = scheduler
        self.reminder = reminder
        _title = State(initialValue: reminder?.title ?? "")
        _dueAt = State(initialValue: reminder?.dueAt ?? Date().addingTimeInterval(3_600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("О чём напомнить?", text: $title, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                    DatePicker("Когда", selection: $dueAt, in: earliest..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    if reminder?.status == .completed || (reminder?.dueAt ?? .distantFuture) <= Date() {
                        Text("При сохранении напоминание будет запланировано заново на выбранное время.")
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(reminder == nil ? "Новое напоминание" : "Изменить напоминание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving { ProgressView() } else { Text("Сохранить").fontWeight(.semibold) }
                    }
                    .disabled(isSaving || scheduler.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueAt <= Date())
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert("Не удалось сохранить", isPresented: $showingError) {
                Button("Понятно", role: .cancel) {}
            } message: { Text(error) }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                if let reminder { _ = try await scheduler.update(id: reminder.id, title: title, dueAt: dueAt) }
                else { _ = try await scheduler.create(title: title, dueAt: dueAt) }
                dismiss()
            } catch { self.error = error.localizedDescription; showingError = true }
            isSaving = false
        }
    }
}
