import AVFoundation
import Foundation

/// Optional microphone fusion: keeps the last second of built-in mic audio so each tap can also be "heard".
/// The knock travels through the lid and chassis, and its ring changes with where it lands.
/// Only runs while the user turns it on (macOS shows the orange mic dot then).
final class MicRing {
    static let segmentLength = 2048

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring: [Float] = []
    private var head = 0
    private var filled = 0
    private var endTime = 0.0   // mach seconds of the sample just after the newest one
    private(set) var sampleRate = 48_000.0
    private(set) var running = false

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func start(completion: @escaping (Bool) -> Void) {
        guard !running else { return completion(true) }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { return completion(false) }
                completion(self.startEngine())
            }
        }
    }

    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }
        sampleRate = format.sampleRate
        lock.withLock {
            ring = [Float](repeating: 0, count: Int(sampleRate))
            head = 0
            filled = 0
        }
        // Large buffers: fewer wake-ups. The tap result waits for the IMU window anyway.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.append(buffer, time)
        }
        do {
            try engine.start()
            running = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            Log.sensor.error("Mic start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let start = time.isHostTimeValid ? MachClock.seconds(hostTime: time.hostTime) : MachClock.now() - Double(n) / sampleRate
        lock.withLock {
            let cap = ring.count
            guard cap > 0 else { return }
            for i in 0..<n {
                ring[head] = data[i]
                head = (head + 1) % cap
            }
            filled = min(cap, filled + n)
            endTime = start + Double(n) / sampleRate
        }
    }

    /// Audio around a tap at mach time `t0`: finds the knock's onset within ±60 ms and returns
    /// `segmentLength` samples starting just before it. Nil if the audio doesn't cover it yet.
    func segment(around t0: Double) -> [Float]? {
        lock.withLock { () -> [Float]? in
            let cap = ring.count
            guard cap > 0, filled > 0 else { return nil }
            let sr = sampleRate
            // Index (0 = oldest) of a mach time.
            func index(_ t: Double) -> Int { filled - Int(((endTime - t) * sr).rounded()) }
            let searchFrom = index(t0 - 0.06), searchTo = index(t0 + 0.06)
            guard searchFrom >= 0, searchTo <= filled else { return nil }
            func sample(_ i: Int) -> Float { ring[(head - filled + i + 2 * cap) % cap] }
            // Onset = largest energy jump over 1 ms frames.
            let frame = max(16, Int(sr / 1000))
            var best = searchFrom, bestJump: Float = -1, prevEnergy: Float = 0
            var i = searchFrom
            while i + frame <= min(searchTo, filled) {
                var e: Float = 0
                for k in 0..<frame { let s = sample(i + k); e += s * s }
                if e - prevEnergy > bestJump { bestJump = e - prevEnergy; best = i }
                prevEnergy = e
                i += frame
            }
            let start = max(0, best - 96)
            guard start + Self.segmentLength <= filled else { return nil }
            return (0..<Self.segmentLength).map { sample(start + $0) }
        }
    }
}
