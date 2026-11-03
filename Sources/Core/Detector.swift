import Foundation

/// One tap, cut around the trigger: `TapDetector.length` samples at 800 Hz of high-passed gyro (deg/s) and
/// accelerometer (g), interleaved x,y,z. Sample `TapDetector.pre` is the trigger.
struct TapWindow {
    var t0: Double
    var gyro: [Float]
    var accel: [Float]
    var peakGyro: Float
    var peakAccel: Float
    var noise: Float
    var threshold: Float
    /// Strongest twist in the 300 ms before the trigger: a deliberate tap starts from a still screen.
    var preMotion: Float
}

struct DetectorTuning: Equatable {
    var sensitivity: Float = 6     // trigger at this many times the idle twist noise ...
    var floor: Float = 1.2         // ... but never below this many deg/s
    var refractory: Double = 0.38  // dead time after a tap so the wobble doesn't trigger again
}

/// Fixed-capacity history of timestamped 3-axis samples.
struct Ring3 {
    let capacity: Int
    private(set) var t: [Double]
    private(set) var v: [SIMD3<Float>]
    private(set) var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        t = Array(repeating: 0, count: capacity)
        v = Array(repeating: .zero, count: capacity)
    }

    mutating func append(_ time: Double, _ value: SIMD3<Float>) {
        t[head] = time
        v[head] = value
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    var lastTime: Double { count == 0 ? 0 : t[(head - 1 + capacity) % capacity] }

    /// Slot of the i-th oldest sample.
    @inline(__always) func slot(_ i: Int) -> Int { (head - count + i + capacity) % capacity }

    /// Linear resampling onto `n` uniform points from `start`, interleaved x,y,z. Nil if the history doesn't cover it.
    func resample(start: Double, step: Double, n: Int) -> [Float]? {
        guard count > 2, t[slot(0)] <= start, lastTime >= start + step * Double(n - 1) - 0.003 else { return nil }
        // Binary search for the last sample at or before `start`.
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if t[slot(mid)] <= start { lo = mid } else { hi = mid - 1 }
        }
        var j = lo
        var out = [Float](repeating: 0, count: n * 3)
        for k in 0..<n {
            let tk = start + Double(k) * step
            while j + 1 < count - 1 && t[slot(j + 1)] < tk { j += 1 }
            let a = slot(j), b = slot(min(j + 1, count - 1))
            let span = t[b] - t[a]
            let w = span > 0 ? Float(min(1, max(0, (tk - t[a]) / span))) : 0
            let p = v[a] + (v[b] - v[a]) * w
            out[k * 3] = p.x; out[k * 3 + 1] = p.y; out[k * 3 + 2] = p.z
        }
        return out
    }
}

/// First-order high-pass filter on three axes (removes gravity and slow drift).
struct HighPass3 {
    var fc: Float = 5
    private var prevIn: SIMD3<Float>?
    private var prevOut = SIMD3<Float>.zero
    private var lastT: Double = 0

    mutating func callAsFunction(_ x: SIMD3<Float>, at t: Double) -> SIMD3<Float> {
        let dt = Float(lastT == 0 ? 1.0 / 800 : min(0.01, max(0.0004, t - lastT)))
        lastT = t
        let rc = 1 / (2 * Float.pi * fc)
        let a = rc / (rc + dt)
        let p = prevIn ?? x
        let y = a * (prevOut + x - p)
        prevIn = x
        prevOut = y
        return y
    }
}

/// Finds taps in the IMU stream. Runs entirely on the sensor thread; constant work per sample.
///
/// Trigger: high-passed gyro twist magnitude above max(floor, sensitivity × idle noise). Desk knocks shake the
/// laptop sideways but barely twist it, so the gyroscope, not the accelerometer, is the trigger.
final class TapDetector {
    static let rate = 800.0
    static let pre = 20          // 25 ms before the trigger
    static let length = 128      // 160 ms window in all → about 140 ms from tap to result
    static var post: Double { Double(length - pre) / rate }

