import SwiftUI

struct SiriHelpView: View {
    var body: some View {
        List {
            Section {
                Label("Разговор без разблокировки", systemImage: "airpods")
                    .font(.headline)
                Text("Скажите Siri «Давай поболтаем» и дождитесь короткого сигнала Findy. После него можно говорить.")
            }

            Section("Настроить один раз") {
                Text("Сначала отправьте сообщение в Findy и разрешите передачу данных выбранному провайдеру. Доступ к микрофону тоже нужно разрешить в приложении.")
                    .font(.subheadline).foregroundStyle(.secondary)
                instruction("1", title: "Добавьте готовую команду", detail: "Нажмите кнопку ниже. Откроются «Команды» с готовой командой «Давай поболтаем» — подтвердите её добавление. Действие Findy уже настроено.")
                AddChatShortcutButton(accessibilityIdentifier: "siri-help-shortcuts-link")
                instruction("2", title: "Разрешите Siri при блокировке", detail: "Включите доступ к Siri на заблокированном iPhone в системных настройках.")
                instruction("3", title: "Назначьте Siri на AirPods", detail: "Выберите вызов Siri при удержании ножки в настройках наушников.")
            }

            Section("Начать разговор") {
                Text("Заблокируйте iPhone, удерживайте ножку AirPods и произнесите «Давай поболтаем». Дождитесь сигнала готовности Findy.")
                Text("После ответа можно задать следующий вопрос. Другой короткий сигнал обозначает завершение разговора. Время завершения после тишины выбирается в настройках Findy.")
            }

            Section {
                Text("Также доступна фраза «Чат в Findy» — она появляется автоматически после установки приложения.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Siri и AirPods")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Opens the user's iPhone-shared shortcut using Apple's standard iCloud link.
/// Shortcuts owns the Add Shortcut confirmation and subsequent permissions.
struct AddChatShortcutButton: View {
    let accessibilityIdentifier: String
    private static let shortcutURL = URL(string: "https://www.icloud.com/shortcuts/2c024a556dd846bbafc893b7b42778a9")!

    var body: some View {
        Link(destination: Self.shortcutURL) {
            Label("Добавить «Давай поболтаем»", systemImage: "plus.square.on.square")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
