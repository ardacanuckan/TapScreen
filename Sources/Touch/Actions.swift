import AppKit
import ApplicationServices
import CoreGraphics

/// The MacBook's own display: where taps happen.
enum Display {
    static var id: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    /// Global CG coordinates (origin top-left of the main display), as used by CGEvent and Accessibility.
    static var bounds: CGRect { CGDisplayBounds(id) }

    static var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            ?? NSScreen.main
    }

    /// Physical size in millimetres (falls back to a 13.6" panel).
    static var sizeMM: CGSize {
        let s = CGDisplayScreenSize(id)
        return s.width > 50 ? s : CGSize(width: 302, height: 196)
    }

    /// Normalised point (0..1, top-left origin) → global CG point.
    static func cgPoint(_ p: CGPoint) -> CGPoint {
        let b = bounds
        return CGPoint(x: b.minX + p.x * b.width, y: b.minY + p.y * b.height)
    }

    static func cgRect(_ r: CGRect) -> CGRect {
        let b = bounds
        return CGRect(x: b.minX + r.minX * b.width, y: b.minY + r.minY * b.height, width: r.width * b.width, height: r.height * b.height)
    }

    /// Global CG rect → normalised.
    static func normalized(_ r: CGRect) -> CGRect {
        let b = bounds
        return CGRect(x: (r.minX - b.minX) / b.width, y: (r.minY - b.minY) / b.height, width: r.width / b.width, height: r.height / b.height)
    }
}

enum Pointer {
    static func click(at p: CGPoint, returnPointer: Bool) {
        let original = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            ev?.setIntegerValueField(.mouseEventClickState, value: 1)
            ev?.post(tap: .cghidEventTap)
        }
        if returnPointer, let original {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { CGWarpMouseCursorPosition(original) }
        }
    }
}

enum Keys {
    /// Arrow keys need the fn/numpad flags for Spaces switching to work.
    static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        var flags = flags
        if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    /// NX_KEYTYPE_* media keys (sound up 0, down 1, mute 7, play 16, next 17, previous 18).
    static func media(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (key << 16) | (state << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// What a cell does in "zone shortcuts" mode.
struct ZoneAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case smartTouch, openApp, openURL, openFile, missionControl, showDesktop, desktopLeft, desktopRight, playPause, next,
             previous, volumeUp, volumeDown, mute, spotlight, click, shell, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .smartTouch: "Press what's under my finger"
            case .openURL: "Open website…"
            case .openFile: "Open file or folder…"
            case .none: "Nothing"
            case .click: "Click the zone centre"
            case .missionControl: "Mission Control"
            case .showDesktop: "Show Desktop"
            case .desktopLeft: "Desktop left"
            case .desktopRight: "Desktop right"
            case .playPause: "Play / Pause"
            case .next: "Next track"
            case .previous: "Previous track"
            case .volumeUp: "Volume up"
            case .volumeDown: "Volume down"
            case .mute: "Mute"
            case .spotlight: "Spotlight"
            case .openApp: "Open app…"
            case .shell: "Run command…"
            }
        }

        var symbol: String {
            switch self {
            case .smartTouch: "hand.tap"
            case .openURL: "globe"
            case .openFile: "folder"
            case .none: "circle.dashed"
            case .click: "cursorarrow.click"
            case .missionControl: "rectangle.3.group"
            case .showDesktop: "menubar.dock.rectangle"
            case .desktopLeft: "arrow.left.square"
            case .desktopRight: "arrow.right.square"
            case .playPause: "playpause.fill"
            case .next: "forward.fill"
            case .previous: "backward.fill"
            case .volumeUp: "speaker.wave.3.fill"
            case .volumeDown: "speaker.wave.1.fill"
            case .mute: "speaker.slash.fill"
            case .spotlight: "magnifyingglass"
            case .openApp: "app.badge"
            case .shell: "terminal"
            }
        }

