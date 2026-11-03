import CoreGraphics
import Foundation

// Headless checks for the signal path and the learners, on synthetic taps whose twist depends on where they land.
// Run with scripts/test.sh.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
    if !ok { failures += 1 }
}

var rng = SplitMix(seed: 7)

/// A synthetic tap at normalised (u, v): the twist axis and phase change smoothly with position.
func synthTap(u: Float, v: Float, strength: Float) -> (gyro: [Float], accel: [Float]) {
    let n = TapDetector.length, pre = TapDetector.pre
    var g = [Float](repeating: 0, count: n * 3), a = g
    let ax = (u - 0.5) * 2, ay = (0.5 - v) * 2
    let mix = SIMD3<Float>(0.9 * ay + 0.2 * ax, 0.25 + 0.6 * ax * ax, 0.8 * ax - 0.3 * ay * ax)
    let freq: Float = 38 + 14 * v + 6 * u
    for i in 0..<n {
        let t = Float(i - pre) / 800
        let env: Float = t < 0 ? 0 : exp(-t * (22 + 10 * u)) * (1 - exp(-t * 400))
        let s = sin(2 * .pi * freq * t)
        for k in 0..<3 {
            g[i * 3 + k] = strength * env * s * mix[k] + 0.12 * rng.gaussian()
            a[i * 3 + k] = strength * 0.0015 * env * cos(2 * .pi * freq * 1.7 * t + Float(k)) * (k == 2 ? 1 : 0.3 + 0.4 * u) + 0.0008 * rng.gaussian()
        }
    }
    return (g, a)
}

func dataset(grid: Grid, perCell: Int, noise: Int) -> [TapSample] {
    var out: [TapSample] = []
    for c in 0..<grid.count {
        let r = grid.rect(c)
        for _ in 0..<perCell {
            let u = Float(r.midX) + Float(r.width) * Float.random(in: -0.25...0.25, using: &rng)
            let v = Float(r.midY) + Float(r.height) * Float.random(in: -0.25...0.25, using: &rng)
            let strength = Float.random(in: 3...14, using: &rng)
            let (g, a) = synthTap(u: u, v: v, strength: strength)
            out.append(TapSample(source: .calibration, x: u, y: v, lidAngle: 118, peakGyro: strength, gyro: Floats(g), accel: Floats(a)))
        }
    }
    for _ in 0..<noise {
        // Desk knocks: mostly sideways shake, little twist, random axes.
        let n = TapDetector.length
        var g = [Float](repeating: 0, count: n * 3), a = g
        let f = Float.random(in: 15...90, using: &rng)
        for i in 0..<n {
            let t = Float(i - TapDetector.pre) / 800
            let env: Float = t < 0 ? 0 : exp(-t * 15)
            for k in 0..<3 {
                g[i * 3 + k] = 1.5 * env * sin(2 * .pi * f * t + Float(k) * 1.3) * rng.gaussian() + 0.12 * rng.gaussian()
                a[i * 3 + k] = 0.02 * env * sin(2 * .pi * f * t) + 0.001 * rng.gaussian()
            }
        }
        out.append(TapSample(source: .noise, lidAngle: 118, peakGyro: 2, gyro: Floats(g), accel: Floats(a)))
    }
    return out
}

print("Ring + detector")
do {
    var ring = Ring3(capacity: 64)
    for i in 0..<100 { ring.append(Double(i) * 0.01, SIMD3(Float(i), 0, 0)) }
    let r = ring.resample(start: 0.5, step: 0.005, n: 5)
    check(r != nil && abs(r![0] - 50) < 1e-3 && abs(r![3] - 50.5) < 1e-3, "linear resampling")
    check(ring.resample(start: 0.1, step: 0.01, n: 3) == nil, "refuses history it no longer has")

    let det = TapDetector()
    var windows: [TapWindow] = []
    det.onWindow = { windows.append($0) }
    let tapAt = 2.0
    for i in 0..<(800 * 4) {
        let t = Double(i) / 800
        var gyro = SIMD3<Float>(0.08 * rng.gaussian(), 0.08 * rng.gaussian(), 0.08 * rng.gaussian())
        if t >= tapAt { let e = Float(exp(-(t - tapAt) * 25)); gyro += SIMD3(12 * e * Float(sin(2 * .pi * 40 * (t - tapAt))), 3 * e, 0) }
        det.ingest(.gyro, t, gyro)
        det.ingest(.accel, t + 0.0003, SIMD3(0, 0, -1) + SIMD3(0.001 * rng.gaussian(), 0, 0))
    }
    check(windows.count == 1, "one tap detected (got \(windows.count))")
    if let w = windows.first {
        check(abs(w.t0 - tapAt) < 0.01, "trigger time within 10 ms (\(String(format: "%.4f", w.t0)))")
        check(w.gyro.count == TapDetector.length * 3, "window length")
        check(w.peakGyro > 5, "peak twist \(w.peakGyro)")
    }
}

