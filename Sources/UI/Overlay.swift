import AppKit
import SwiftUI

enum RippleColor { case accent, green, miss }

/// Transient effects drawn on the overlay.
@MainActor
final class OverlayFX: ObservableObject {
    struct Ripple: Identifiable { let id = UUID(); let point: CGPoint; let color: RippleColor }
    struct Flash: Identifiable { let id = UUID(); let cell: Int; let title: String }
    @Published var ripples: [Ripple] = []
    @Published var flash: Flash?
}

/// One borderless, click-through window over the built-in display. Hidden whenever there is nothing to draw,
/// so it costs nothing while idle.
@MainActor
final class OverlayController {
    private unowned let engine: Engine
    let fx = OverlayFX()
    private var panel: NSPanel?

    init(engine: Engine) { self.engine = engine }

    private var needed: Bool {
        if engine.calibration != nil || !fx.ripples.isEmpty || fx.flash != nil { return true }
        if case .idle = engine.interaction { return false }
        return true
    }

    func update() {
        guard needed else { panel?.orderOut(nil); return }
        let panel = self.panel ?? make()
        if let screen = Display.screen, panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        // Calibration takes the keyboard (esc, delete, space); everything else stays click-through.
        let calibrating = engine.calibration != nil
        panel.ignoresMouseEvents = !calibrating
        if calibrating { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }

    func ripple(at cg: CGPoint, color: RippleColor) {
        let b = Display.bounds
        let r = OverlayFX.Ripple(point: CGPoint(x: cg.x - b.minX, y: cg.y - b.minY), color: color)
        fx.ripples.append(r)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.fx.ripples.removeAll { $0.id == r.id }
            self?.update()
        }
    }

    func zoneFlash(_ cell: Int, title: String) {
        let f = OverlayFX.Flash(cell: cell, title: title)
        fx.flash = f
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.fx.flash?.id == f.id { self?.fx.flash = nil }
            self?.update()
        }
    }

    private func make() -> NSPanel {
        let frame = Display.screen?.frame ?? .zero
        let p = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: OverlayView(engine: engine, fx: fx))
        panel = p
        return p
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Views

struct OverlayView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var fx: OverlayFX

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let cal = engine.calibration {
                    CalibrationOverlay(cal: cal, size: geo.size, lastEvent: engine.lastEvent)
                }
                switch engine.interaction {
                case .picking(let tiles, _, _):
                    PickerOverlay(tiles: tiles, grid: engine.settings.grid, size: geo.size)
                case .zooming(let region, let level, _):
                    ZoomOverlay(region: region, level: level, levels: engine.settings.zoomLevels, grid: engine.settings.grid, size: geo.size)
                case .idle:
                    EmptyView()
                }
                if let f = fx.flash {
                    ZoneFlashView(rect: scaled(engine.settings.grid.rect(f.cell), geo.size), title: f.title)
                        .id(f.id)
                }
                ForEach(fx.ripples) { RippleView(ripple: $0) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

func scaled(_ r: CGRect, _ size: CGSize) -> CGRect {
    CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
}

struct RippleView: View {
    let ripple: OverlayFX.Ripple
    @State private var go = false

    var body: some View {
        let color: Color = switch ripple.color {
        case .green: .green
        case .miss: .orange
        case .accent: Theme.accent
        }
        ZStack {
            Circle().stroke(color, lineWidth: 3).frame(width: 90, height: 90).scaleEffect(go ? 1 : 0.15).opacity(go ? 0 : 0.95)
            Circle().fill(color.opacity(0.35)).frame(width: 34, height: 34).scaleEffect(go ? 1.4 : 0.6).opacity(go ? 0 : 1)
        }
        .position(ripple.point)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { go = true } }
        .allowsHitTesting(false)
    }
}

struct ZoneFlashView: View {
    let rect: CGRect
    let title: String
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Theme.accent.opacity(shown ? 0.0 : 0.22))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Theme.accent.opacity(shown ? 0 : 0.8), lineWidth: 3))
            .overlay(Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10).background(.black.opacity(0.55), in: Capsule())
                .opacity(shown ? 0 : 1))
            .frame(width: rect.width - 16, height: rect.height - 16)
            .position(x: rect.midX, y: rect.midY)
            .onAppear { withAnimation(.easeOut(duration: 0.65)) { shown = true } }
    }
}

/// Ambiguous smart tap: each candidate gets a big tile in a physical cell. Tap anywhere in the tile to choose it.
struct PickerOverlay: View {
    let tiles: [PickTile]
    let grid: Grid
    let size: CGSize

    var body: some View {
        let b = Display.bounds
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.28)
            ForEach(Array(tiles.enumerated()), id: \.element.id) { i, pick in
                let t = pick.target
                let color = Theme.palette[i % Theme.palette.count]
                let tile = scaled(pick.rect(grid), size).insetBy(dx: 14, dy: 14)
                let target = CGRect(x: t.frame.minX - b.minX, y: t.frame.minY - b.minY, width: t.frame.width, height: t.frame.height)
                Path { p in
                    p.move(to: CGPoint(x: tile.midX, y: tile.midY))
                    p.addLine(to: CGPoint(x: target.midX, y: target.midY))
                }
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                RoundedRectangle(cornerRadius: 26)
                    .fill(color.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(color.opacity(0.85), lineWidth: 2.5))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: t.symbol).font(.system(size: 30, weight: .semibold))
                            Text(t.title.isEmpty ? Theme.roleName(t.role) : t.title)
                                .font(.system(size: 20, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white).padding(14)
                        .background(color.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                    )
                    .frame(width: tile.width, height: tile.height)
                    .position(x: tile.midX, y: tile.midY)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18)))
                    .frame(width: target.width + 8, height: target.height + 8)
                    .position(x: target.midX, y: target.midY)
            }
            Hint(text: "Which one? Tap anywhere in its coloured corner · tap the middle or press any key to cancel")
                .position(x: size.width / 2, y: size.height - 40)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// Zoom refinement: the chosen region is split like the screen; tapping a physical cell picks the same sub-cell.
