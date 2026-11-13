import SwiftUI
import UIKit

@MainActor
struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = PersonalData.shared
    @State private var query = ""
    @State private var editor: MemoryEditorRequest?
    @State private var deleting: MemoryFact?
    @State private var actionError = ""
    @State private var showingError = false

    private var filtered: [MemoryFact] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? data.memories : data.memories.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(data.memoryCount)/\(AssistantLimits.memorySlots)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(data.memoryCount >= AssistantLimits.memorySlots ? Color.accentColor : Color.secondary)
                        .accessibilityLabel("Записей в памяти")
                        .accessibilityValue("\(data.memoryCount) из \(AssistantLimits.memorySlots)")
                        .accessibilityIdentifier("memory-slot-count")
                }
                if let error = data.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if data.memories.isEmpty {
                    Section {
                        Text("Пока ничего не сохранено").font(.headline)
                        Text("Добавьте то, что помощнику стоит знать о вас. Также можно попросить его: «Запомни…».")
                            .foregroundStyle(.secondary)
                    }
                } else if filtered.isEmpty {
                    Section { Text("Ничего не найдено").foregroundStyle(.secondary) }
                } else {
                    Section {
                        ForEach(filtered) { fact in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(fact.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(fact.updatedAt, format: .dateTime.day().month(.abbreviated).year())
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .accessibilityIdentifier("memory-fact")
                            .contextMenu {
                                Button("Изменить", systemImage: "pencil") { editor = MemoryEditorRequest(fact: fact) }
                                Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.string = fact.text }
                                Button("Удалить", systemImage: "trash", role: .destructive) { deleting = fact }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Удалить", role: .destructive) { deleting = fact }
                                Button("Изменить") { editor = MemoryEditorRequest(fact: fact) }
                                    .tint(.accentColor)
                            }
                            .accessibilityAction(named: "Изменить") { editor = MemoryEditorRequest(fact: fact) }
                        }
                    }
                }
                Section {
                    Text("Ассистент обращается к памяти по необходимости. При заполнении новые записи заменяют самые давно обновлённые.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Память")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Поиск в памяти")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = MemoryEditorRequest(fact: nil)
                    } label: {
                        Label("Добавить факт", systemImage: "plus")
                    }
                    .accessibilityIdentifier("memory-add")
                    .disabled(data.store == nil)
                }
            }
            .sheet(item: $editor) { MemoryEditorView(fact: $0.fact) }
            .confirmationDialog("Удалить факт из памяти?", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    guard let fact = deleting else { return }
                    do { try data.deleteMemory(id: fact.id) }
                    catch { actionError = error.localizedDescription; showingError = true }
                    deleting = nil
                }
            }
            .alert("Не удалось изменить память", isPresented: $showingError) {
                Button("Понятно", role: .cancel) {}
            } message: { Text(actionError) }
            .task { await data.refresh() }
            .refreshable { await data.refresh() }
        }
    }
}

private struct MemoryEditorRequest: Identifiable {
    let id = UUID()
    let fact: MemoryFact?
}

@MainActor
private struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var data = PersonalData.shared
    let fact: MemoryFact?
    @State private var text: String
    @State private var error = ""
    @State private var showingError = false
    @FocusState private var isFocused: Bool

    init(fact: MemoryFact?) {
        self.fact = fact
        _text = State(initialValue: fact?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(height: 180)
                        .focused($isFocused)
                        .accessibilityLabel("Что запомнить")
                        .accessibilityIdentifier("memory-editor")
                } header: { Text("Что запомнить") } footer: {
                    CharacterLimitCounter(count: text.count, limit: AssistantLimits.memoryNoteCharacters)
                        .accessibilityIdentifier("memory-character-count")
                }
            }
            .navigationTitle(fact == nil ? "Новый факт" : "Изменить факт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .accessibilityIdentifier("memory-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do {
                            try data.saveMemory(text: text, replacing: fact?.id)
                            dismiss()
                        } catch { self.error = error.localizedDescription; showingError = true }
                    }
                    .accessibilityIdentifier("memory-save")
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > AssistantLimits.memoryNoteCharacters)
                }
            }
            .alert("Не удалось сохранить", isPresented: $showingError) {
                Button("Понятно", role: .cancel) {}
            } message: { Text(error) }
            .onAppear { isFocused = true }
        }
    }
}
