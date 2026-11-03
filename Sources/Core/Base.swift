import CoreGraphics
import Foundation
import os

/// Seconds on the mach clock, the same clock as IOHID report timestamps, CGEvent timestamps and audio host time.
enum MachClock {
    static let tick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    static func now() -> Double { Double(mach_absolute_time()) * tick }
    static func seconds(hostTime: UInt64) -> Double { Double(hostTime) * tick }
}

enum Log {
    static let sensor = Logger(subsystem: "app.tapscreen", category: "sensor")
    static let engine = Logger(subsystem: "app.tapscreen", category: "engine")
    static let ml = Logger(subsystem: "app.tapscreen", category: "ml")
}

/// A float array stored as base64 in JSON, so datasets and models stay small on disk.
struct Floats: Codable, Equatable {
    var v: [Float]
    init(_ v: [Float]) { self.v = v }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Data(base64Encoded: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad base64"))
        }
        v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(v.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString())
    }
}

/// The screen split into cells. Points are normalised: (0,0) top-left, (1,1) bottom-right.
struct Grid: Codable, Hashable {
    var cols: Int
    var rows: Int

    init(_ cols: Int, _ rows: Int) { self.cols = cols; self.rows = rows }

    var count: Int { cols * rows }
    var label: String { "\(cols)×\(rows)" }

    static let presets = [Grid(2, 2), Grid(3, 2), Grid(3, 3), Grid(4, 3)]

    func cell(at p: CGPoint) -> Int {
        let c = min(cols - 1, max(0, Int(p.x * CGFloat(cols))))
        let r = min(rows - 1, max(0, Int(p.y * CGFloat(rows))))
        return r * cols + c
    }

    func rect(_ i: Int) -> CGRect {
        let w = 1 / CGFloat(cols), h = 1 / CGFloat(rows)
        return CGRect(x: CGFloat(i % cols) * w, y: CGFloat(i / cols) * h, width: w, height: h)
    }

    func center(_ i: Int) -> CGPoint { let r = rect(i); return CGPoint(x: r.midX, y: r.midY) }

    /// The same cell layout laid over any rectangle (used by zoom refinement).
    func rect(_ i: Int, in outer: CGRect) -> CGRect {
        let r = rect(i)
        return CGRect(x: outer.minX + r.minX * outer.width, y: outer.minY + r.minY * outer.height,
                      width: r.width * outer.width, height: r.height * outer.height)
    }
}

extension Array where Element == Float {
    var sum: Float { reduce(0, +) }
    var mean: Float { isEmpty ? 0 : sum / Float(count) }
}

/// Small deterministic RNG so training and cross-validation are reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        let u1 = max(Float.random(in: 0..<1, using: &self), 1e-7), u2 = Float.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
