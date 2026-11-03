import Accelerate
import Foundation

/// Turns a raw tap (IMU window, optional audio) into a fixed-length feature vector.
///
/// Every IMU feature is scaled by the tap's own strength, so a soft and a firm tap on the same spot look alike.
/// Each feature carries a weight applied after standardisation: hand-made physical features count fully, the long
/// waveform template is down-weighted so it doesn't drown them.
enum Features {
    static var imuCount: Int { imuWeights.count }
    static let audioCount = audioBands + 3
    static let audioBands = 24

    // Defaults tuned on real lap taps (tools/experiment.swift, round 2): a heavier, finer, peak-aligned waveform
    // template took 4×3 accuracy from 73% to 78% and mean error from 32 to 26 mm.
    static var imuWeights: [Float] = defaultIMUWeights()

    /// Waveform template: `templatePoints` samples every `templateStep`, starting a few samples before the trigger,
    /// or before the twist peak when `alignToPeak` (soft taps cross the trigger at varying points of their rise).
    static var templatePoints = 40
    static var templateStep = 2
    static var alignToPeak = true

    static func defaultIMUWeights(template: Float = 1.0) -> [Float] {
        var w: [Float] = []
        w += Array(repeating: 1, count: 6)      // signed direction at peak (gyro, accel)
        w += Array(repeating: 1, count: 18)     // early integrals 10/30/80 ms
        w += Array(repeating: 1, count: 6)      // axis energy split
        w += Array(repeating: 0.8, count: 3)    // strengths and twist/shake ratio
        w += Array(repeating: 0.8, count: 4)    // decay and peak timing
        w += Array(repeating: 0.8, count: 12)   // spectral bands
        w += Array(repeating: 0.7, count: 6)    // axis correlations
        w += Array(repeating: template, count: templatePoints * 6) // waveform template
        w += [0.5]                              // lid angle
        return w
    }

    static var audioWeights: [Float] = Array(repeating: 0.8, count: audioBands) + [0.6, 0.6, 0.6]


    static func weights(audio: Bool) -> [Float] { audio ? imuWeights + audioWeights : imuWeights }

    // MARK: IMU

    static func imu(gyro g: [Float], accel a: [Float], lidAngle: Int?) -> [Float] {
        let n = g.count / 3, pre = TapDetector.pre
        func axis(_ x: [Float], _ k: Int) -> [Float] { stride(from: k, to: x.count, by: 3).map { x[$0] } }
        let gx = (0..<3).map { axis(g, $0) }, ax = (0..<3).map { axis(a, $0) }
        func mags(_ c: [[Float]]) -> [Float] { (0..<n).map { (c[0][$0] * c[0][$0] + c[1][$0] * c[1][$0] + c[2][$0] * c[2][$0]).squareRoot() } }
        let gm = mags(gx), am = mags(ax)
        let gPeakI = gm.indices.max { gm[$0] < gm[$1] } ?? pre
        let aPeakI = am.indices.max { am[$0] < am[$1] } ?? pre
        let gs = max(gm[gPeakI], 1e-4), asc = max(am[aPeakI], 1e-6)

        var f: [Float] = []
        f.reserveCapacity(imuCount)
        // Signed direction of the twist and the shake at their peaks.
        for k in 0..<3 { f.append(gx[k][gPeakI] / gs) }
        for k in 0..<3 { f.append(ax[k][aPeakI] / asc) }
        // Net early motion per axis: which way the lid first rotates and moves.
        for (c, s) in [(gx, gs), (ax, asc)] {
            for len in [8, 24, 64] {
                for k in 0..<3 {
                    var acc: Float = 0
                    for i in pre..<min(n, pre + len) { acc += c[k][i] }
                    f.append(acc / (s * Float(len).squareRoot() * 2))
                }
            }
        }
        // How the energy splits across axes.
        for c in [gx, ax] {
            let e = (0..<3).map { k in c[k].reduce(0) { $0 + $1 * $1 } }
            let tot = max(e.reduce(0, +), 1e-12)
            for k in 0..<3 { f.append(e[k] / tot) }
        }
        // Strengths: tap strength itself is weak evidence, but twist per unit of shake depends on position.
        f.append(log(gs) / 2)
        f.append(log(asc * 1000) / 2)
        f.append(log(gs / (asc * 1000)))
        // How fast it fades and when it peaks.
        for m in [gm, am] {
            let total = max(m.reduce(0) { $0 + $1 * $1 }, 1e-12)
            let late = m[min(n, pre + 40)..<n].reduce(0) { $0 + $1 * $1 }
            f.append(late / total)
        }
        f.append(Float(gPeakI - pre) / 20)
        f.append(Float(aPeakI - pre) / 20)
        // Spectrum: six octave-ish bands of each sensor (bins of 6.25 Hz).
        for c in [gx, ax] {
            let p = power(c, from: pre - 4)
            let bands = [(1, 2), (3, 4), (5, 8), (9, 16), (17, 32), (33, 63)]
            let tot = max(p.reduce(0, +), 1e-12)
            for (lo, hi) in bands {
                var s: Float = 0
                for b in lo...min(hi, p.count - 1) { s += p[b] }
                f.append((s / tot).squareRoot())
            }
        }
        // Correlation between axes over the first 60 ms: the "shape" of the rotation.
        func corr(_ x: [Float], _ y: [Float]) -> Float {
            var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
            for i in pre..<min(n, pre + 48) { sxy += x[i] * y[i]; sxx += x[i] * x[i]; syy += y[i] * y[i] }
            return sxy / max((sxx * syy).squareRoot(), 1e-9)
        }
        f += [corr(gx[0], gx[1]), corr(gx[0], gx[2]), corr(gx[1], gx[2]),
              corr(gx[0], ax[2]), corr(gx[1], ax[2]), corr(gx[2], ax[0])]
        // Waveform template, normalised by strength.
        for (c, s) in [(gx, gs), (ax, asc)] {
            for k in 0..<3 {
                let origin = alignToPeak ? max(0, min(gPeakI, pre + 40) - 8) : pre - 3
                for j in 0..<templatePoints {
                    let i = min(n - 1, origin + j * templateStep)
                    f.append(c[k][i] / s)
                }
            }
        }
        f.append(Float((lidAngle ?? 115) - 115) / 15)
        return f.map { $0.isFinite ? $0 : 0 }
    }

