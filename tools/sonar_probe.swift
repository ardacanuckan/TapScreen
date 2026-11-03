import Accelerate
import AVFoundation
import Foundation

// Sonar feasibility probe: can this MacBook's speakers + mic see a finger moving near the display?
//
//   sonar_probe sweep                 1 s of silence, then 1 s tones at 17–22.5 kHz: received level vs noise floor
//   sonar_probe track <fL> <fR>       left speaker plays fL, right plays fR; spoken cues ask you to move your finger.
//                                     Phase of each echo → change in path length (speaker → finger → mic), in mm.
//
// Uses two engines (speakers and mic are separate devices). Prints a report and writes CSV next to the binary.

final class Recorder {
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private(set) var samples: [Float] = []
    var rate: Double { engine.inputNode.outputFormat(forBus: 0).sampleRate }

    private(set) var configChanges = 0

    func start() throws {
        // If the device switches sample rate (another app, or our own output starting), the tap stops silently.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configChanges += 1
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let d = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            self.lock.withLock { self.samples.append(contentsOf: UnsafeBufferPointer(start: d, count: n)) }
        }
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }
}

final class Player {
    let engine = AVAudioEngine()
    /// (left Hz, right Hz) for a time in seconds since start; 0 = silent.
    var schedule: (Double) -> (Double, Double) = { _ in (0, 0) }
    private var n: Int64 = 0
    private var phase = (0.0, 0.0)

    func start() throws {
        let fs = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 2)!
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let l = bufs[0].mData!.assumingMemoryBound(to: Float.self), r = bufs[1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) {
                let t = Double(self.n) / fs
                let (fl, fr) = self.schedule(t)
                // Short fades at the start of each segment avoid audible clicks.
                let a = 0.35 * min(1, (t - floor(t)) * 50)
                self.phase.0 += 2 * .pi * fl / fs
                self.phase.1 += 2 * .pi * fr / fs
                l[i] = fl > 0 ? Float(a * sin(self.phase.0)) : 0
                r[i] = fr > 0 ? Float(a * sin(self.phase.1)) : 0
                self.n += 1
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        try engine.start()
    }

    func stop() { engine.stop() }
}

/// Complex baseband of `x` at frequency f, decimated to `outRate` by block averaging.
func baseband(_ x: [Float], fs: Double, f: Double, outRate: Double = 1000) -> [DSPComplex] {
    let block = Int(fs / outRate)
    var out: [DSPComplex] = []
    out.reserveCapacity(x.count / block)
    let w = 2 * Double.pi * f / fs
    var i = 0
    while i + block <= x.count {
        var re = 0.0, im = 0.0
        for k in i..<(i + block) {
            let p = w * Double(k)
            re += Double(x[k]) * cos(p)
            im -= Double(x[k]) * sin(p)
        }
        out.append(DSPComplex(real: Float(re / Double(block)), imag: Float(im / Double(block))))
        i += block
    }
    return out
}

func mag(_ z: DSPComplex) -> Float { (z.real * z.real + z.imag * z.imag).squareRoot() }
func db(_ x: Float) -> String { String(format: "%6.1f dB", 20 * log10(max(x, 1e-9))) }

