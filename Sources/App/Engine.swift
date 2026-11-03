import AppKit
import ApplicationServices
import Combine
import IOKit.hid
import ServiceManagement

/// What happened to one detected tap, for the UI.
struct TapEvent: Identifiable {
    enum Outcome {
        case ignored(String)
        case noise
        case unfamiliar
        case unsure
        case cell(Int)
        case calibrated(Int)
        case noiseRecorded
    }

    let id = UUID()
    let date = Date()
    let peak: Float
    var outcome: Outcome
    var prediction: Prediction?
    var detail = ""

    var summary: String {
        switch outcome {
        case .ignored(let why): "Ignored: \(why)"
        case .noise: "Bump/noise, ignored"
        case .unfamiliar: "Unfamiliar, ignored"
        case .unsure: "Unsure, ignored"
        case .cell(let c): "Cell \(c + 1)" + (prediction.map { " · \(Int($0.confidence * 100))%" } ?? "")
        case .calibrated(let c): "Calibration: cell \(c + 1)"
        case .noiseRecorded: "Noise sample recorded"
        }
    }

    var isGood: Bool {
        switch outcome {
        case .cell, .calibrated, .noiseRecorded: true
        default: false
        }
    }
}

struct Calibration {
    enum Phase: Equatable { case taps, noise(until: Date) }
    enum Quality { case good, soft, hard }

    var grid: Grid
    var perCell: Int
    var order: [Int]
    var target: CGPoint
    var counts: [Int]
    var phase: Phase = .taps
    var quality: Quality?
    var added: [UUID] = []
    var noiseAdded = 0
    var noiseSeconds = 20.0
    var flash = 0

    var cell: Int? { order.first }
    var total: Int { grid.count * perCell }
    var done: Int { counts.reduce(0, +) }

    static func jittered(_ cell: Int, _ grid: Grid) -> CGPoint {
        let r = grid.rect(cell)
        return CGPoint(x: r.midX + r.width * .random(in: -0.22...0.22), y: r.midY + r.height * .random(in: -0.22...0.22))
    }
}

/// One choice while Smart Touch asks "which one?": a big tile made of grid cells, and the target it stands for.
struct PickTile: Identifiable {
    let cells: [Int]
    let target: Target
    var id: UUID { target.id }

    func rect(_ grid: Grid) -> CGRect { cells.map { grid.rect($0) }.reduce(CGRect.null) { $0.union($1) } }
}

/// Multi-tap interactions in progress.
enum Interaction {
    case idle
    case picking(tiles: [PickTile], first: TapSample, until: Date)
    case zooming(region: CGRect, level: Int, until: Date)
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var settings: Settings { didSet { if settings != oldValue { apply(oldValue) } } }
    @Published private(set) var model: TouchModel?
    @Published private(set) var samples: [TapSample] = []
    @Published private(set) var sensorRate: Double = 0
    @Published fileprivate(set) var lidAngle: Int?
    @Published fileprivate(set) var sensorProblem: String?
    @Published private(set) var recent: [TapEvent] = []
    @Published var calibration: Calibration?
    @Published private(set) var training = false
    @Published private(set) var trainProgress: Double = 0
    @Published private(set) var trainStage = ""
    @Published var trainError: String?
    @Published fileprivate(set) var accessibilityOK = AXIsProcessTrusted()
    @Published fileprivate(set) var inputMonitoringOK = true
    @Published private(set) var micRunning = false
    @Published private(set) var interaction: Interaction = .idle {
        didSet {
            overlay.update()
            if case .idle = interaction { stopEscapeMonitor() } else { startEscapeMonitor() }
        }
    }
    @Published private(set) var lastPosterior: [Float]?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Bumped on every tap (the menu bar icon flashes).
    let tapped = PassthroughSubject<Bool, Never>()

    let imu = IMUReader()
    let detector = TapDetector()
    let mic = MicRing()
    lazy var overlay = OverlayController(engine: self)

    private var statusTimer: Timer?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var learnedSinceTraining = 0
    private var noRateSince: Date?
    private var lastAppSwitch = 0.0

