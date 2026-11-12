import SwiftUI

/// The three flowing ribbons of the app icon, redrawn as a transparent vector.
/// The caller owns the color, so the same mark works as a quiet watermark.
struct FindyMark: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        for ribbon in 0..<3 {
            result.addPath(FindyRibbon.path(ribbon, in: rect))
        }
        return result
    }
}

/// Decorative phase motion stays inside the composer. It never opens audio or
/// publishes frame updates into the conversation's view hierarchy.
struct VoiceComposerWave: View {
    let phase: VoiceSession.Phase
    var isPresented = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = false

    private var animates: Bool {
        visible && isPresented && scenePhase == .active && !reduceMotion && phase != .idle && phase != .stopping
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            let time = animates ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                draw(in: &context, size: size, time: time)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let dark = colorScheme == .dark
        let speed: Double
        let amplitude: Double
        switch phase {
        case .listening: speed = 1.8; amplitude = 9
        case .speaking: speed = 2.7; amplitude = 12
        case .thinking: speed = 1.15; amplitude = 6
        case .starting: speed = 1.4; amplitude = 7
        case .idle, .stopping: speed = 0; amplitude = 3
        }
        let coral = Color(red: 0.97, green: dark ? 0.51 : 0.40, blue: 0.37)
        let amber = Color(red: 1, green: dark ? 0.72 : 0.62, blue: 0.34)
        let pink = Color(red: 0.92, green: 0.43, blue: 0.61)
        let clock = time * speed
        for strand in 0..<4 {
            let layer = Double(strand)
            var path = Path()
            // A narrow taper leaves breathing room next to the text and button.
            for step in 0...100 {
                let x = Double(step) / 100
                let envelope = pow(sin(.pi * x), 0.8)
                let carrier = sin(x * .pi * (2.5 + layer * 0.18) - clock + layer * 0.75)
                let ripple = sin(x * .pi * 5.2 + clock * 0.68 + layer) * 0.23
                let breath = 0.8 + 0.2 * sin(clock * 0.65 + layer * 0.5)
                let y = size.height / 2 + envelope * amplitude * breath * (carrier + ripple) * (1 - layer * 0.12)
                let point = CGPoint(x: x * size.width, y: y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: amber.opacity(0), location: 0),
                    .init(color: amber.opacity(0.75), location: 0.15),
                    .init(color: coral, location: 0.45),
                    .init(color: pink.opacity(0.8), location: 0.78),
                    .init(color: pink.opacity(0), location: 1)
                ]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
                style: StrokeStyle(lineWidth: strand == 0 ? 1.8 : 1.15, lineCap: .round, lineJoin: .round))
        }
    }
}

private enum FindyRibbon {
    typealias Warp = (Double, Double) -> CGPoint

    static func path(_ ribbon: Int, in rect: CGRect, warp: Warp = { CGPoint(x: $0, y: $1) }) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            let p = warp(x, y)
            return CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
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

#Preview("Conversation artwork") {
    VStack(spacing: 24) {
        FindyMark().foregroundStyle(.tertiary).frame(width: 112, height: 54)
        VoiceComposerWave(phase: .listening).frame(width: 210, height: 34)
        VoiceComposerWave(phase: .thinking).frame(width: 210, height: 34)
        VoiceComposerWave(phase: .speaking).frame(width: 210, height: 34)
    }
    .padding()
}

// Native Liquid Glass on current iOS, with a material fallback for iOS 18–25.
extension View {
    @ViewBuilder
    func findyComposerGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.07), lineWidth: 1).allowsHitTesting(false) }
        }
    }
}