print("Features")
do {
    let (g, a) = synthTap(u: 0.2, v: 0.3, strength: 8)
    let f = Features.imu(gyro: g, accel: a, lidAngle: 120)
    check(f.count == Features.imuCount && f.count == Features.imuWeights.count, "IMU feature count \(f.count)")
    check(f.allSatisfy(\.isFinite), "all finite")
    let (g2, a2) = synthTap(u: 0.2, v: 0.3, strength: 16)
    let f2 = Features.imu(gyro: g2, accel: a2, lidAngle: 120)
    let shape = zip(f.prefix(30), f2.prefix(30)).map { abs($0 - $1) }.max()!
    check(shape < 0.35, "strength-invariant shape (max diff \(shape))")
    var tone = [Float](repeating: 0, count: MicRing.segmentLength)
    for i in tone.indices { tone[i] = sin(2 * .pi * 3000 * Float(i) / 48_000) * exp(-Float(i) / 600) }
    let af = Features.audio(tone, sampleRate: 48_000, tapStrength: 8)
    check(af.count == Features.audioCount && af.allSatisfy(\.isFinite), "audio features \(af.count)")
}

print("Learners")
for grid in [Grid(2, 2), Grid(3, 3), Grid(4, 3)] {
    let data = dataset(grid: grid, perCell: 12, noise: 20)
    let t0 = Date()
    do {
        let model = try Trainer.train(samples: data, grid: grid, micFusion: false, choice: nil,
                                      screenMM: CGSize(width: 302, height: 196)) { _, _ in }
        let r = model.report
        let line = r.scores.map { "\($0.kind.rawValue) \(Int($0.accuracy * 100))%/\(Int($0.errorMM))mm" }.joined(separator: "  ")
        print("  \(grid.label): \(line)  → \(r.chosen.rawValue), \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        check(r.accuracy > 0.8, "\(grid.label) cross-validated accuracy \(Int(r.accuracy * 100))%")
        if let nr = r.scores.first(where: { $0.kind == r.chosen })?.noiseRejected { check(nr > 0.7, "\(grid.label) noise rejected \(Int(nr * 100))%") }
        // Fresh taps.
        var ok = 0, total = 0
        for c in 0..<grid.count {
            let p = grid.center(c)
            let (g, a) = synthTap(u: Float(p.x), v: Float(p.y), strength: 9)
            let s = TapSample(source: .calibration, lidAngle: 118, peakGyro: 9, gyro: Floats(g), accel: Floats(a))
            let pred = model.predict(model.features(of: s))
            total += 1
            if pred.cell == c && !pred.isNoise() { ok += 1 }
        }
        check(ok >= total - 1, "\(grid.label) fresh taps \(ok)/\(total)")
        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(TouchModel.self, from: encoded)
        let s = data[0]
        let p1 = model.predict(model.features(of: s)).posterior, p2 = decoded.predict(decoded.features(of: s)).posterior
        check(zip(p1, p2).allSatisfy { abs($0 - $1) < 1e-5 }, "\(grid.label) model round-trips through JSON (\(encoded.count / 1024) KB)")
    } catch {
        check(false, "\(grid.label) training threw \(error)")
    }
}

do {
    let thin = dataset(grid: Grid(3, 3), perCell: 2, noise: 0)
    let threw = (try? Trainer.train(samples: thin, grid: Grid(3, 3), micFusion: false, choice: nil, screenMM: .init(width: 300, height: 200)) { _, _ in }) == nil
    check(threw, "refuses to train with too few taps")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
