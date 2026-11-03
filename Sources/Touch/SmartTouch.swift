import AppKit
import ApplicationServices

/// Something on screen a tap could have meant: a button, link, field, tab, menu bar item or Dock icon.
struct Target: Identifiable {
    let id = UUID()
    let element: AXUIElement
    let frame: CGRect          // global CG coordinates
    let role: String
    let title: String
    let pid: pid_t
    var score: Double = 0

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var symbol: String {
        switch role {
        case "AXLink": "link"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": "character.cursor.ibeam"
        case "AXCheckBox": "checkmark.square"
        case "AXRadioButton", "AXTab": "smallcircle.filled.circle"
        case "AXPopUpButton", "AXMenuButton": "chevron.up.chevron.down"
        case "AXMenuBarItem": "menubar.rectangle"
        case "AXDockItem": "dock.rectangle"
        default: "hand.point.up.left"
        }
    }

    /// Press through Accessibility where it makes sense (no pointer jump); click everything else.
    @MainActor
    func activate(returnPointer: Bool) {
        let pressable: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                      "AXMenuBarItem", "AXDockItem", "AXTab", "AXDisclosureTriangle"]
        if pressable.contains(role), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        Pointer.click(at: center, returnPointer: returnPointer)
    }
}

/// Finds clickable things on the built-in display through the Accessibility tree, and scores them against
/// where the model thinks the tap landed.
enum SmartTouch {
    static let clickableRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                              "AXMenuButton", "AXMenuBarItem", "AXDockItem", "AXTextField", "AXTextArea",
                                              "AXComboBox", "AXTab", "AXDisclosureTriangle", "AXIncrementor", "AXSlider",
                                              "AXCell", "AXRow", "AXImage", "AXStaticText"]
    /// Roles that only count when they say they can be pressed (web content uses them for clickable things).
    static let pressOnlyRoles: Set<String> = ["AXImage", "AXStaticText", "AXCell", "AXRow", "AXGroup"]

    private static let chromium = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser",
                                   "com.vivaldi", "com.operasoftware"]

    /// Collects targets from the frontmost app's windows, its menu bar, and the Dock. Bounded in time and size.
    static func collect(budget: TimeInterval = 0.15, limit: Int = 4000) -> [Target] {
        let deadline = Date().addingTimeInterval(budget)
        let screen = Display.bounds
        var roots: [AXUIElement] = []
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.05)
            // Chromium browsers and Electron apps only build their tree when asked.
            let id = app.bundleIdentifier ?? ""
            if chromium.contains(where: id.hasPrefix) {
                AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let windows = copy(ax, kAXWindowsAttribute) as? [AXUIElement] { roots += windows.prefix(4) }
            if let menu = copy(ax, kAXMenuBarAttribute) { roots.append(menu as! AXUIElement) }
        }
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let ax = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.05)
            if let kids = copy(ax, kAXChildrenAttribute) as? [AXUIElement] { roots += kids }
        }

        var out: [Target] = []
        var queue = roots[...]
        var visited = 0
        let attrs = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
                     kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as CFArray
        while let el = queue.popFirst(), visited < limit, Date() < deadline {
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [AnyObject], v.count == 7 else { continue }
            let role = v[0] as? String ?? ""
            let frame = rect(v[1], v[2])
            if let frame, frame.width > 0, !frame.intersects(screen), role != "AXMenuBar", role != "AXApplication" { continue }
            if let frame, clickableRoles.contains(role) || pressOnlyRoles.contains(role), frame.width >= 6, frame.height >= 6,
               frame.width < screen.width * 0.6 || frame.height < screen.height * 0.25, screen.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                let ok = !pressOnlyRoles.contains(role) || canPress(el)
                if ok {
                    let title = [v[4], v[5], v[6]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
                    var pid: pid_t = 0
                    AXUIElementGetPid(el, &pid)
                    out.append(Target(element: el, frame: frame, role: role, title: String(title.prefix(40)), pid: pid))
                }
            }
            if role == "AXMenu" { continue }  // closed menus' items aren't on screen
            if let kids = v[3] as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return innermost(out)
    }

    /// Scores targets by the tap's probability density at their nearest point (a Gaussian bump around where taps in
    /// each cell really land, weighted by the cell's posterior), with a mild preference for bigger targets.
    /// A score near 1 means "right where the tap most likely landed"; near 0 means "nowhere near it".
    static func rank(_ targets: [Target], posterior: [Float], centroids: [Float], grid: Grid) -> [Target] {
        let b = Display.bounds
        let sx = Double(b.width) / Double(grid.cols) * 0.42, sy = Double(b.height) / Double(grid.rows) * 0.42
        return targets.map { t in
            var t = t
            var dens = 0.0
            for c in 0..<grid.count where posterior[c] > 0.005 {
                let cx = Double(b.minX) + Double(centroids[c * 2]) * Double(b.width)
                let cy = Double(b.minY) + Double(centroids[c * 2 + 1]) * Double(b.height)
                // Distance to the nearest point of the target, not its centre: big targets catch more taps.
                let dx = max(0, max(Double(t.frame.minX) - cx, cx - Double(t.frame.maxX)))
                let dy = max(0, max(Double(t.frame.minY) - cy, cy - Double(t.frame.maxY)))
                dens += Double(posterior[c]) * exp(-0.5 * (dx * dx / (sx * sx) + dy * dy / (sy * sy)))
            }
            let area = Double(t.frame.width * t.frame.height)
            t.score = dens * (1 + 0.08 * log1p(area / 1500))
            return t
        }
        .filter { $0.score > 1e-4 }
        .sorted { $0.score > $1.score }
    }

    /// Keeps only targets you can actually see: the thing at their centre on screen must belong to the same app.
    /// Catches buttons hidden behind another window. Checks the best `limit` only (each check is an IPC call).
    static func visible(_ ranked: [Target], limit: Int = 10) -> [Target] {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        return ranked.prefix(limit).filter { t in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(t.center.x), Float(t.center.y), &hit) == .success, let hit else { return true }
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            return pid == t.pid || pid == 0
        }
    }

    /// Up to four big, well-separated picking tiles built from the calibration grid: the top and bottom rows,
    /// left and right halves (middle row and column left out). Taps there are the model's most reliable.
    static func pickRegions(_ grid: Grid) -> [[Int]] {
        let rows = grid.rows >= 2 ? [0, grid.rows - 1] : [0]
        let half = grid.cols / 2
        let left = Array(0..<max(1, half)), right = Array((grid.cols - max(1, half))..<grid.cols)
        var out: [[Int]] = []
        for r in rows { for cols in [left, right] { out.append(cols.map { r * grid.cols + $0 }) } }
        return out
    }

    /// Drop a target when a smaller target sits inside it (prefer the button over the toolbar cell around it).
    private static func innermost(_ ts: [Target]) -> [Target] {
        ts.filter { outer in
            !ts.contains { inner in
                inner.id != outer.id && outer.frame.contains(inner.center) && inner.frame.width * inner.frame.height < outer.frame.width * outer.frame.height * 0.6
            }
        }
    }

    private static func canPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func rect(_ pos: AnyObject, _ size: AnyObject) -> CGRect? {
        guard CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
