import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
enum TapScreenMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if CommandLine.arguments.contains("--ax-test") { MainActor.assumeIsolated { SelfTest.accessibility() } }
        let app = NSApplication.shared
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            app.setActivationPolicy(.accessory)
            MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments[i + 1]) }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        // A normal app: Dock icon, ⌘-Tab, menus. (The menu bar icon can hide behind the notch on a full menu bar.)
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var studio: NSWindow?
    private var bag: Set<AnyCancellable> = []
    private var flashWork: DispatchWorkItem?
    private let engine = Engine.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuView(openStudio: { [weak self] tab in self?.showStudio(tab) }))

        engine.$settings.map(\.enabled).removeDuplicates().sink { [weak self] _ in self?.refreshIcon(flash: false) }.store(in: &bag)
        engine.$model.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in self?.refreshIcon(flash: false) }.store(in: &bag)
        engine.tapped.sink { [weak self] _ in self?.refreshIcon(flash: true) }.store(in: &bag)
        HotKey.shared.action = { [weak self] in self?.engine.toggle() }
        engine.boot()
        refreshIcon(flash: false)
        NSApp.mainMenu = makeMenu()

        if !CommandLine.arguments.contains("--background") { showStudio(engine.model == nil ? .calibrate : .home) }
    }

    /// Clicking the Dock icon (or opening the app again) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStudio(engine.model == nil ? .calibrate : .home) }
        return true
    }

    /// Closing the window keeps tap detection running; quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        submenu("TapScreen", [
            item("About TapScreen", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(openSettings), ",", target: self),
            item("Turn On/Off", #selector(toggleEnabled), "", target: self),
            .separator(),
            item("Hide TapScreen", #selector(NSApplication.hide(_:)), "h"),
            item("Quit TapScreen", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "Z"), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    @objc private func openSettings() { showStudio(.settings) }
    @objc private func toggleEnabled() { engine.toggle() }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        // Right-click (or ctrl-click) toggles without opening anything.
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            engine.toggle()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshIcon(flash: Bool) {
        guard let button = statusItem?.button else { return }
        let on = engine.settings.enabled
        let name = flash ? "hand.tap.fill" : (on ? "hand.tap" : "hand.raised.slash")
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: flash ? .bold : .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "TapScreen")?.withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = on || flash ? 1 : 0.55
        button.toolTip = on ? "TapScreen: on (⌃⌥T)" : "TapScreen: off (⌃⌥T)"
        if flash {
            flashWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshIcon(flash: false) }
            flashWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func showStudio(_ tab: StudioTab) {
        popover.performClose(nil)
        StudioState.shared.tab = tab
        if studio == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "TapScreen"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 600)
            w.center()
            w.delegate = self
            // Come to the Space the user is on, also over full-screen apps.
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            studio = w
        }
        // The SwiftUI tree only exists while the window is open, so a closed studio costs nothing.
        if studio?.contentView is NSHostingView<StudioView> == false { studio?.contentView = NSHostingView(rootView: StudioView()) }
        NSApp.activate(ignoringOtherApps: true)
        studio?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === studio else { return }
        DispatchQueue.main.async { w.contentView = NSView() }
    }
}

/// ⌃⌥T toggles TapScreen from anywhere (Carbon hot keys need no permission).
@MainActor
final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? register() : unregister()
        }
    }

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x444B_4E54), id: 1)  // 'DKNT'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

/// `TapScreen --selftest`: reads the motion sensor for 3 seconds and prints what it sees (for troubleshooting).
enum SelfTest {
    /// `TapScreen --ax-test`: lists what Smart Touch can find in the frontmost app right now.
    @MainActor
    static func accessibility() -> Never {
        // The first answer in a fresh process can arrive late; give macOS a moment.
        _ = AXIsProcessTrusted()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("accessibility trusted:", AXIsProcessTrusted())
        print("frontmost:", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
        for budget in [0.15, 0.5] {
            let t0 = Date()
            let targets = SmartTouch.collect(budget: budget)
            print(String(format: "budget %.2f s: %d targets in %.0f ms", budget, targets.count, Date().timeIntervalSince(t0) * 1000))
            if budget == 0.5 {
                var roles: [String: Int] = [:]
                for t in targets { roles[t.role, default: 0] += 1 }
                print("roles:", roles.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                for t in targets.prefix(25) {
                    print(String(format: "  %-16@ %-28@ %4.0f,%4.0f %4.0f×%-4.0f", t.role, String(t.title.prefix(28)), t.frame.minX, t.frame.minY, t.frame.width, t.frame.height))
                }
            }
        }
        exit(0)
    }

    static func run() -> Never {
        let imu = IMUReader(), det = TapDetector()
        var taps: [String] = []
        let t0 = MachClock.now()
        det.onWindow = { w in taps.append(String(format: "%.2fs peak %.2f pre %.2f", w.t0 - t0, w.peakGyro, w.preMotion)) }
        imu.onSample = { k, t, v in det.ingest(k, t, v) }
        imu.start()
        Thread.sleep(forTimeInterval: 6)
        let c = imu.takeCounts()
        let s = det.scope()
        print("""
        accel: \(c.accel / 6) Hz
        gyro:  \(c.gyro / 6) Hz
        lid:   \(imu.lidAngle.map { "\($0)°" } ?? "—")
        idle twist noise: \(String(format: "%.3f", s.noise)) °/s, trigger \(String(format: "%.2f", s.threshold)) °/s
        taps:  \(taps.count) \(taps.joined(separator: " | "))
        error: \(imu.error ?? "none")
        """)
        imu.stop()
        exit(c.gyro > 0 ? 0 : 1)
    }
}
