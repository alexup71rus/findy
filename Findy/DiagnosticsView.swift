import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var log = SessionLog.shared
    @ObservedObject private var session = VoiceSession.shared

    var body: some View {
        List {
            if !session.routeSummary.isEmpty {
                Section("Аудиомаршрут") {
                    Text(session.routeSummary)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            Section {
                ShareLink(item: log.fileURL) {
                    Label("Экспортировать журнал", systemImage: "square.and.arrow.up")
                }
                .disabled(!log.isExportSafe)
                if let error = log.writeError {
                    Text("Ошибка записи: \(error)").foregroundStyle(.red)
                }
            }
            Section("Последние события") {
                Text(log.lines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
    }
}
