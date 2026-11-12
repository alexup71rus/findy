import SwiftUI

@MainActor
struct SystemPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = VoiceSession.shared
    @State private var draft: String
    @State private var saveError = ""
    @State private var showingSaveError = false

    private let providerName: String
    private let onSave: (String) throws -> Void

    init(prompt: String, providerName: String, onSave: @escaping (String) throws -> Void) {
        _draft = State(initialValue: prompt)
        self.providerName = providerName
        self.onSave = onSave
    }

    private var editingDisabled: Bool { session.isRunning || session.isSendingText || session.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !providerName.isEmpty {
                Text(providerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .disabled(editingDisabled)
                .accessibilityLabel("Системный промпт")
                .accessibilityIdentifier("system-prompt-editor")
            CharacterLimitCounter(count: draft.count, limit: AssistantLimits.systemPromptCharacters)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("system-prompt-character-count")
            Button {
                guard !editingDisabled else { return }
                draft = AssistantConfiguration.defaultSystemPrompt
            } label: {
                Text("Восстановить по умолчанию")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(editingDisabled || draft == AssistantConfiguration.defaultSystemPrompt)
            .accessibilityIdentifier("system-prompt-restore-default")
        }
        .padding(16)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Промпт")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("system-prompt-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
                    .fontWeight(.semibold)
                    .disabled(editingDisabled || draft.count > AssistantLimits.systemPromptCharacters)
                    .accessibilityIdentifier("system-prompt-save")
            }
        }
        .alert("Не удалось сохранить", isPresented: $showingSaveError) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(saveError)
        }
    }

    private func save() {
        guard !editingDisabled, draft.count <= AssistantLimits.systemPromptCharacters else { return }
        do {
            try onSave(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            showingSaveError = true
        }
    }
}

/// Shared, quiet counters leave native text entry and selection intact.
struct CharacterLimitCounter: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count)/\(limit)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : count == limit ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Символов")
            .accessibilityValue("\(count) из \(limit)")
    }
}
