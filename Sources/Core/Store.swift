import CoreGraphics
import Foundation

/// One recorded tap. Raw windows are kept so improved feature code or a new grid re-uses old data.
struct TapSample: Codable, Identifiable {
    enum Source: String, Codable { case calibration, noise, pick }

    var id = UUID()
    var date = Date()
    var source: Source
    /// Where the finger landed, normalised (0,0 top-left). Nil for noise.
    var x: Float?
    var y: Float?
    var lidAngle: Int?
    var peakGyro: Float
    var gyro: Floats
    var accel: Floats
    var audio: Floats?
    var sampleRate: Double?

    var isNoise: Bool { source == .noise }
    var point: CGPoint? { x.flatMap { x in y.map { CGPoint(x: CGFloat(x), y: CGFloat($0)) } } }
}

enum TouchMode: String, Codable, CaseIterable, Identifiable {
    case smart, zoom, zones
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "Smart Touch"
        case .zoom: "Zoom & Tap"
        case .zones: "Tap Map"
        }
    }

    var symbol: String {
        switch self {
        case .smart: "hand.point.up.left"
        case .zoom: "plus.magnifyingglass"
        case .zones: "square.grid.3x3.topleft.filled"
        }
    }

    var blurb: String {
        switch self {
        case .smart: "Finds the button, link or field where you tapped and presses it right away."
        case .zoom: "Splits the screen into a grid; each tap zooms into the cell you chose. Reaches any point in 2–3 taps."
        case .zones: "You choose what each part of the screen does: open an app or website, music, desktops, or press what's under your finger."
        }
    }
}

struct Settings: Codable, Equatable {
    var enabled = true
    var mode: TouchMode = .smart
    var grid = Grid(3, 3)
    var tapsPerCell = 12
    var sensitivity: Float = 6
    var floor: Float = 1.2
    var gating = true
    var micFusion = false
    var modelChoice: ModelKind? = nil   // nil = pick automatically
    var minConfidence: Float = 0.55
    var rejectFactor: Float = 2.2
    var autoClickShare: Float = 0.72
    var zoomLevels = 2
    var learnFromPicks = true
    var showFeedback = false
    var askWhenUnsure = false
    var returnPointer = false
    var hotkey = true
    var zoneActions: [ZoneAction] = ZoneAction.defaults(for: Grid(3, 3))

    init() {}

    // Tolerant decoding: new settings get their defaults when an older file is loaded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = v(.enabled, d.enabled)
        mode = v(.mode, d.mode)
        grid = v(.grid, d.grid)
        tapsPerCell = v(.tapsPerCell, d.tapsPerCell)
        sensitivity = v(.sensitivity, d.sensitivity)
        floor = v(.floor, d.floor)
        gating = v(.gating, d.gating)
        micFusion = v(.micFusion, d.micFusion)
        modelChoice = v(.modelChoice, d.modelChoice)
        minConfidence = v(.minConfidence, d.minConfidence)
        rejectFactor = v(.rejectFactor, d.rejectFactor)
        autoClickShare = v(.autoClickShare, d.autoClickShare)
        zoomLevels = v(.zoomLevels, d.zoomLevels)
        learnFromPicks = v(.learnFromPicks, d.learnFromPicks)
        showFeedback = v(.showFeedback, d.showFeedback)
        askWhenUnsure = v(.askWhenUnsure, d.askWhenUnsure)
        returnPointer = v(.returnPointer, d.returnPointer)
        hotkey = v(.hotkey, d.hotkey)
        zoneActions = v(.zoneActions, ZoneAction.defaults(for: grid))
    }
}

/// Files under ~/Library/Application Support/TapScreen.
enum Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("TapScreen", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    static var datasetURL: URL { dir.appendingPathComponent("dataset.json") }
    static var modelURL: URL { dir.appendingPathComponent("model.json") }

    static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            Log.engine.error("Could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, _ url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.engine.error("Could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
