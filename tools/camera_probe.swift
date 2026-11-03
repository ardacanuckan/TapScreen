import AppKit
import AVFoundation
import CoreImage
import Vision

// Camera feasibility probe: can the built-in camera (and its Desk View) see the fingertip when you touch the screen?
//
//   camera_probe <outdir>
//
// Runs both cameras at once if macOS allows it, detects hands with Vision, and asks you (spoken cues) to touch
// and hold 9 spots on the screen. Prints, per spot and camera, how often a hand was found and where the index
// fingertip was; saves one annotated frame per spot and camera to <outdir>.

struct Obs {
    let t: Double
    let camera: String
    let hands: Int
    let tip: CGPoint?        // index fingertip, normalised image coords (Vision: origin bottom-left)
    let tipConfidence: Float
}

final class Cam: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let name: String
    let session = AVCaptureSession()
    let queue: DispatchQueue
    var frames = 0
    var lastProcessed = 0.0
    var onObs: ((Obs, CVPixelBuffer, [CGPoint]) -> Void)?
    let start: Date
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    init?(device: AVCaptureDevice, name: String, start: Date) {
        self.name = name
        self.start = start
        queue = DispatchQueue(label: "cam.\(name)")
        super.init()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.beginConfiguration()
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { return nil }
        session.addOutput(out)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        let t = Date().timeIntervalSince(start)
        guard t - lastProcessed >= 0.1, let px = CMSampleBufferGetImageBuffer(sb) else { return }  // ~10 Hz is enough here
        lastProcessed = t
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: .up)
        try? handler.perform([request])
        let hands = request.results ?? []
        // The hand whose index tip is most confident.
        var best: (CGPoint, Float)?
        var allPoints: [CGPoint] = []
        for h in hands {
            if let pts = try? h.recognizedPoints(.all) { allPoints += pts.values.filter { $0.confidence > 0.3 }.map(\.location) }
            if let tip = try? h.recognizedPoint(.indexTip), tip.confidence > 0.3, tip.confidence > (best?.1 ?? 0) {
                best = (tip.location, tip.confidence)
            }
        }
        onObs?(Obs(t: t, camera: name, hands: hands.count, tip: best?.0, tipConfidence: best?.1 ?? 0), px, allPoints)
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "camtest")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
sem.wait()
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { print("NO CAMERA PERMISSION"); exit(1) }

let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .deskViewCamera]
let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
let start = Date()
var cams: [Cam] = []
for d in devices {
    let name = d.deviceType == .deskViewCamera ? "deskview" : "front"
    if let c = Cam(device: d, name: name, start: start) { cams.append(c) } else { print("could not open \(name)") }
}

// Spots: (label, normalised screen x, y) with y down.
let spots: [(String, Double, Double)] = [
    ("top left", 0.12, 0.12), ("top middle", 0.5, 0.12), ("top right", 0.88, 0.12),
    ("middle left", 0.12, 0.5), ("center", 0.5, 0.5), ("middle right", 0.88, 0.5),
    ("bottom left", 0.12, 0.88), ("bottom middle", 0.5, 0.88), ("bottom right", 0.88, 0.88),
]
let hold = 3.6, lead = 4.0
func spotIndex(_ t: Double) -> Int? {
    let i = Int((t - lead) / hold)
    let within = (t - lead) - Double(i) * hold
    return t >= lead && i < spots.count && within > 1.4 ? i : nil   // skip the first 1.4 s of each: hand still moving
}

let lock = NSLock()
var obs: [Obs] = []
var saved = Set<String>()
let ci = CIContext()
for c in cams {
    c.onObs = { o, px, points in
        lock.withLock { obs.append(o) }
        // One annotated frame per spot and camera, taken ~2.4 s into the hold.
        guard let i = spotIndex(o.t), (o.t - lead) - Double(i) * hold > 2.3 else { return }
        let key = "\(i)-\(o.camera)"
        guard lock.withLock({ saved.insert(key).inserted }) else { return }
        let img = CIImage(cvPixelBuffer: px)
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        let w = 640, h = Int(Double(cg.height) / Double(cg.width) * 640)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.systemGreen.cgColor)
        for p in points { ctx.fillEllipse(in: CGRect(x: p.x * CGFloat(w) - 3, y: p.y * CGFloat(h) - 3, width: 6, height: 6)) }
        if let tip = o.tip {
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fillEllipse(in: CGRect(x: tip.x * CGFloat(w) - 6, y: tip.y * CGFloat(h) - 6, width: 12, height: 12))
        }
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        let name = String(format: "%d-%@-%@.jpg", i + 1, spots[i].0.replacingOccurrences(of: " ", with: "_"), o.camera)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: outDir.appendingPathComponent(name))
    }
}
for c in cams { c.session.startRunning() }
RunLoop.current.run(until: Date().addingTimeInterval(1.5))
for c in cams { print("\(c.name): \(c.frames) frames in first 1.5 s, running \(c.session.isRunning)") }

func say(_ s: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-r", "200", s]
    try? p.run()
}
say("Hands away from the screen.")
var next = 0
while Date().timeIntervalSince(start) < lead + hold * Double(spots.count) + 0.5 {
    let t = Date().timeIntervalSince(start)
    if next < spots.count, t >= lead + Double(next) * hold - 0.3 {
        say(next == 0 ? "Touch and hold the \(spots[next].0) of the screen." : spots[next].0)
        next += 1
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
say("Done.")
for c in cams { c.session.stopRunning() }

let all = lock.withLock { obs }
print("\nframes received: " + cams.map { "\($0.name) \($0.frames)" }.joined(separator: ", "))
print("\n  spot            camera     hand found   tip found   tip x     tip y     spread")
for (i, s) in spots.enumerated() {
    for c in cams {
        let o = all.filter { $0.camera == c.name && spotIndex($0.t) == i }
        guard !o.isEmpty else { print(String(format: "  %-15@ %-9@  no frames", s.0, c.name)); continue }
        let tips = o.compactMap(\.tip)
        let hand = Double(o.filter { $0.hands > 0 }.count) / Double(o.count)
        let tipRate = Double(tips.count) / Double(o.count)
        if tips.isEmpty {
            print(String(format: "  %-15@ %-9@  %5.0f%%       %5.0f%%", s.0, c.name, hand * 100, tipRate * 100))
        } else {
            let mx = tips.map(\.x).reduce(0, +) / CGFloat(tips.count), my = tips.map(\.y).reduce(0, +) / CGFloat(tips.count)
            let sp = tips.map { hypot($0.x - mx, $0.y - my) }.reduce(0, +) / CGFloat(tips.count)
            print(String(format: "  %-15@ %-9@  %5.0f%%       %5.0f%%    %.3f     %.3f     %.3f", s.0, c.name, hand * 100, tipRate * 100, mx, my, sp))
        }
    }
}
print("\nstill phase (no hand expected): " + cams.map { c in
    let o = all.filter { $0.camera == c.name && $0.t > 1.5 && $0.t < lead - 0.3 }
    return "\(c.name) hand in \(o.filter { $0.hands > 0 }.count)/\(o.count) frames"
}.joined(separator: ", "))
print("frames saved to \(outDir.path)")
