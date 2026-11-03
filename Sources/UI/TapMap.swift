import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Home

/// The first thing you see: on/off, what a tap does, whether everything is ready, and the last tap.
struct HomeTab: View {
    @ObservedObject private var engine = Engine.shared
    @ObservedObject private var state = StudioState.shared

    var body: some View {
        hero
        setup
        Card(title: "What a tap does") {
            HStack(spacing: 10) {
                ForEach(TouchMode.allCases) { mode in ModeCard(mode: mode, selected: engine.settings.mode == mode) { engine.settings.mode = mode } }
            }
            if engine.settings.mode == .zones {
                Button { state.tab = .tapMap } label: { Label("Edit your Tap Map", systemImage: "square.grid.3x3.topleft.filled") }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            Card(title: "Last tap") {
                HStack(alignment: .top, spacing: 14) {
                    PosteriorMap(grid: engine.settings.grid, posterior: engine.lastPosterior).frame(width: 170)
                    VStack(alignment: .leading, spacing: 6) {
                        if let e = engine.lastEvent {
                            Text(e.summary).font(.system(size: 14, weight: .semibold))
                            if !e.detail.isEmpty { Text(e.detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                            Text(e.date, format: .dateTime.hour().minute().second()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        } else {
                            Text("Tap the screen lightly with a fingertip. The map shows where the model thinks you tapped.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Card(title: "Model") {
                if let r = engine.model?.report {
                    Text(Theme.percent(r.accuracy)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    Text("right zone on \(r.grid.label) · about \(Int(r.errorMM)) mm off on average").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("\(r.samples) taps · \(r.chosen.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Not trained yet").font(.system(size: 14, weight: .semibold))
                }
                Button { state.tab = .calibrate } label: { Label(engine.model == nil ? "Calibrate" : "Add more taps", systemImage: "scope") }
            }
            .frame(width: 280)
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: "hand.tap").font(.system(size: 30, weight: .light))
                .foregroundStyle(engine.settings.enabled ? .primary : .tertiary).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.settings.enabled ? "TapScreen is on" : "TapScreen is off").font(.system(size: 20, weight: .semibold))
                Text(engine.settings.enabled ? "Tap your display. ⌃⌥T turns it off from anywhere." : "Your taps are ignored and the sensors are stopped. ⌃⌥T turns it on.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Pill(text: engine.sensorRate > 0 ? "sensor \(Int(engine.sensorRate)) Hz" : "sensor off", symbol: "waveform.path",
                         color: engine.sensorRate > 300 ? .green : .secondary)
                    if let a = engine.lidAngle { Pill(text: "lid \(a)°", symbol: "laptopcomputer") }
                    Pill(text: engine.settings.mode.title, symbol: engine.settings.mode.symbol, color: Theme.accent)
                }
            }
            Spacer()
            Toggle("", isOn: $engine.settings.enabled).toggleStyle(.switch).controlSize(.large).labelsHidden()
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var setup: some View {
        if !engine.inputMonitoringOK || engine.sensorProblem != nil {
            Banner(symbol: "exclamationmark.triangle.fill", text: "TapScreen can't read the motion sensor. Allow Input Monitoring, then reopen TapScreen.",
                   color: .orange, button: "Open Settings") { engine.requestInputMonitoringIfNeeded(); engine.openPrivacy("Privacy_ListenEvent") }
        }
        if !engine.accessibilityOK {
            Banner(symbol: "hand.raised.fill", text: "Allow Accessibility so taps can press buttons, open apps and run shortcuts.",
                   color: .orange, button: "Allow") { engine.requestAccessibility(); engine.openPrivacy("Privacy_Accessibility") }
        }
        if engine.model == nil && !engine.training {
            Banner(symbol: "scope", text: "Calibrate first: tap a dot in each zone a few times, about 3 minutes.",
                   color: Theme.accent, button: "Calibrate") { state.tab = .calibrate }
        }
    }
}

struct ModeCard: View {
    let mode: TouchMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: mode.symbol).font(.system(size: 17)).foregroundStyle(selected ? Theme.accent : .secondary)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
                Text(mode.title).font(.system(size: 13.5, weight: .semibold))
                Text(mode.blurb).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(selected ? Theme.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tap Map

/// Your screen, split like your calibration. Click a zone, choose what tapping there does.
struct TapMapTab: View {
    @ObservedObject private var engine = Engine.shared
    @State private var selected = 0

    var body: some View {
        if engine.settings.mode != .zones {
            Banner(symbol: "info.circle.fill", text: "Tap Map is set up here but not active. Right now taps use \(engine.settings.mode.title).",
                   color: Theme.accent, button: "Use Tap Map") { engine.settings.mode = .zones }
        }
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Your screen · \(engine.settings.grid.label)") {
                ScreenMap(grid: engine.settings.grid, actions: engine.settings.zoneActions, accuracy: engine.model?.report.perCellAccuracy,
                          selected: $selected)
                Text("Click a zone to change it. The small percentage is how often the model gets that zone right; recalibrate to improve weak ones. Zones follow your calibration grid.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card(title: "Zone \(selected + 1)") {
                if engine.settings.zoneActions.indices.contains(selected) {
                    ZoneInspector(index: selected, action: $engine.settings.zoneActions[selected])
                }
            }
            .frame(width: 300)
        }
        HStack {
            Button("Make every zone press what's under my finger") {
                engine.settings.zoneActions = engine.settings.zoneActions.map { _ in ZoneAction(.smartTouch) }
            }
            Button("Reset to defaults") { engine.settings.zoneActions = ZoneAction.defaults(for: engine.settings.grid) }
        }
        .controlSize(.small)
    }
}

struct ScreenMap: View {
    let grid: Grid
    let actions: [ZoneAction]
    let accuracy: [Float]?
    @Binding var selected: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(grid.cols), h = geo.size.height / CGFloat(grid.rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85))
                ForEach(0..<grid.count, id: \.self) { i in
                    let a = actions.indices.contains(i) ? actions[i] : ZoneAction(.none)
                    let on = i == selected
                    Button { selected = i } label: {
                        VStack(spacing: 6) {
                            ZoneIcon(action: a, size: min(w, h) * 0.3)
                            Text(a.label).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(a.kind == .none ? 0.4 : 0.9))
                        }
                        .padding(6)
                        .frame(width: w - 6, height: h - 6)
                        .background(on ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.accent : .white.opacity(0.1), lineWidth: on ? 2 : 1))
                        .overlay(alignment: .topLeading) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5)).padding(6)
                        }
                        .overlay(alignment: .topTrailing) {
                            if let acc = accuracy, acc.indices.contains(i) {
                                Text(Theme.percent(acc[i])).font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(acc[i] >= 0.8 ? .green : acc[i] >= 0.6 ? .yellow : .orange).padding(6)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(i % grid.cols) * w + 3, y: CGFloat(i / grid.cols) * h + 3)
                }
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
    }
}

struct ZoneIcon: View {
    let action: ZoneAction
    let size: CGFloat

    var body: some View {
        if let icon = action.fileIcon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: action.kind.symbol).font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(action.kind == .none ? .white.opacity(0.3) : .white)
                .frame(width: size, height: size)
        }
    }
}

