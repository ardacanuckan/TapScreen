import AppKit
// Renders the app icon set: a graphite tile with a tapping hand.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = size * scale
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let inset = r.insetBy(dx: r.width * 0.09, dy: r.height * 0.09)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)
        // Plain graphite tile with a white hand: quiet, like the Mac's own utilities.
        NSColor(white: 0.16, alpha: 1).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        path.lineWidth = max(1, inset.width * 0.008)
        path.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: inset.width * 0.46, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: inset.midX - s.width / 2, y: inset.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
