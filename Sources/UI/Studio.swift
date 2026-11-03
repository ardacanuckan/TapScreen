import SwiftUI

enum StudioTab: String, CaseIterable, Identifiable {
    case home, tapMap, calibrate, live, model, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .tapMap: "Tap Map"
        case .calibrate: "Calibration"
        case .live: "Live"
        case .model: "Model"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .tapMap: "square.grid.3x3.topleft.filled"
        case .calibrate: "scope"
        case .live: "waveform.path.ecg"
        case .model: "brain"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class StudioState: ObservableObject {
    static let shared = StudioState()
    @Published var tab: StudioTab = .home
}

struct StudioView: View {
    @ObservedObject private var state = StudioState.shared
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        NavigationSplitView {
            List(StudioTab.allCases, selection: Binding(get: { state.tab }, set: { if let t = $0 { state.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Toggle(isOn: $engine.settings.enabled) { Text(engine.settings.enabled ? "On" : "Off").font(.system(size: 12, weight: .medium)) }
                        .toggleStyle(.switch).controlSize(.small)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state.tab {
                    case .home: HomeTab()
                    case .tapMap: TapMapTab()
                    case .live: LiveTab()
                    case .calibrate: CalibrateTab()
                    case .model: ModelTab()
                    case .settings: SettingsTab()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(state.tab.title)
        }
    }
}

// MARK: - Live

struct LiveTab: View {
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        Card(title: "Motion sensor · twist (gyro)") {
            ScopeView(detector: engine.detector).frame(height: 170)
            HStack(spacing: 6) {
                Pill(text: "\(Int(engine.sensorRate)) Hz", symbol: "waveform.path", color: engine.sensorRate > 300 ? .green : .orange)
                if let a = engine.lidAngle { Pill(text: "lid \(a)°", symbol: "laptopcomputer") }
                Pill(text: engine.micRunning ? "mic on" : "mic off", symbol: "mic", color: engine.micRunning ? .orange : .secondary)
                if let p = engine.sensorProblem { Pill(text: p, symbol: "exclamationmark.triangle", color: .orange) }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            Card(title: "Last tap · model belief") {
                PosteriorMap(grid: engine.settings.grid, posterior: engine.lastPosterior)
                if let e = engine.lastEvent, let p = e.prediction {
                    Text("Cell \(p.cell + 1) · confidence \(Theme.percent(p.confidence)) · noise \(Theme.percent(p.noise)) · familiarity \(String(format: "%.1f×", p.familiarity))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 330)
            Card(title: "Event log") {
                if engine.recent.isEmpty {
                    Text("Tap the screen lightly. Every tap shows up here; bumps from typing are ignored.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(engine.recent.prefix(14)) { e in
                    HStack(spacing: 8) {
                        Circle().fill(e.isGood ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(e.date, format: .dateTime.hour().minute().second()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(e.summary).font(.system(size: 12))
                        if !e.detail.isEmpty { Text("· \(e.detail)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(String(format: "%.1f°/s", e.peak)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Calibrate

struct CalibrateTab: View {
    @ObservedObject private var engine = Engine.shared
    @State private var grid = Engine.shared.settings.grid
    @State private var perCell = Engine.shared.settings.tapsPerCell
    @State private var fresh = false
    @State private var confirmClear = false

    var body: some View {
        newCard
        dataCard
        tipsCard
    }

    private var minutes: Int { Int((Double(grid.count * perCell) * 1.1 + 20) / 60 + 0.5) }

    private var newCard: some View {
        Card(title: "New calibration") {
            Text("The screen is split into a grid; you tap the dot in each cell lightly with a fingertip. Then 20 s of everyday bumps (typing, clicking, knocking the desk) are recorded so the model learns to ignore them. The model trains automatically.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Grid").font(.system(size: 12, weight: .semibold))
                    Picker("", selection: $grid) {
                        ForEach(Grid.presets, id: \.self) { g in Text(g.label).tag(g) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Taps per cell").font(.system(size: 12, weight: .semibold))
                    Stepper("\(perCell)", value: $perCell, in: 5...40, step: 1)
                }
                Spacer()
            }
            Text("About \(minutes) min · \(grid.count * perCell) taps. 2×2 is the most reliable; 3×3 is ideal for Smart Touch; 4×3 is finer but needs more data.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Toggle("Discard earlier taps for this grid", isOn: $fresh).toggleStyle(.checkbox)
                Spacer()
                Button {
                    engine.settings.tapsPerCell = perCell
                    engine.startCalibration(grid: grid, perCell: perCell, fresh: fresh)
                } label: {
                    Label("Start calibration", systemImage: "play.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .disabled(engine.sensorRate == 0 && engine.settings.enabled)
            }
        }
    }

    private var dataCard: some View {
        Card(title: "Collected data · \(engine.settings.grid.label)") {
            HStack(alignment: .top, spacing: 18) {
                CountsGrid(grid: engine.settings.grid, counts: engine.cellCounts, goal: engine.settings.tapsPerCell).frame(width: 240)
                VStack(alignment: .leading, spacing: 8) {
                    stat("Calibration taps", "\(engine.samples.filter { $0.source == .calibration }.count)")
                    stat("Learned from picks", "\(engine.samples.filter { $0.source == .pick }.count)")
                    stat("Noise samples", "\(engine.noiseCount)")
                    stat("Samples with audio", "\(engine.samples.filter { $0.audio != nil }.count)")
                    HStack {
                        Button("Record noise only") { engine.recordNoiseOnly() }
                        Button("Delete all", role: .destructive) { confirmClear = true }
                    }
                    .controlSize(.small)
                }
            }
        }
        .confirmationDialog("Delete all taps and the model?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { engine.clearData() }
        }
    }

    private var tipsCard: some View {
        Card(title: "Getting good taps") {
            VStack(alignment: .leading, spacing: 5) {
                tip("A quick, light flick with the pad of your fingertip. Never press: pressure can mark the display panel.")
                tip("Let the screen settle between taps (about half a second).")
                tip("Calibrate where and at the lid angle you usually work. If you also use it on your lap, add a few rounds there too.")
                tip("Left/right is the hardest axis: tap the dot, not the cell edges.")
            }
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit().fontWeight(.semibold) }
            .font(.system(size: 12)).frame(width: 230)
    }

    private func tip(_ s: String) -> some View {
        Label { Text(s).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
        }
    }
}

struct CountsGrid: View {
    let grid: Grid
    let counts: [Int]
    let goal: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(grid.cols), h = geo.size.height / CGFloat(grid.rows)
            ForEach(0..<grid.count, id: \.self) { i in
                let c = counts.indices.contains(i) ? counts[i] : 0
                let f = min(1, Double(c) / Double(max(goal, 1)))
                RoundedRectangle(cornerRadius: 5)
                    .fill(c < 3 ? Color.orange.opacity(0.18) : Theme.accent.opacity(0.12 + 0.5 * f))
                    .overlay(Text("\(c)").font(.system(size: 12, weight: .semibold)))
                    .frame(width: w - 3, height: h - 3)
                    .offset(x: CGFloat(i % grid.cols) * w, y: CGFloat(i / grid.cols) * h)
            }
        }
        .aspectRatio(1.55, contentMode: .fit)
    }
}

// MARK: - Model

struct ModelTab: View {
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        Card(title: "Training") {
            HStack(spacing: 12) {
                Button {
                    engine.train()
                } label: { Label(engine.training ? "Training…" : "Train now", systemImage: "brain").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .disabled(engine.training || !engine.canTrain)
                Picker("Model", selection: $engine.settings.modelChoice) {
                    Text("Automatic (best)").tag(ModelKind?.none)
                    ForEach(ModelKind.allCases) { Text($0.title).tag(ModelKind?.some($0)) }
                }
                .frame(width: 260)
                Toggle("Mic fusion", isOn: Binding(get: { engine.settings.micFusion }, set: { engine.setMic($0) }))
                    .help("Also listens to the sound of the tap. Can help with left/right; the mic indicator turns on.")
            }
            if engine.training {
                ProgressView(value: engine.trainProgress) { Text(engine.trainStage).font(.system(size: 11)) }.tint(Theme.accent)
            }
            if let err = engine.trainError { Text(err).foregroundStyle(.orange).font(.system(size: 12)) }
            if !engine.canTrain && !engine.training {
                Text("Training needs at least 3 taps in every cell. Start from the Calibration tab.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("Every run compares 5 models with 5-fold cross-validation and picks the best. Data is augmented (time shift + sensor noise). All on this Mac, in seconds.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let r = engine.model?.report {
            HStack(spacing: 14) {
                Metric(title: "Accuracy", value: Theme.percent(r.accuracy), note: r.chosen.title)
                Metric(title: "Mean position error", value: String(format: "%.0f mm", r.errorMM), note: "estimated point → true")
                Metric(title: "Row / column", value: "\(Theme.percent(r.rowAccuracy)) / \(Theme.percent(r.columnAccuracy))", note: "top-bottom · left-right")
                Metric(title: "Noise rejected", value: Theme.percent(r.scores.first { $0.kind == r.chosen }?.noiseRejected ?? .nan), note: "\(r.noise) samples")
            }
            HStack(alignment: .top, spacing: 14) {
                Card(title: "Model comparison (cross-validated)") {
                    ForEach(r.scores) { s in
                        HStack(spacing: 8) {
                            Text(s.kind.title).font(.system(size: 12, weight: s.kind == r.chosen ? .bold : .regular)).frame(width: 150, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule().fill(s.kind == r.chosen ? Theme.accent : Color.primary.opacity(0.22))
                                        .frame(width: g.size.width * CGFloat(s.accuracy))
                                }
                            }
                            .frame(height: 10)
                            Text(Theme.percent(s.accuracy)).font(.system(size: 12, design: .monospaced)).frame(width: 44, alignment: .trailing)
                            Text(String(format: "%3.0f mm", s.errorMM)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52)
                        }
                    }
                    Text("\(r.samples) taps · \(r.usesAudio ? "IMU + audio" : "IMU only") · \(String(format: "%.1f", r.seconds)) s · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Card(title: "Accuracy per cell") {
                    PosteriorMap(grid: r.grid, posterior: r.perCellAccuracy)
                    Text("Darker = reliable. Recalibrate to strengthen weak cells; new taps add to the old ones.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 280)
            }
            Card(title: "Confusion matrix (row = true, column = predicted)") {
                ConfusionView(confusion: r.confusion, cells: r.grid.count)
            }
        }
    }
}

struct Metric: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }
}

struct ConfusionView: View {
    let confusion: [[Int]]
    let cells: Int

    var body: some View {
        let cols = confusion.first?.count ?? 0
        SwiftUI.Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("")
                ForEach(0..<cols, id: \.self) { c in
                    Text(c == cells ? "N" : "\(c + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28)
                }
            }
            ForEach(0..<confusion.count, id: \.self) { r in
                let total = max(confusion[r].reduce(0, +), 1)
                GridRow {
                    Text("\(r + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(0..<cols, id: \.self) { c in
                        let v = confusion[r][c]
                        let f = Double(v) / Double(total)
                        Text(v == 0 ? "" : "\(v)").font(.system(size: 10, design: .monospaced))
                            .frame(width: 28, height: 22)
                            .background((r == c ? Color.green : Color.orange).opacity(v == 0 ? 0.04 : 0.15 + 0.7 * f), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        Card(title: "Detection") {
            slider("Sensitivity (trigger = idle noise ×)", $engine.settings.sensitivity, 3...12, "%.1f×")
            slider("Minimum twist", $engine.settings.floor, 0.3...4, "%.1f °/s")
            Toggle("Ignore taps while typing, clicking, scrolling or moving the lid", isOn: $engine.settings.gating)
        }
        Card(title: "Decisions") {
            slider("Minimum confidence", $engine.settings.minConfidence, 0.3...0.95, "%.2f")
            slider("Reject unfamiliar taps (distance ×)", $engine.settings.rejectFactor, 1.3...5, "%.1f×")
            Toggle("Smart Touch: when two buttons are close, ask with big corner tiles instead of pressing the likelier one",
                   isOn: $engine.settings.askWhenUnsure)
            if engine.settings.askWhenUnsure {
                slider("Press directly when one is this likely", $engine.settings.autoClickShare, 0.4...0.95, "%.2f")
            }
            Stepper("Zoom steps: \(engine.settings.zoomLevels)", value: $engine.settings.zoomLevels, in: 1...4)
            Toggle("Learn from my picks (every pick becomes a training example)", isOn: $engine.settings.learnFromPicks)
        }
        Card(title: "Behaviour") {
            Toggle("Show a ripple where taps land (off = nothing drawn on screen)", isOn: $engine.settings.showFeedback)
            Toggle("Return the pointer after clicking", isOn: $engine.settings.returnPointer)
            Toggle("Toggle with ⌃⌥T", isOn: $engine.settings.hotkey)
            Toggle("Launch at login", isOn: Binding(get: { engine.launchAtLogin }, set: { engine.setLaunchAtLogin($0) }))
            Text("Right-clicking the menu bar icon also toggles it. When off, the sensors stop completely.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        Card(title: "Permissions") {
            permission("Input Monitoring", "To read the motion sensor", engine.inputMonitoringOK) {
                engine.requestInputMonitoringIfNeeded(); engine.openPrivacy("Privacy_ListenEvent")
            }
            permission("Accessibility", "To click, find buttons and run shortcuts", engine.accessibilityOK) {
                engine.requestAccessibility(); engine.openPrivacy("Privacy_Accessibility")
            }
            permission("Microphone (optional)", "For mic fusion", MicRing.permission == .authorized) {
                engine.openPrivacy("Privacy_Microphone")
            }
        }
        Card(title: "About") {
            Text("TapScreen feels taps on your display through the MacBook's built-in motion sensor (and optionally the microphone), and a small model trained on your own taps works out where you tapped. No extra hardware, no network: everything stays on this Mac.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("Sensor access and the idea: LidTap (Yemcube), yamete, apple-silicon-accelerometer. Data: ~/Library/Application Support/TapScreen")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ fmt: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 270, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).font(.system(size: 11, design: .monospaced)).frame(width: 64, alignment: .trailing)
        }
    }

    private func permission(_ title: String, _ why: String, _ ok: Bool, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Open Settings", action: fix).controlSize(.small) }
        }
    }
}
