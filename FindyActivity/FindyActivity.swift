import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FindyActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            FindyActivityLockScreen(status: context.state.status)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FindyActivityHeading()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(FindyActivityStatus.full(context.state.status))
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                FindyActivityMark()
                    .fill(FindyActivityPalette.islandAccent)
                    .frame(width: 25, height: 13)
                    .accessibilityHidden(true)
            } compactTrailing: {
                Text(FindyActivityStatus.compact(context.state.status))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityLabel(FindyActivityStatus.full(context.state.status))
            } minimal: {
                FindyActivityMark()
                    .fill(FindyActivityPalette.islandAccent)
                    .frame(width: 24, height: 13)
                    .accessibilityLabel("Findy. \(FindyActivityStatus.full(context.state.status))")
            }
            .keylineTint(FindyActivityPalette.islandAccent)
        }
    }
}

private struct FindyActivityLockScreen: View {
    let status: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FindyActivityMark()
                .fill(FindyActivityPalette.accent(for: colorScheme))
                .frame(width: 36, height: 18)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Findy")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                Text(FindyActivityStatus.full(status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct FindyActivityHeading: View {
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            FindyActivityMark()
                .fill(FindyActivityPalette.islandAccent)
                .frame(width: 30, height: 15)
                .accessibilityHidden(true)
            Text("Findy")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

private enum FindyActivityPalette {
    // Match the app's AccentColor asset. The Island always has a dark surface.
    static let islandAccent = Color(red: 1, green: 0.596, blue: 0.525)

    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? islandAccent : Color(red: 0.749, green: 0.290, blue: 0.243)
    }
}

private enum FindyActivityStatus {
    static func full(_ status: String) -> String {
        switch status {
        case "Запускаю микрофон…", "Готовлю микрофон…": "Готовлюсь…"
        case "Подключаю голос OpenAI…": "Подключаюсь…"
        default: status
        }
    }

    static func compact(_ status: String) -> String {
        switch status {
        case "Слушаю": "Слушаю"
        case "Думаю…": "Думаю"
        case "Отвечаю": "Ответ"
        case "Выполняю просьбу…": "В работе"
        case "Запускаю микрофон…", "Готовлю микрофон…", "Подключаю голос OpenAI…": "Старт"
        default: "Чат"
        }
    }
}

// The app's FindyMark/FindyRibbon geometry, kept local to the widget so its
// extension doesn't depend on the app's composer or VoiceSession types.
private struct FindyActivityMark: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        for ribbon in 0..<3 {
            result.addPath(ribbonPath(ribbon, in: rect))
        }
        return result
    }

    private func ribbonPath(_ ribbon: Int, in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.02, 0.61))
        func curve(_ x: Double, _ y: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            path.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
        }
        switch ribbon {
        case 0:
            curve(0.24, 0.45, 0.10, 0.43, 0.18, 0.47)
            curve(0.55, 0.03, 0.40, 0.43, 0.42, 0.02)
            curve(0.85, 0.46, 0.69, 0.02, 0.70, 0.45)
            curve(0.99, 0.49, 0.92, 0.47, 0.94, 0.42)
            curve(0.84, 0.52, 0.92, 0.45, 0.90, 0.52)
            curve(0.55, 0.20, 0.71, 0.54, 0.67, 0.18)
            curve(0.24, 0.54, 0.42, 0.19, 0.37, 0.57)
            curve(0.02, 0.61, 0.14, 0.50, 0.12, 0.48)
        case 1:
            curve(0.25, 0.61, 0.11, 0.48, 0.16, 0.59)
            curve(0.55, 0.28, 0.38, 0.65, 0.42, 0.29)
            curve(0.86, 0.60, 0.69, 0.25, 0.72, 0.62)
            curve(0.99, 0.49, 0.92, 0.60, 0.94, 0.52)
            curve(0.84, 0.66, 0.91, 0.51, 0.92, 0.64)
            curve(0.56, 0.45, 0.70, 0.70, 0.65, 0.44)
            curve(0.24, 0.75, 0.44, 0.46, 0.39, 0.83)
            curve(0.02, 0.61, 0.13, 0.69, 0.12, 0.57)
        default:
            curve(0.31, 0.80, 0.15, 0.58, 0.18, 0.76)
            curve(0.62, 0.55, 0.47, 0.86, 0.49, 0.56)
            curve(0.87, 0.65, 0.72, 0.53, 0.76, 0.73)
            curve(0.99, 0.49, 0.92, 0.62, 0.94, 0.54)
            curve(0.80, 0.77, 0.91, 0.55, 0.89, 0.76)
            curve(0.61, 0.70, 0.70, 0.80, 0.68, 0.69)
            curve(0.33, 0.96, 0.50, 0.73, 0.46, 1.00)
            curve(0.02, 0.61, 0.18, 0.92, 0.19, 0.66)
        }
        path.closeSubpath()
        return path
    }
}