    private static let cosTable = (0..<128).map { cos(2 * Float.pi * Float($0) / 128) }
    private static let sinTable = (0..<128).map { sin(2 * Float.pi * Float($0) / 128) }

    /// Power spectrum of the sum over axes, 128-point DFT (naive: tiny and only once per tap).
    private static func power(_ c: [[Float]], from start: Int) -> [Float] {
        let n = 128
        var p = [Float](repeating: 0, count: n / 2)
        for axis in c {
            var x = [Float](repeating: 0, count: n)
            for i in 0..<n where start + i < axis.count {
                let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1))
                x[i] = axis[start + i] * w
            }
            for k in 1..<n / 2 {
                var re: Float = 0, im: Float = 0
                for i in 0..<n { let t = (k * i) & (n - 1); re += x[i] * cosTable[t]; im -= x[i] * sinTable[t] }
                p[k] += re * re + im * im
            }
        }
        return p
    }

    // MARK: Audio

    private static let fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!

    /// Spectral fingerprint of the knock: 24 log-spaced band levels (shape only), overall level, centroid, decay.
    static func audio(_ s: [Float], sampleRate: Double, tapStrength: Float) -> [Float] {
        let n = MicRing.segmentLength
        guard s.count == n else { return Array(repeating: 0, count: audioCount) }
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = s[i] * (0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1))) }
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
                for k in 1..<n / 2 { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
            }
        }
        let binHz = sampleRate / Double(n)
        let lo = 150.0, hi = min(18_000.0, sampleRate / 2 * 0.95)
        var bands: [Float] = []
        for b in 0..<audioBands {
            let f0 = lo * pow(hi / lo, Double(b) / Double(audioBands)), f1 = lo * pow(hi / lo, Double(b + 1) / Double(audioBands))
            let k0 = max(1, Int(f0 / binHz)), k1 = max(k0 + 1, Int(f1 / binHz))
            var e: Float = 0
            for k in k0..<min(k1, n / 2) { e += power[k] }
            bands.append(log10(e / Float(k1 - k0) + 1e-12))
        }
        let level = bands.mean
        var f = bands.map { ($0 - level) / 2 }
        f.append((level - log10(max(tapStrength, 1e-3))) / 4)
        var num: Double = 0, den: Double = 0
        for k in 1..<n / 2 { num += Double(power[k]) * log2(Double(k) * binHz); den += Double(power[k]) }
        f.append(Float(den > 0 ? (num / den - 11) / 2 : 0))
        let firstHalf = s[0..<n / 2].reduce(0) { $0 + $1 * $1 }, total = max(s.reduce(0) { $0 + $1 * $1 }, 1e-12)
        f.append(firstHalf / total)
        return f.map { $0.isFinite ? $0 : 0 }
    }

    // MARK: Augmentation

    /// A plausible variant of a recorded tap: shifted a sample or two and with a little sensor noise.
    static func augment(_ x: [Float], shift: Int, noise: Float, rng: inout SplitMix) -> [Float] {
        let n = x.count / 3
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<n {
            let j = min(n - 1, max(0, i - shift))
            for k in 0..<3 { out[i * 3 + k] = x[j * 3 + k] + noise * rng.gaussian() }
        }
        return out
    }
}
