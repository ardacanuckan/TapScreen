import AppKit
import SwiftUI

/// `TapScreen --snapshot <dir>` renders the main screens to PNG with synthetic data (UI checks without a display).
@MainActor
enum Snapshot {
    static func run(_ dir: String) -> Never {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let engine = Engine.shared
        let grid = engine.settings.grid
        var rng = SplitMix(seed: 3)
        var samples: [TapSample] = []
        for c in 0..<grid.count {
            for _ in 0..<10 {
                let p = Calibration.jittered(c, grid)
                let (g, a) = synth(Float(p.x), Float(p.y), &rng)
                samples.append(TapSample(source: .calibration, x: Float(p.x), y: Float(p.y), lidAngle: 118, peakGyro: 8, gyro: Floats(g), accel: Floats(a)))
            }
        }
        let model = try! Trainer.train(samples: samples, grid: grid, micFusion: false, choice: nil, screenMM: Display.sizeMM) { _, _ in }
        let pred = model.predict(model.features(of: samples[7]))
        var events = [TapEvent(peak: 7.2, outcome: .cell(pred.cell), prediction: pred, detail: "Pressed: Save (84%)"),
                      TapEvent(peak: 1.6, outcome: .ignored("typing")),
                      TapEvent(peak: 9.1, outcome: .cell(4), prediction: pred, detail: "Showing 3 choices")]
        events[0].detail = "Pressed: Save (84%)"
        engine.installForPreview(model: model, samples: samples, events: events, posterior: pred.posterior)

        func save<V: View>(_ name: String, _ view: V, _ size: CGSize, dark: Bool = false) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(dark ? Color.black : Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
        }

        save("menu", MenuView(openStudio: { _ in }).padding(0), CGSize(width: 340, height: 420))
        for tab in StudioTab.allCases {
            StudioState.shared.tab = tab
            save("studio-\(tab.rawValue)", StudioView(), CGSize(width: 980, height: 720))
        }
        let size = Display.screen?.frame.size ?? CGSize(width: 1470, height: 956)
        engine.calibration = Calibration(grid: grid, perCell: 10, order: [4, 2, 7], target: Calibration.jittered(4, grid),
                                         counts: (0..<grid.count).map { $0 * 2 % 10 }, quality: .good)
        save("overlay-calibration", OverlayView(engine: engine, fx: OverlayFX()), size, dark: true)
        engine.calibration = nil
        let sys = AXUIElementCreateSystemWide()
        let b = Display.bounds
        let regions = SmartTouch.pickRegions(grid)
        let tiles = [
            PickTile(cells: regions[0], target: Target(element: sys, frame: CGRect(x: b.minX + 220, y: b.minY + 140, width: 90, height: 28), role: "AXButton", title: "Save", pid: 0)),
            PickTile(cells: regions[1], target: Target(element: sys, frame: CGRect(x: b.minX + 330, y: b.minY + 140, width: 90, height: 28), role: "AXButton", title: "Cancel", pid: 0)),
            PickTile(cells: regions[2], target: Target(element: sys, frame: CGRect(x: b.minX + 260, y: b.minY + 190, width: 160, height: 22), role: "AXLink", title: "Details", pid: 0)),
        ]
        engine.previewInteraction(.picking(tiles: tiles, first: samples[0], until: .distantFuture))
        save("overlay-picker", OverlayView(engine: engine, fx: OverlayFX()), size, dark: true)
        engine.previewInteraction(.zooming(region: grid.rect(4), level: 1, until: .distantFuture))
        save("overlay-zoom", OverlayView(engine: engine, fx: OverlayFX()), size, dark: true)
        engine.previewInteraction(.idle)
        print("Snapshots written to \(dir)")
        exit(0)
    }

    private static func synth(_ u: Float, _ v: Float, _ rng: inout SplitMix) -> ([Float], [Float]) {
        let n = TapDetector.length, pre = TapDetector.pre
        var g = [Float](repeating: 0, count: n * 3), a = g
        let mix = SIMD3<Float>((0.5 - v) * 1.8 + 0.2 * (u - 0.5), 0.25 + 2.4 * (u - 0.5) * (u - 0.5), 1.6 * (u - 0.5))
        for i in 0..<n {
            let t = Float(i - pre) / 800
            let env: Float = t < 0 ? 0 : exp(-t * 25) * (1 - exp(-t * 400))
            for k in 0..<3 {
                g[i * 3 + k] = 8 * env * sin(2 * .pi * (40 + 12 * v) * t) * mix[k] + 0.12 * rng.gaussian()
                a[i * 3 + k] = 0.01 * env * cos(2 * .pi * 70 * t + Float(k)) + 0.0008 * rng.gaussian()
            }
        }
        return (g, a)
    }
}