    var onWindow: ((TapWindow) -> Void)?

    private let lock = NSLock()
    private var _tuning = DetectorTuning()
    var tuning: DetectorTuning {
        get { lock.withLock { _tuning } }
        set { lock.withLock { _tuning = newValue } }
    }

    private var gyro = Ring3(capacity: 2400)
    private var accel = Ring3(capacity: 2400)
    private var gyroHP = HighPass3()
    private var accelHP = HighPass3()
    private var noise: Float = 0.15
    private var lastTrigger = -10.0
    private var pending: Double?
    private var tuningCache = DetectorTuning()
    private var sampleIndex = 0

    // Scope for the live view: twist magnitude at 200 Hz, last 3 s.
    private var scopeMag = [Float](repeating: 0, count: 600)
    private var scopeHead = 0
    private var scopeTaps: [Double] = []
    private var scopeLastT = 0.0

    func ingest(_ kind: IMUReader.Kind, _ t: Double, _ raw: SIMD3<Float>) {
        switch kind {
        case .accel:
            accel.append(t, accelHP(raw, at: t))
        case .gyro:
            let g = gyroHP(raw, at: t)
            gyro.append(t, g)
            sampleIndex &+= 1
            if sampleIndex & 63 == 0 { tuningCache = tuning }
            let mag = (g * g).sum().squareRoot()
            let threshold = max(tuningCache.floor, tuningCache.sensitivity * noise)
            let quiet = t - lastTrigger > 0.8
            if quiet && mag < threshold {
                // Idle noise follows the quiet signal only (time constant ≈ 1.5 s).
                noise += (mag - noise) * 0.0008
                noise = max(noise, 0.02)
            }
            if pending == nil, mag >= threshold, t - lastTrigger >= tuningCache.refractory {
                pending = t
                lastTrigger = t
            }
            if sampleIndex & 3 == 0 {
                lock.withLock {
                    scopeMag[scopeHead] = mag
                    scopeHead = (scopeHead + 1) % scopeMag.count
                    scopeLastT = t
                }
            }
        }
        if let t0 = pending, gyro.lastTime >= t0 + Self.post, accel.lastTime >= t0 + Self.post {
            pending = nil
            emit(t0)
        }
    }

    private func emit(_ t0: Double) {
        let step = 1 / Self.rate, start = t0 - Double(Self.pre) * step
        guard let g = gyro.resample(start: start, step: step, n: Self.length),
              let a = accel.resample(start: start, step: step, n: Self.length) else { return }
        func peak(_ x: [Float]) -> Float {
            var best: Float = 0
            for i in stride(from: 0, to: x.count, by: 3) { best = max(best, x[i] * x[i] + x[i + 1] * x[i + 1] + x[i + 2] * x[i + 2]) }
            return best.squareRoot()
        }
        var preMotion: Float = 0
        if let before = gyro.resample(start: t0 - 0.33, step: 0.0025, n: 120) { preMotion = peak(before) }
        let tuning = tuningCache
        let window = TapWindow(t0: t0, gyro: g, accel: a, peakGyro: peak(g), peakAccel: peak(a), noise: noise,
                               threshold: max(tuning.floor, tuning.sensitivity * noise), preMotion: preMotion)
        lock.withLock {
            scopeTaps.append(t0)
            if scopeTaps.count > 12 { scopeTaps.removeFirst() }
        }
        onWindow?(window)
    }

    struct Scope {
        var mag: [Float] = []    // oldest first, 200 Hz
        var threshold: Float = 1
        var noise: Float = 0
        var taps: [Double] = []  // seconds before the newest sample
    }

    func scope() -> Scope {
        lock.withLock {
            let n = scopeMag.count
            let mag = (0..<n).map { scopeMag[(scopeHead + $0) % n] }
            let taps = scopeTaps.map { scopeLastT - $0 }.filter { $0 < 3 }
            return Scope(mag: mag, threshold: max(_tuning.floor, _tuning.sensitivity * noise), noise: noise, taps: taps)
        }
    }
}