struct ZoneInspector: View {
    let index: Int
    @Binding var action: ZoneAction

    private static let groups: [(String, [ZoneAction.Kind])] = [
        ("Open", [.openApp, .openURL, .openFile]),
        ("Touch", [.smartTouch, .click]),
        ("Mac", [.missionControl, .showDesktop, .desktopLeft, .desktopRight, .spotlight]),
        ("Media", [.playPause, .next, .previous, .volumeUp, .volumeDown, .mute]),
        ("Other", [.shell, .none]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZoneIcon(action: action, size: 34).background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                Text(action.label).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            Picker("When I tap here", selection: Binding(get: { action.kind }, set: { kind in
                if kind != action.kind { action = ZoneAction(kind) }
                if kind == .openApp { chooseApp() }
                if kind == .openFile { chooseFile() }
            })) {
                ForEach(Self.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                    }
                }
            }
            switch action.kind {
            case .openApp:
                Button { chooseApp() } label: { Label(action.argument.isEmpty ? "Choose App…" : "Change App…", systemImage: "app.badge") }
            case .openFile:
                Button { chooseFile() } label: { Label(action.argument.isEmpty ? "Choose File or Folder…" : "Change…", systemImage: "folder") }
            case .openURL:
                TextField("example.com", text: $action.argument).textFieldStyle(.roundedBorder)
            case .shell:
                TextField("zsh command, {zone} = zone number", text: $action.argument).textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            case .smartTouch:
                Text("Finds the button, link or field right where you tapped and presses it. Nothing is drawn on screen.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            if action.kind != .smartTouch && action.kind != .none {
                Button { action.run(cell: index, grid: Engine.shared.settings.grid, returnPointer: true) } label: {
                    Label("Try it now", systemImage: "play.fill")
                }
                .disabled(action.kind.needsArgument && action.argument.isEmpty)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "Which app should open when you tap zone \(index + 1)?"
        if panel.runModal() == .OK, let url = panel.url { action = ZoneAction(.openApp, url.path) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "What should open when you tap zone \(index + 1)?"
        if panel.runModal() == .OK, let url = panel.url { action = ZoneAction(.openFile, url.path) }
    }
}
