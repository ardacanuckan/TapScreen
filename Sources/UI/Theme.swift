import SwiftUI

enum Theme {
    /// The Mac's own accent colour (System Settings → Appearance), so TapScreen looks like part of macOS.
    static let accent = Color.accentColor
    static let surface = Color.primary.opacity(0.035)
    static let hairline = Color.primary.opacity(0.08)
    /// Distinct colours for telling picking tiles and zones apart on screen.
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .mint, .indigo, .cyan, .brown]

    static func roleName(_ role: String) -> String {
        switch role {
        case "AXButton": "Button"
        case "AXLink": "Link"
        case "AXTextField", "AXTextArea", "AXComboBox": "Text field"
        case "AXCheckBox": "Checkbox"
        case "AXRadioButton", "AXTab": "Tab"
        case "AXPopUpButton", "AXMenuButton": "Menu"
        case "AXMenuBarItem": "Menu bar"
        case "AXDockItem": "Dock"
        default: "Item"
        }
    }

    static func percent(_ x: Float) -> String { x.isNaN ? "—" : "\(Int((x * 100).rounded()))%" }
}

/// Grid of cells coloured by probability: the model's belief about where the last tap landed.
struct PosteriorMap: View {
    let grid: Grid
    let posterior: [Float]?
    var labels = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(grid.cols), h = geo.size.height / CGFloat(grid.rows)
            ZStack(alignment: .topLeading) {
                ForEach(0..<grid.count, id: \.self) { i in
                    let p = CGFloat(posterior.map { $0.indices.contains(i) ? $0[i] : 0 } ?? 0)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.accent.opacity(0.05 + 0.6 * p))
                        .overlay {
                            if labels && p > 0.05 {
                                Text("\(Int(p * 100))").font(.system(size: 10, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(p > 0.5 ? Color.white : Color.primary.opacity(0.7))
                            }
                        }
                        .frame(width: w - 3, height: h - 3)
                        .offset(x: CGFloat(i % grid.cols) * w, y: CGFloat(i / grid.cols) * h)
                }
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
        .animation(.easeOut(duration: 0.25), value: posterior ?? [])
    }
}

/// Live twist magnitude with the trigger line and tap markers.
struct ScopeView: View {
    let detector: TapDetector

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let s = detector.scope()
            Canvas { ctx, size in
                let maxV = max(s.threshold * 3, s.mag.max() ?? 1, 1)
                func y(_ v: Float) -> CGFloat { size.height - CGFloat(min(v, maxV) / maxV) * (size.height - 6) - 3 }
                var path = Path()
                for (i, v) in s.mag.enumerated() {
                    let p = CGPoint(x: CGFloat(i) / CGFloat(max(s.mag.count - 1, 1)) * size.width, y: y(v))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let ty = y(s.threshold)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: ty)); $0.addLine(to: CGPoint(x: size.width, y: ty)) },
                           with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
                for t in s.taps {
                    let x = size.width * CGFloat(1 - t / 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 2, width: 8, height: 8)), with: .color(.green))
                }
                ctx.draw(Text(String(format: "trigger %.2f °/s · noise %.2f", s.threshold, s.noise))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: 6, y: 6), anchor: .topLeading)
            }
        }
    }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if color != .secondary { Circle().fill(color).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.surface, in: Capsule())
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }
}