func run(seconds: Double, player: Player, cues: [(Double, String)]) throws -> ([Float], Double) {
    let rec = Recorder()
    try rec.start()
    // Let the output engine start (and any device reconfiguration settle) before the schedule's clock matters.
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try player.start()
    let t0 = Date()
    var pending = cues
    while Date().timeIntervalSince(t0) < seconds {
        if let c = pending.first, Date().timeIntervalSince(t0) >= c.0 {
            pending.removeFirst()
            print(String(format: "[%4.1fs] %@", c.0, c.1))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-r", "190", c.1]
            try? p.run()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    player.stop()
    let rate = rec.rate
    let x = rec.stop()
    let expected = Int(seconds * rate)
    print("mic \(Int(rate)) Hz, got \(String(format: "%.1f", Double(x.count) / rate)) s of \(String(format: "%.1f", seconds)) s, config changes: \(rec.configChanges)")
    if x.count < expected * 8 / 10 { print("RECORDING INCOMPLETE: rerun"); exit(3) }
    // The recording started 0.3 s before playback: drop that so t=0 matches the schedule.
    return (Array(x.dropFirst(Int(0.3 * rate))), rate)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: sonar_probe sweep | track <fL> <fR>"); exit(2) }

switch args[1] {
case "sweep":
    let freqs: [Double] = [17000, 18000, 19000, 20000, 20500, 21000, 21500, 22000, 22500]
    let p = Player()
    p.schedule = { t in
        let i = Int(t) - 1
        guard i >= 0, i < freqs.count else { return (0, 0) }
        return (freqs[i], freqs[i])
    }
    let (x, fs) = try run(seconds: Double(freqs.count) + 1.6, player: p, cues: [])
    let peak = x.map(abs).max() ?? 0
    if peak == 0 { print("MIC SILENT: no microphone permission or no input"); exit(1) }
    // Noise floor: first second (silence). Tone level: middle 0.6 s of its slot. Audio latency is ~20–60 ms.
    func level(_ f: Double, from: Double, to: Double) -> Float {
        let a = Int(from * fs), b = min(x.count, Int(to * fs))
        guard b > a else { return 0 }
        let z = baseband(Array(x[a..<b]), fs: fs, f: f, outRate: 50)
        return z.map(mag).reduce(0, +) / Float(max(z.count, 1))
    }
    print("\n  freq      tone        floor       SNR")
    for (i, f) in freqs.enumerated() {
        let tone = level(f, from: Double(i + 1) + 0.25, to: Double(i + 1) + 0.85)
        let floor = level(f, from: 0.15, to: 0.85)
        print(String(format: "  %5.1f kHz %@  %@  %6.1f dB", f / 1000, db(tone), db(floor), 20 * log10(max(tone, 1e-9) / max(floor, 1e-9))))
    }

case "track":
    guard args.count >= 4, let fl = Double(args[2]), let fr = Double(args[3]) else { print("track <fL> <fR>"); exit(2) }
    let p = Player()
    p.schedule = { _ in (fl, fr) }
    let segments: [(Double, Double, String)] = [(0, 5, "still"), (5, 14, "left-right"), (14, 23, "up-down"), (23, 28, "hover")]
    let cues: [(Double, String)] = [
        (0.3, "Keep your hands still, away from the screen."),
        (5, "Now slide one finger left and right across the screen. Slowly."),
        (14, "Now slide up and down."),
        (23, "Now hold your hand still, close to the screen."),
        (27.6, "Done."),
    ]
    let (x, fs) = try run(seconds: 28.5, player: p, cues: cues)
    if (x.map(abs).max() ?? 0) == 0 { print("MIC SILENT"); exit(1) }
    let rate = 1000.0
    var csv = "t,segment"
    var series: [(name: String, dyn: [Float], path: [Float])] = []
    for (name, f) in [("L", fl), ("R", fr)] {
        let z = baseband(x, fs: fs, f: f, outRate: rate)
        // Static paths (direct sound, desk, lid) = slow moving average; what's left moves.
        let win = Int(0.35 * rate)
        var dyn = [Float](repeating: 0, count: z.count), path = dyn
        var sr: Float = 0, si: Float = 0
        var q: [DSPComplex] = []
        var dz = [DSPComplex](repeating: .init(real: 0, imag: 0), count: z.count)
        for (k, v) in z.enumerated() {
            q.append(v); sr += v.real; si += v.imag
            if q.count > win { sr -= q[0].real; si -= q[0].imag; q.removeFirst() }
            let c = max(0, k - win / 2)
            if k >= win / 2 {
                dz[c] = DSPComplex(real: z[c].real - sr / Float(q.count), imag: z[c].imag - si / Float(q.count))
            }
        }
        // Smooth to ~40 Hz bandwidth, then unwrap phase → path change. λ = c / f.
        let lambdaMM = Float(343_000 / f)
        var prev: Float?
        var acc: Float = 0
        var sm = DSPComplex(real: 0, imag: 0)
        for k in 0..<dz.count {
            sm.real += (dz[k].real - sm.real) * 0.25
            sm.imag += (dz[k].imag - sm.imag) * 0.25
            dyn[k] = mag(sm)
            let ph = atan2(sm.imag, sm.real)
            if let pv = prev {
                var d = ph - pv
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                acc += -d / (2 * .pi) * lambdaMM
            }
            prev = ph
            path[k] = acc
        }
        series.append((name, dyn, path))
        csv += ",dyn\(name),path\(name)mm"
        let baseLevel = z.map(mag).reduce(0, +) / Float(max(z.count, 1))
        print(String(format: "%@ %5.1f kHz received level %@", name, f / 1000, db(baseLevel)))
    }
    csv += "\n"
    let n = min(series[0].dyn.count, series[1].dyn.count)
    for k in stride(from: 0, to: n, by: 10) {
        let t = Double(k) / rate
        let seg = segments.first { t >= $0.0 && t < $0.1 }?.2 ?? ""
        csv += String(format: "%.2f,%@,%g,%.2f,%g,%.2f\n", t, seg, series[0].dyn[k], series[0].path[k], series[1].dyn[k], series[1].path[k])
    }
    let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("sonar_track.csv")
    try? csv.write(to: out, atomically: true, encoding: .utf8)

    // Per segment: motion energy vs still, how far each path moved, and how L and R moves relate.
    func range(_ s: (Double, Double, String)) -> Range<Int> { Int((s.0 + 0.4) * rate)..<min(n, Int((s.1 - 0.2) * rate)) }
    let still = range(segments[0])
    let stillDyn = series.map { s in s.dyn[still].reduce(0, +) / Float(still.count) }
    print("\n  segment      motion L    motion R    path travel L   path travel R   corr(dL,dR)")
    for seg in segments {
        let r = range(seg)
        guard r.count > 10 else { continue }
        var parts: [String] = []
        for (i, s) in series.enumerated() {
            let m = s.dyn[r].reduce(0, +) / Float(r.count)
            parts.append(String(format: "%+6.1f dB", 20 * log10(max(m, 1e-12) / max(stillDyn[i], 1e-12))))
        }
        var travel: [Float] = [0, 0]
        var dl: [Float] = [], dr: [Float] = []
        for k in stride(from: r.lowerBound + 20, to: r.upperBound, by: 20) {
            let a = series[0].path[k] - series[0].path[k - 20], b = series[1].path[k] - series[1].path[k - 20]
            travel[0] += abs(a); travel[1] += abs(b); dl.append(a); dr.append(b)
        }
        let ml = dl.mean, mr = dr.mean
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in dl.indices { sxy += (dl[i] - ml) * (dr[i] - mr); sxx += (dl[i] - ml) * (dl[i] - ml); syy += (dr[i] - mr) * (dr[i] - mr) }
        let corr = sxy / max((sxx * syy).squareRoot(), 1e-9)
        print(String(format: "  %-11@ %@   %@   %8.0f mm     %8.0f mm       %+.2f", seg.2, parts[0], parts[1], travel[0], travel[1], corr))
    }
    // Coarse timeline: cumulative path per half second.
    print("\n  t(s)  seg          pathL(mm)  pathR(mm)  motionL  motionR")
    for k in stride(from: 0, to: n, by: 500) {
        let t = Double(k) / rate
        let seg = segments.first { t >= $0.0 && t < $0.1 }?.2 ?? ""
        print(String(format: "  %4.1f  %-11@ %9.0f  %9.0f  %@ %@", t, seg, series[0].path[k], series[1].path[k],
                     db(series[0].dyn[k] / max(stillDyn[0], 1e-12)), db(series[1].dyn[k] / max(stillDyn[1], 1e-12))))
    }
    print("\nCSV: \(out.path)")

default:
    print("usage: sonar_probe sweep | track <fL> <fR>")
}

extension Array where Element == Float {
    var mean: Float { isEmpty ? 0 : reduce(0, +) / Float(count) }
}
