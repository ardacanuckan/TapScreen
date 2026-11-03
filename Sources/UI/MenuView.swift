import SwiftUI

/// The menu bar popover: on/off, mode, what the last tap did, and the way into calibration and the studio.
struct MenuView: View {
    @ObservedObject private var engine = Engine.shared
    let openStudio: (StudioTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banners
            modes
            live
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap").font(.system(size: 20)).foregroundStyle(engine.settings.enabled ? .primary : .tertiary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("TapScreen").font(.system(size: 16, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $engine.settings.enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    private var subtitle: String {
        guard engine.settings.enabled else { return "Off · ⌃⌥T to turn on" }
        guard let m = engine.model else { return "Needs calibration" }
        return "\(m.grid.label) · \(m.report.chosen.title) · \(Theme.percent(m.report.accuracy))"
    }

    @ViewBuilder private var banners: some View {
        if let problem = engine.sensorProblem {
            Banner(symbol: "exclamationmark.triangle.fill", text: problem, color: .orange,
                   button: "Allow") { engine.requestInputMonitoringIfNeeded(); engine.openPrivacy("Privacy_ListenEvent") }
        }
        if !engine.accessibilityOK && engine.settings.enabled {
            Banner(symbol: "hand.raised.fill", text: "Clicking and shortcuts need Accessibility permission.", color: .orange,
                   button: "Allow") { engine.requestAccessibility() }
        }
        if engine.model == nil && !engine.training {
            Banner(symbol: "scope", text: "Calibrate first: tap the dots on a grid a few times (~2 min).", color: Theme.accent,
                   button: "Start") { openStudio(.calibrate) }
        }
        if engine.training {
            HStack {
                ProgressView(value: engine.trainProgress).tint(Theme.accent)
                Text(engine.trainStage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var modes: some View {
        HStack(spacing: 6) {
            ForEach(TouchMode.allCases) { mode in
                let on = engine.settings.mode == mode
                Button {
                    engine.settings.mode = mode
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 16, weight: .medium))
                        Text(mode.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundStyle(on ? Theme.accent : .primary)
                    .background(on ? Theme.accent.opacity(0.1) : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.hairline))
                }
                .buttonStyle(.plain)
                .help(mode.blurb)
            }
        }
    }

    private var live: some View {
        HStack(alignment: .top, spacing: 12) {
            PosteriorMap(grid: engine.settings.grid, posterior: engine.lastPosterior, labels: false)
                .frame(width: 92)
            VStack(alignment: .leading, spacing: 6) {
                if let e = engine.lastEvent {
                    Text(e.summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(e.isGood ? .primary : .secondary)
                        .lineLimit(1)
                    if !e.detail.isEmpty { Text(e.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                } else {
                    Text("No taps yet").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Pill(text: engine.sensorRate > 0 ? "\(Int(engine.sensorRate)) Hz" : "waiting for sensor", symbol: "waveform.path",
                         color: engine.sensorRate > 300 ? .green : .secondary)
                    if let a = engine.lidAngle { Pill(text: "\(a)°", symbol: "laptopcomputer") }
                    if engine.micRunning { Pill(text: "mic", symbol: "mic.fill", color: .orange) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button { openStudio(.calibrate) } label: { Label("Calibrate", systemImage: "scope") }
            Button { openStudio(.home) } label: { Label("Open TapScreen", systemImage: "macwindow") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
        }
        .controlSize(.regular)
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let color: Color
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let button, let action { Button(button, action: action).controlSize(.small) }
        }
        .padding(9)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}
