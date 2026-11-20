import SwiftUI
import AppKit

// Styl przezroczystego szkła — jak w Sejfie.

struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum Palette {
    static let blue   = [Color(red: 0.35, green: 0.55, blue: 1.00), Color(red: 0.55, green: 0.30, blue: 0.95)]
    static let green  = [Color(red: 0.20, green: 0.85, blue: 0.45), Color(red: 0.05, green: 0.60, blue: 0.35)]
    static let orange = [Color(red: 1.00, green: 0.62, blue: 0.20), Color(red: 0.95, green: 0.35, blue: 0.30)]
}

/// Rozmycie + poświata + świetlista obwódka.
struct GlassBackground: View {
    var tint: Color = Palette.blue[0]
    var radius: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            BlurBackground()
            Color.black.opacity(0.10)
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduce)) { ctx in
                let t = reduce ? 0 : ctx.date.timeIntervalSinceReferenceDate
                GeometryReader { g in
                    ZStack {
                        blob(tint, 0.42, g, x: 0.15 + 0.12 * sin(t * 0.21), y: 0.05 + 0.10 * cos(t * 0.17), r: 620)
                        blob(Palette.blue[1], 0.38, g, x: 0.88 + 0.10 * cos(t * 0.19), y: 0.95 + 0.08 * sin(t * 0.23), r: 580)
                        blob(Color(red: 0.95, green: 0.35, blue: 0.7), 0.16, g, x: 0.55 + 0.25 * sin(t * 0.13 + 1), y: 0.45 + 0.2 * cos(t * 0.11), r: 420)
                    }
                }
            }
            LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if radius > 0 { RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .white.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1) }
        }
        .ignoresSafeArea()
    }
    private func blob(_ c: Color, _ o: Double, _ g: GeometryProxy, x: Double, y: Double, r: CGFloat) -> some View {
        RadialGradient(colors: [c.opacity(o), .clear], center: .center, startRadius: 10, endRadius: r)
            .frame(width: r * 2, height: r * 2)
            .position(x: g.size.width * x, y: g.size.height * y)
    }
}

struct GlyphBadge: View {
    var symbol: String
    var colors: [Color]
    var size: CGFloat = 78
    @State private var glow = false
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: colors[1].opacity(0.55), radius: glow ? 22 : 14, y: 6)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1).frame(width: size, height: size)
            Image(systemName: symbol).font(.system(size: size * 0.41, weight: .semibold)).foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true } }
    }
}

/// Czyni okno przezroczystym (jak panele Sejfu), z zaokrąglonym szklanym tłem.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            for d in [0.3, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { w.invalidateShadow() } }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}


/// Przycisk z efektem wciśnięcia (sprężyste zmniejszenie).
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