    var lastEvent: TapEvent? { recent.first }

    private init() {
        settings = Store.load(Settings.self, Store.settingsURL) ?? Settings()
        samples = Store.load([TapSample].self, Store.datasetURL) ?? []
        if let m = Store.load(TouchModel.self, Store.modelURL), m.grid == settings.grid,
           m.standardizer.dimension == Features.imuCount + (m.usesAudio ? Features.audioCount : 0) {
            model = m
        }
        if settings.zoneActions.count != settings.grid.count { settings.zoneActions = ZoneAction.defaults(for: settings.grid) }
        detector.onWindow = { [weak self] w in DispatchQueue.main.async { self?.received(w) } }
        imu.onSample = { [weak detector] kind, t, v in detector?.ingest(kind, t, v) }
    }

    func boot() {
        // Switching apps (Dock, ⌘-Tab, clicking a window) comes with clicks and bumps that aren't screen taps.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastAppSwitch = MachClock.now() }
        }
        apply(nil)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        statusTimer?.tolerance = 0.3
        if model == nil, canTrain { train() }
    }

    // MARK: Settings

    private func apply(_ old: Settings?) {
        Store.save(settings, Store.settingsURL)
        detector.tuning = DetectorTuning(sensitivity: settings.sensitivity, floor: settings.floor)
        let running = settings.enabled || calibration != nil
        if running { startSensors() } else { stopSensors() }
        if old?.grid != settings.grid, old != nil {
            settings.zoneActions = ZoneAction.defaults(for: settings.grid)
            if model?.grid != settings.grid { model = nil }
            if canTrain { train() }
        }
        if old?.micFusion != settings.micFusion, old != nil, canTrain { train() }
        HotKey.shared.enabled = settings.hotkey
        if old?.enabled != settings.enabled { cancelInteraction() }
    }

    private func startSensors() {
        guard !imu.isRunning else { return }
        requestInputMonitoringIfNeeded()
        imu.start()
        noRateSince = Date()
        if settings.micFusion { startMic() }
    }

    private func stopSensors() {
        imu.stop()
        mic.stop()
        micRunning = false
        sensorRate = 0
    }

    private func startMic() {
        mic.start { [weak self] ok in
            guard let self else { return }
            self.micRunning = ok
            if !ok { self.settings.micFusion = false }
        }
    }

    func setMic(_ on: Bool) {
        settings.micFusion = on
        if on && (settings.enabled || calibration != nil) { startMic() } else { mic.stop(); micRunning = false }
    }

    private func tick() {
        // @Published fires on every assignment, so only assign changes: every publish re-renders open views.
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<Engine, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        let c = imu.takeCounts()
        let rate = Double(c.gyro)
        if (rate == 0) != (sensorRate == 0) {
            Log.sensor.notice("Motion sensor \(rate > 0 ? "streaming" : "stopped", privacy: .public) at \(Int(rate)) Hz")
        }
        if abs(rate - sensorRate) > 25 || (rate == 0) != (sensorRate == 0) { sensorRate = rate }
        set(\.lidAngle, imu.lidAngle)
        set(\.accessibilityOK, AXIsProcessTrusted())
        set(\.inputMonitoringOK, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
        if imu.isRunning, c.gyro == 0 {
            if let since = noRateSince, Date().timeIntervalSince(since) > 3 {
                set(\.sensorProblem, imu.error == "permission" || !inputMonitoringOK
                    ? "No access to the motion sensor. Allow Input Monitoring."
                    : "No data from the motion sensor. This Mac may not have one (needs M2 or later).")
            }
        } else {
            noRateSince = imu.isRunning ? nil : Date()
            if c.gyro > 0 { set(\.sensorProblem, nil); noRateSince = Date() }
        }
        expireInteraction()
    }

    func requestInputMonitoringIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.engine.error("Launch at login: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Taps

    private func received(_ w: TapWindow) {
        Log.engine.debug("tap peak \(w.peakGyro, format: .fixed(precision: 2)) thr \(w.threshold, format: .fixed(precision: 2))")
        tapped.send(true)
        if micRunning { withAudio(w, attempt: 0) } else { process(w, audio: nil) }
    }

    /// The mic delivers audio in chunks, so the knock may arrive a little after the IMU window. Retry briefly.
    private func withAudio(_ w: TapWindow, attempt: Int) {
        if let a = mic.segment(around: w.t0) { return process(w, audio: a) }
        if attempt >= 4 { return process(w, audio: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.withAudio(w, attempt: attempt + 1) }
    }

    /// Typing, clicking, scrolling and lid moves shake the laptop too. Returns why a tap should be ignored.
    private func gateReason(_ w: TapWindow) -> String? {
        guard settings.gating else { return nil }
        let now = MachClock.now()
        let kinds: [(CGEventType, String)] = [(.keyDown, "typing"), (.keyUp, "typing"), (.flagsChanged, "typing"),
                                              (.leftMouseDown, "click"), (.leftMouseUp, "click"),
                                              (.rightMouseDown, "click"), (.rightMouseUp, "click"),
                                              (.otherMouseDown, "click"), (.scrollWheel, "scrolling")]
        for (type, name) in kinds {
            let t = now - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            if t > w.t0 - 0.3 && t < w.t0 + 0.2 { return name }
        }
        // A finger moving the pointer on the trackpad isn't tapping the screen.
        for type in [CGEventType.mouseMoved, .leftMouseDragged] {
            let t = now - CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            if t > w.t0 - 0.25 && t < w.t0 + 0.15 { return "using the trackpad" }
        }
        if abs(w.t0 - lastAppSwitch) < 0.7 { return "switching apps" }
        if w.t0 - imu.lidMovedAt < 0.8 { return "lid moved" }
        if w.preMotion > w.peakGyro * 0.55 && w.preMotion > w.threshold { return "screen was still wobbling" }
        return nil
    }

    private func sample(_ w: TapWindow, audio: [Float]?, source: TapSample.Source, point: CGPoint?) -> TapSample {
        TapSample(source: source, x: point.map { Float($0.x) }, y: point.map { Float($0.y) }, lidAngle: imu.lidAngle,
                  peakGyro: w.peakGyro, gyro: Floats(w.gyro), accel: Floats(w.accel), audio: audio.map(Floats.init),
                  sampleRate: audio == nil ? nil : mic.sampleRate)
    }

    private func log(_ e: TapEvent) {
        recent.insert(e, at: 0)
        if recent.count > 40 { recent.removeLast() }
    }

    private func process(_ w: TapWindow, audio: [Float]?) {
        if var cal = calibration {
            switch cal.phase {
            case .noise:
                let s = sample(w, audio: audio, source: .noise, point: nil)
                samples.append(s)
                cal.added.append(s.id)
                cal.noiseAdded += 1
                calibration = cal
                log(TapEvent(peak: w.peakGyro, outcome: .noiseRecorded))
            case .taps:
                if let why = gateReason(w) {
                    log(TapEvent(peak: w.peakGyro, outcome: .ignored(why)))
                    return
                }
                guard let cell = cal.cell else { return }
                let s = sample(w, audio: audio, source: .calibration, point: cal.target)
                samples.append(s)
                cal.added.append(s.id)
                cal.counts[cell] += 1
                cal.quality = w.peakGyro < w.threshold * 1.6 ? .soft : (w.peakGyro > 60 ? .hard : .good)
                cal.order.removeFirst()
                cal.flash += 1
                if let next = cal.order.first { cal.target = Calibration.jittered(next, cal.grid) }
                calibration = cal
                log(TapEvent(peak: w.peakGyro, outcome: .calibrated(cell)))
                if cal.order.isEmpty { beginNoisePhase() }
            }
            return
        }

        guard settings.enabled else { return }
        if let why = gateReason(w) {
            log(TapEvent(peak: w.peakGyro, outcome: .ignored(why)))
            return
        }
        guard let model else {
            log(TapEvent(peak: w.peakGyro, outcome: .ignored("calibrate first")))
            return
        }
        let s = sample(w, audio: audio, source: .pick, point: nil)
        let p = model.predict(model.features(of: s))
        lastPosterior = p.posterior
        var event = TapEvent(peak: w.peakGyro, outcome: .cell(p.cell), prediction: p)
        if p.isNoise() {
            event.outcome = .noise
        } else if p.isUnfamiliar(settings.rejectFactor) {
            event.outcome = .unfamiliar
        }
        if case .cell = event.outcome {} else { log(event); return }

        switch interaction {
        case .picking(let tiles, let first, _):
            // Add up the probability over each tile's cells: far more reliable than reading a single cell.
            let mass = tiles.map { t in t.cells.reduce(Float(0)) { $0 + p.posterior[$1] } }
            let best = mass.indices.max { mass[$0] < mass[$1] }
            if let best, mass[best] >= 0.45 {
                let target = tiles[best].target
                interaction = .idle
                target.activate(returnPointer: settings.returnPointer)
                overlay.ripple(at: target.center, color: .green)
                event.detail = "Picked: \(target.title.isEmpty ? Theme.roleName(target.role) : target.title)"
                learn(first, at: target.center)
            } else {
                cancelInteraction()
                event.detail = "Pick cancelled"
            }
        case .zooming(let region, let level, _):
            guard p.confidence >= settings.minConfidence * 0.8 else { event.outcome = .unsure; break }
            zoom(into: settings.grid.rect(p.cell, in: region), level: level + 1)
        case .idle:
            switch settings.mode {
            case .zones:
                let action = settings.zoneActions.indices.contains(p.cell) ? settings.zoneActions[p.cell] : ZoneAction(.none)
                if action.kind == .smartTouch {
                    event.detail = smartTap(p, sample: s)
                    break
                }
                guard p.confidence >= settings.minConfidence else { event.outcome = .unsure; break }
                if settings.showFeedback { overlay.zoneFlash(p.cell, title: action.label) }
                action.run(cell: p.cell, grid: settings.grid, returnPointer: settings.returnPointer)
                event.detail = action.label
            case .zoom:
                guard p.confidence >= settings.minConfidence * 0.8 else { event.outcome = .unsure; break }
                zoom(into: settings.grid.rect(p.cell), level: 1)
            case .smart:
                event.detail = smartTap(p, sample: s)
            }
        }
        log(event)
    }

    // MARK: Smart touch

    /// Finds what's under the finger: clickable things on screen, scored by where the model thinks the tap landed.
    /// One clear winner → press it. Several close candidates → ask with up to four big corner tiles. Nothing near
    /// the tap → do nothing rather than guess.
    private func smartTap(_ p: Prediction, sample: TapSample) -> String {
        guard accessibilityOK else {
            requestAccessibility()
            return "Accessibility permission needed"
        }
        guard let model else { return "" }
        let ranked = SmartTouch.visible(SmartTouch.rank(SmartTouch.collect(), posterior: p.posterior, centroids: model.centroids,
                                                        grid: settings.grid))
        let estimate = Display.cgPoint(p.point)
        guard let top = ranked.first, top.score >= 0.06 else {
            if settings.showFeedback { overlay.ripple(at: estimate, color: .miss) }
            return "Nothing to press here"
        }
        let pool = ranked.prefix(6)
        let share = top.score / max(pool.reduce(0) { $0 + $1.score }, 1e-9)
        // Candidates worth asking about: within reach of the best one.
        let contenders = ranked.filter { $0.score >= top.score * 0.25 }
        // By default a tap just presses the best match: nothing drawn on screen, nothing to answer.
        if !settings.askWhenUnsure || contenders.count == 1
            || (Float(share) >= settings.autoClickShare && p.confidence >= settings.minConfidence) {
            top.activate(returnPointer: settings.returnPointer)
            if settings.showFeedback { overlay.ripple(at: top.center, color: .accent) }
            return "Pressed: \(top.title.isEmpty ? Theme.roleName(top.role) : top.title) (\(Int(share * 100))%)"
        }
        // Ambiguous: the best few, each on its own big corner tile, nearest corner first.
        let regions = SmartTouch.pickRegions(settings.grid)
        var free = Array(regions.indices)
        var tiles: [PickTile] = []
        let b = Display.bounds
        for t in contenders.prefix(regions.count) {
            let n = CGPoint(x: (t.center.x - b.minX) / b.width, y: (t.center.y - b.minY) / b.height)
            func center(_ r: Int) -> CGPoint {
                let rect = regions[r].map { settings.grid.rect($0) }.reduce(CGRect.null) { $0.union($1) }
                return CGPoint(x: rect.midX, y: rect.midY)
            }
            guard let r = free.min(by: { dist(center($0), n) < dist(center($1), n) }) else { break }
            free.removeAll { $0 == r }
            tiles.append(PickTile(cells: regions[r], target: t))
        }
        interaction = .picking(tiles: tiles, first: sample, until: Date().addingTimeInterval(6))
        return "Showing \(tiles.count) choices"
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// A pick tells us exactly where the first tap was aimed: a free labelled example.
    private func learn(_ first: TapSample, at cgPoint: CGPoint) {
        guard settings.learnFromPicks else { return }
        let n = Display.normalized(CGRect(origin: cgPoint, size: .zero)).origin
        var s = first
        s.source = .pick
        s.x = Float(n.x)
        s.y = Float(n.y)
        samples.append(s)
        saveSamples()
        learnedSinceTraining += 1
        if learnedSinceTraining >= 6, !training { train(quiet: true) }
    }

    // MARK: Zoom

    private func zoom(into region: CGRect, level: Int) {
        if level >= settings.zoomLevels || region.width * Display.bounds.width < 50 {
            interaction = .idle
            let cg = Display.cgRect(region)
            // Snap to a clickable thing inside the final region when there is one.
            var point = CGPoint(x: cg.midX, y: cg.midY)
            if accessibilityOK {
                let inside = SmartTouch.collect(budget: 0.08).filter { cg.insetBy(dx: -cg.width * 0.15, dy: -cg.height * 0.15).contains($0.center) }
                if let t = inside.min(by: { dist($0.center, point) < dist($1.center, point) }) {
                    t.activate(returnPointer: settings.returnPointer)
                    if settings.showFeedback { overlay.ripple(at: t.center, color: .accent) }
                    return
                }
                point = CGPoint(x: cg.midX, y: cg.midY)
            }
            Pointer.click(at: point, returnPointer: settings.returnPointer)
            if settings.showFeedback { overlay.ripple(at: point, color: .accent) }
            return
        }
        interaction = .zooming(region: region, level: level, until: Date().addingTimeInterval(6))
    }

    func cancelInteraction() {
        if case .idle = interaction { return }
        interaction = .idle
    }

    private func expireInteraction() {
        switch interaction {
        case .picking(_, _, let until), .zooming(_, _, let until):
            if Date() > until { cancelInteraction() }
        case .idle: break
        }
    }

    /// Any key press cancels a pending pick or zoom (needs Accessibility for a global monitor).
    private func startEscapeMonitor() {
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        }
    }

    private func stopEscapeMonitor() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        globalKeyMonitor = nil
    }

    // MARK: Calibration

    func startCalibration(grid: Grid, perCell: Int, fresh: Bool) {
        cancelInteraction()
        if grid != settings.grid { settings.grid = grid }
        if fresh { samples.removeAll { $0.source != .noise } }
        var order: [Int] = []
        for _ in 0..<perCell { order += Array(0..<grid.count).shuffled() }
        calibration = Calibration(grid: grid, perCell: perCell, order: order, target: Calibration.jittered(order[0], grid),
                                  counts: Array(repeating: 0, count: grid.count))
        startSensors()
        NSApp.activate(ignoringOtherApps: true)
        overlay.update()
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let key = e.keyCode
            let handled = MainActor.assumeIsolated { self?.calibrationKey(key) ?? false }
            return handled ? nil : e
        }
    }

    /// Esc quits calibration, delete undoes the last tap, space ends the noise phase early.
    private func calibrationKey(_ key: UInt16) -> Bool {
        guard let cal = calibration else { return false }
        switch key {
        case 53: finishCalibration(train: false)
        case 51: undoCalibrationTap()
        case 49: if case .noise = cal.phase { finishCalibration(train: true) }
        default: return false
        }
        return true
    }

    /// Only the "everyday bumps" part: typing, clicks, desk knocks the model should learn to ignore.
    func recordNoiseOnly() {
        cancelInteraction()
        let grid = settings.grid
        calibration = Calibration(grid: grid, perCell: 0, order: [], target: grid.center(0), counts: Array(repeating: 0, count: grid.count))
        startSensors()
        NSApp.activate(ignoringOtherApps: true)
        beginNoisePhase()
        overlay.update()
        installKeyMonitor()
    }

    func undoCalibrationTap() {
        guard var cal = calibration, let last = cal.added.popLast(), let s = samples.first(where: { $0.id == last }) else { return }
        samples.removeAll { $0.id == last }
        if s.isNoise { cal.noiseAdded -= 1 } else if let p = s.point {
            let cell = cal.grid.cell(at: p)
            cal.counts[cell] -= 1
            cal.order.insert(cell, at: 0)
            cal.target = p
            if case .noise = cal.phase { cal.phase = .taps }
        }
        calibration = cal
    }

    private func beginNoisePhase() {
        guard var cal = calibration else { return }
        cal.phase = .noise(until: Date().addingTimeInterval(cal.noiseSeconds))
        calibration = cal
        saveSamples()
        DispatchQueue.main.asyncAfter(deadline: .now() + cal.noiseSeconds) { [weak self] in
            guard let self, case .noise = self.calibration?.phase else { return }
            self.finishCalibration(train: true)
        }
    }

    func finishCalibration(train shouldTrain: Bool) {
        guard calibration != nil else { return }
        calibration = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        overlay.update()
        saveSamples()
        if !settings.enabled { stopSensors() }
        if shouldTrain || canTrain { train() }
    }

    // MARK: Data and training

    var cellCounts: [Int] {
        var c = [Int](repeating: 0, count: settings.grid.count)
        for s in samples { if let p = s.point { c[settings.grid.cell(at: p)] += 1 } }
        return c
    }

    var noiseCount: Int { samples.filter(\.isNoise).count }
    var canTrain: Bool { cellCounts.allSatisfy { $0 >= 3 } }

    func saveSamples() { Store.save(samples, Store.datasetURL) }

    func clearData() {
        samples = []
        model = nil
        saveSamples()
        try? FileManager.default.removeItem(at: Store.modelURL)
    }

    func train(quiet: Bool = false) {
        guard !training, calibration == nil else { return }
        training = true
        trainProgress = 0
        trainStage = "Preparing"
        trainError = nil
        learnedSinceTraining = 0
        let data = samples, grid = settings.grid, mic = settings.micFusion, choice = settings.modelChoice, mm = Display.sizeMM
        Task.detached(priority: .utility) {
            let result = Result {
                try Trainer.train(samples: data, grid: grid, micFusion: mic, choice: choice, screenMM: mm) { p, stage in
                    Task { @MainActor in
                        self.trainProgress = p
                        self.trainStage = stage
                    }
                }
            }
            await self.finishTraining(result, quiet: quiet)
        }
    }

    private func finishTraining(_ result: Result<TouchModel, Error>, quiet: Bool) {
        training = false
        switch result {
        case .success(let m):
            guard m.grid == settings.grid else { return }
            model = m
            Store.save(m, Store.modelURL)
            Log.ml.notice("Trained \(m.report.chosen.rawValue, privacy: .public): \(Int(m.report.accuracy * 100))%")
        case .failure(let e):
            if !quiet { trainError = e.localizedDescription }
        }
    }

    func toggle() { settings.enabled.toggle() }

    /// Used by `--snapshot` to render the UI with made-up data.
    func installForPreview(model: TouchModel, samples: [TapSample], events: [TapEvent], posterior: [Float]) {
        self.model = model
        self.samples = samples
        recent = events
        lastPosterior = posterior
        sensorRate = 790
        lidAngle = 118
    }

    func previewInteraction(_ i: Interaction) { interaction = i }
}
