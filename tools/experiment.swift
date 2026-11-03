import CoreGraphics
import Foundation

// Replays recorded taps through model variants to find what separates *your* taps best.
//
//   scripts/experiment.sh [dataset.json]
//
// Every row is a full cross-validated training run (the same code the app uses), so the numbers are honest
// estimates for new taps: accuracy over cells, mean distance to the true point, row and column accuracy.

setvbuf(stdout, nil, _IOLBF, 0)
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TapScreen/dataset.json").path
let samples = try JSONDecoder().decode([TapSample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let screenMM = Display.sizeMM
print("\(samples.count) samples (\(samples.filter { !$0.isNoise }.count) taps, \(samples.filter(\.isNoise).count) noise) from \(path)\n")

let baseIMU = Features.imuWeights, baseAudio = Features.audioWeights
// Index groups of the IMU feature vector (see Features.imu).
let gyroIdx = Array(0..<3) + Array(6..<15) + Array(24..<27) + [33, 35] + Array(37..<43) + Array(55..<127)
let accelIdx = Array(3..<6) + Array(15..<24) + Array(27..<30) + [34, 36] + Array(43..<49) + Array(127..<199)
let templateIdx = Array(55..<199)

func weights(_ f: (Int, Float) -> Float) -> [Float] { baseIMU.enumerated().map { f($0.offset, $0.element) } }

struct Config {
    var name: String
    var grid = Grid(4, 3)
    var audio = true
    var imu: [Float] = baseIMU
    var audioW: [Float] = baseAudio
    var shrinkage = 0.4
}

func run(_ c: Config) {
    Features.imuWeights = c.imu
    Features.audioWeights = c.audioW
    Linear.ldaShrinkage = c.shrinkage
    let t0 = Date()
    guard let m = try? Trainer.train(samples: samples, grid: c.grid, micFusion: c.audio, choice: nil, screenMM: screenMM, progress: { _, _ in }) else {
        print("\(c.name): could not train"); return
    }
    let r = m.report
    func acc(_ k: ModelKind) -> String { String(format: "%3.0f", (r.scores.first { $0.kind == k }?.accuracy ?? 0) * 100) }
    print(String(format: "%-34@ %@  best %3.0f%% %-8@ %3.0f mm  row %3.0f%% col %3.0f%%  | knn %@ lda %@ log %@ mlp %@ ens %@  (%.0fs)",
                 c.name, c.grid.label, r.accuracy * 100, r.chosen.rawValue, r.errorMM, r.rowAccuracy * 100, r.columnAccuracy * 100,
                 acc(.knn), acc(.lda), acc(.logistic), acc(.mlp), acc(.ensemble), Date().timeIntervalSince(t0)))
}

let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"
var configs: [Config] = []
if only == "all" || only == "sensors" {
    configs += [
        Config(name: "baseline (IMU + audio)"),
        Config(name: "IMU only", audio: false),
        Config(name: "audio only", imu: weights { _, _ in 0 }),
        Config(name: "gyro + audio (no accel)", imu: weights { accelIdx.contains($0) ? 0 : $1 }),
        Config(name: "accel + audio (no gyro)", imu: weights { gyroIdx.contains($0) ? 0 : $1 }),
        Config(name: "no waveform template", imu: weights { templateIdx.contains($0) ? 0 : $1 }),
        Config(name: "template weight 1.0", imu: weights { templateIdx.contains($0) ? 1 : $1 }),
        Config(name: "no lid angle", imu: weights { $0 == 199 ? 0 : $1 }),
        Config(name: "audio weight ×2", audioW: baseAudio.map { $0 * 2 }),
        Config(name: "audio weight ×0.4", audioW: baseAudio.map { $0 * 0.4 }),
    ]
}
if only == "all" || only == "lda" {
    for s in [0.1, 0.2, 0.6, 0.8] { configs.append(Config(name: "LDA shrinkage \(s)", shrinkage: s)) }
}
if only == "round2" {
    // Motion only (the mic added nothing), heavier template, then alignment and resolution variants.
    func cfg(_ name: String, template: Float, points: Int = 24, step: Int = 3, align: Bool = false, noAccel: Bool = false) -> Config {
        Features.templatePoints = points
        Features.templateStep = step
        var w = Features.defaultIMUWeights(template: template)
        if noAccel {
            // Accel template is the second half of the template block.
            let start = 55 + points * 3
            for i in Array(3..<6) + Array(15..<24) + Array(27..<30) + [34, 36] + Array(43..<49) + Array(start..<(start + points * 3)) { w[i] = 0 }
        }
        return Config(name: name, audio: false, imu: w)
    }
    let variants: [(String, Float, Int, Int, Bool, Bool)] = [
        ("tmpl 1.0", 1.0, 24, 3, false, false),
        ("tmpl 1.5", 1.5, 24, 3, false, false),
        ("tmpl 1.0 peak-aligned", 1.0, 24, 3, true, false),
        ("tmpl 1.0 fine (40×2)", 1.0, 40, 2, false, false),
        ("tmpl 1.0 fine peak-aligned", 1.0, 40, 2, true, false),
        ("tmpl 1.0 long (32×3)", 1.0, 32, 3, false, false),
        ("tmpl 1.0 peak-aligned no accel", 1.0, 24, 3, true, true),
        ("tmpl 1.5 peak-aligned", 1.5, 24, 3, true, false),
    ]
    for v in variants {
        Features.alignToPeak = v.4
        let c = cfg(v.0, template: v.1, points: v.2, step: v.3, align: v.4, noAccel: v.5)
        run(c)
    }
}
if only == "all" || only == "grids" {
    for g in [Grid(2, 2), Grid(3, 2), Grid(3, 3)] { configs.append(Config(name: "grid", grid: g)) }
}
for c in configs { run(c) }
