import SwiftUI

@MainActor
struct SystemPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = VoiceSession.shared
    @State private var preset: SystemPromptPreset
    @State private var customPrompt: String
    private let originalCustomPrompt: String
    @State private var saveError = ""
    @State private var showingSaveError = false

    private let onSave: (SystemPromptPreset, String) throws -> Void

    init(provider: AssistantProvider, onSave: @escaping (SystemPromptPreset, String) throws -> Void) {
        _preset = State(initialValue: provider.promptPreset)
        _customPrompt = State(initialValue: provider.customSystemPrompt)
        originalCustomPrompt = provider.customSystemPrompt
        self.onSave = onSave
    }

    private var editingDisabled: Bool { session.isRunning || session.isSendingText || session.phase != .idle }

    private var displayedPrompt: String {
        preset.builtinPrompt ?? customPrompt
    }

    private var canSave: Bool {
        !editingDisabled && (customPrompt.count <= AssistantLimits.systemPromptCharacters || (preset != .custom && customPrompt == originalCustomPrompt))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Вариант промпта", selection: $preset) {
                Text("Полезный").tag(SystemPromptPreset.helpful)
                Text("Циничный").tag(SystemPromptPreset.cynical)
                Text("Мотивирующий").tag(SystemPromptPreset.motivating)
                Text("Пользовательский").tag(SystemPromptPreset.custom)
            }
            .pickerStyle(.menu)
            .disabled(editingDisabled)
            .accessibilityIdentifier("system-prompt-preset")
            TextEditor(text: Binding(
                get: { displayedPrompt },
                set: { value in
                    customPrompt = value
                    preset = .custom
                }
            ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .disabled(editingDisabled)
                .accessibilityLabel("Системный промпт")
                .accessibilityIdentifier("system-prompt-editor")
            CharacterLimitCounter(count: displayedPrompt.count, limit: AssistantLimits.systemPromptCharacters)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("system-prompt-character-count")

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
                    .disabled(!canSave)
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
        guard canSave else { return }
        do {
            try onSave(preset, customPrompt)
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