struct ZoomOverlay: View {
    let region: CGRect
    let level: Int
    let levels: Int
    let grid: Grid
    let size: CGSize

    var body: some View {
        let r = scaled(region, size)
        ZStack(alignment: .topLeading) {
            // Dim outside the region.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRoundedRect(in: r, cornerSize: CGSize(width: 10, height: 10))
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            ForEach(0..<grid.count, id: \.self) { i in
                let color = Theme.palette[i % Theme.palette.count]
                // Physical cell: a faint numbered tile where the finger goes.
                let tile = scaled(grid.rect(i), size).insetBy(dx: 10, dy: 10)
                RoundedRectangle(cornerRadius: 24).stroke(color.opacity(0.35), lineWidth: 2)
                    .frame(width: tile.width, height: tile.height).position(x: tile.midX, y: tile.midY)
                // Its big number, unless the zoomed region covers that corner.
                if !r.contains(CGPoint(x: tile.minX + 40, y: tile.minY + 40)) {
                    Text("\(i + 1)").font(.system(size: 44, weight: .bold)).foregroundStyle(color.opacity(0.35))
                        .position(x: tile.minX + 40, y: tile.minY + 40)
                }
                // Matching sub-cell inside the region.
                let sub = scaled(grid.rect(i, in: region), size)
                Rectangle().fill(color.opacity(0.14)).overlay(Rectangle().stroke(color, lineWidth: 1.5))
                    .overlay(Text("\(i + 1)").font(.system(size: min(28, sub.height * 0.4), weight: .bold))
                        .foregroundStyle(.white).shadow(radius: 2))
                    .frame(width: sub.width, height: sub.height).position(x: sub.midX, y: sub.midY)
            }
            Hint(text: "Zoom \(level)/\(levels) · tap the screen area with the number your target is in")
                .position(x: size.width / 2, y: size.height - 40)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

struct Hint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.black.opacity(0.65), in: Capsule())
    }
}

/// Full-screen calibration: a target dot in the highlighted cell, progress, and a tap-quality meter.
struct CalibrationOverlay: View {
    let cal: Calibration
    let size: CGSize
    let lastEvent: TapEvent?
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.82))
            ForEach(0..<cal.grid.count, id: \.self) { i in
                let r = scaled(cal.grid.rect(i), size).insetBy(dx: 6, dy: 6)
                let active = cal.cell == i && cal.phase == .taps
                RoundedRectangle(cornerRadius: 22)
                    .fill(active ? Theme.accent.opacity(0.13) : Color.white.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(active ? Theme.accent : .white.opacity(0.12), lineWidth: active ? 2 : 1))
                    .overlay(alignment: .topLeading) {
                        Text("\(i + 1) · \(cal.counts[i])/\(cal.perCell)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(cal.counts[i] >= cal.perCell ? 0.35 : 0.7)).padding(12)
                    }
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
            if cal.phase == .taps {
                let p = CGPoint(x: cal.target.x * size.width, y: cal.target.y * size.height)
                ZStack {
                    Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 2).frame(width: 64, height: 64)
                        .scaleEffect(pulse ? 1.25 : 0.85).opacity(pulse ? 0.2 : 0.9)
                    Circle().fill(Theme.accent).frame(width: 18, height: 18)
                    Circle().stroke(.white, lineWidth: 2).frame(width: 18, height: 18)
                }
                .position(p)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cal.target)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
            }
            // Keep the instructions away from the dot.
            panel.position(x: size.width / 2, y: size.height * (cal.phase == .taps && cal.target.y >= 0.5 ? 0.16 : 0.84))
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 10) {
            switch cal.phase {
            case .taps:
                Text("Tap the dot lightly with your fingertip: short and crisp")
                    .font(.system(size: 19, weight: .semibold))
                ProgressView(value: Double(cal.done), total: Double(cal.total)).tint(Theme.accent).frame(width: 300)
                Text("\(cal.done) / \(cal.total)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                if let q = cal.quality {
                    Label(q == .good ? "Good tap" : q == .soft ? "A little crisper" : "Gentler is fine",
                          systemImage: q == .good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(q == .good ? .green : .orange).font(.system(size: 14, weight: .medium))
                        .id(cal.flash)
                }
                if let e = lastEvent, case .ignored(let why) = e.outcome, Date().timeIntervalSince(e.date) < 2 {
                    Text("Last tap not counted: \(why)").font(.system(size: 13)).foregroundStyle(.orange)
                }
            case .noise(let until):
                Text("Now everyday bumps: type, click, scroll, knock the desk, nudge the laptop")
                    .font(.system(size: 19, weight: .semibold)).multilineTextAlignment(.center)
                Text("It learns not to mistake these for taps. Do NOT tap the screen.").foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let left = max(0, until.timeIntervalSince(ctx.date))
                    Text("\(Int(left.rounded())) s · \(cal.noiseAdded) samples").font(.system(size: 14, design: .monospaced))
                }
            }
            Text(cal.phase == .taps ? "delete: undo   ·   esc: quit" : "space: finish   ·   delete: undo   ·   esc: quit")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
    }
}