        var needsArgument: Bool { [.openApp, .openURL, .openFile, .shell].contains(self) }
    }

    /// Short label for a zone tile: the app, site or file name when there is one.
    var label: String {
        let arg = argument.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .smartTouch: return "Press what's there"
        case .openApp, .openFile:
            guard !arg.isEmpty else { return kind == .openApp ? "Choose an app" : "Choose a file" }
            return FileManager.default.displayName(atPath: arg).replacingOccurrences(of: ".app", with: "")
        case .openURL:
            guard !arg.isEmpty else { return "Enter a website" }
            return URL(string: Self.normalizedURL(arg))?.host ?? arg
        case .shell: return arg.isEmpty ? "Enter a command" : arg
        default: return kind.title
        }
    }

    /// The app or file's own icon, when the zone opens one.
    var fileIcon: NSImage? {
        guard kind == .openApp || kind == .openFile, argument.hasPrefix("/"), FileManager.default.fileExists(atPath: argument) else { return nil }
        return NSWorkspace.shared.icon(forFile: argument)
    }

    static func normalizedURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("://") ? t : "https://\(t)"
    }

    var id = UUID()
    var kind: Kind
    var argument = ""

    init(_ kind: Kind, _ argument: String = "") { self.kind = kind; self.argument = argument }

    static func defaults(for grid: Grid) -> [ZoneAction] {
        let base: [Kind]
        switch (grid.cols, grid.rows) {
        case (2, 2): base = [.desktopLeft, .desktopRight, .playPause, .missionControl]
        case (3, 2): base = [.desktopLeft, .missionControl, .desktopRight, .previous, .playPause, .next]
        case (3, 3): base = [.desktopLeft, .missionControl, .desktopRight, .previous, .playPause, .next, .volumeDown, .showDesktop, .volumeUp]
        default: base = [.desktopLeft, .missionControl, .spotlight, .desktopRight, .previous, .playPause, .next, .mute, .volumeDown, .showDesktop, .none, .volumeUp]
        }
        return (0..<grid.count).map { ZoneAction(base.indices.contains($0) ? base[$0] : .none) }
    }

    @MainActor
    func run(cell: Int, grid: Grid, returnPointer: Bool) {
        switch kind {
        case .none, .smartTouch: break   // smart touch is handled by the engine
        case .openURL:
            if let url = URL(string: Self.normalizedURL(argument)), !argument.isEmpty { NSWorkspace.shared.open(url) }
        case .openFile:
            if !argument.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: argument)) }
        case .click: Pointer.click(at: Display.cgPoint(grid.center(cell)), returnPointer: returnPointer)
        case .missionControl: Self.missionControl(nil)
        case .showDesktop: Self.missionControl("1")
        case .desktopLeft: Keys.press(123, flags: .maskControl)
        case .desktopRight: Keys.press(124, flags: .maskControl)
        case .playPause: Keys.media(16)
        case .next: Keys.media(17)
        case .previous: Keys.media(18)
        case .volumeUp: Keys.media(0)
        case .volumeDown: Keys.media(1)
        case .mute: Keys.media(7)
        case .spotlight: Keys.press(49, flags: .maskCommand)
        case .openApp: Self.openApp(argument)
        case .shell:
            guard !argument.isEmpty else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", argument.replacingOccurrences(of: "{zone}", with: "\(cell + 1)")]
            try? p.run()
        }
    }

    private static func missionControl(_ arg: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        if let arg { p.arguments = [arg] }
        try? p.run()
    }

    private static func openApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let fm = FileManager.default
        let candidates = [trimmed, "/Applications/\(trimmed).app", "/System/Applications/\(trimmed).app",
                          "/System/Applications/Utilities/\(trimmed).app", "\(NSHomeDirectory())/Applications/\(trimmed).app"]
        if let path = candidates.first(where: { $0.hasSuffix(".app") && fm.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", trimmed]
            try? p.run()
        }
    }
}
