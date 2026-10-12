import AppKit

/// The four places the recording pill and the dock can sit: the middle of each screen edge.
enum EdgeSpot: String, CaseIterable {
    case bottom, top, left, right
    var vertical: Bool { self == .left || self == .right }

    static func saved(_ key: String, default d: EdgeSpot) -> EdgeSpot {
        EdgeSpot(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? d
    }
    func save(_ key: String) { UserDefaults.standard.set(rawValue, forKey: key) }
}

extension Notification.Name {
    /// The dock moved to another edge (the pill steps aside when they share one).
    static let utterDockMoved = Notification.Name("utterDockMoved")
}

/// Shared edge-snapping for the pill and the dock: spot frames, picking a spot, the spring.
enum EdgeSnap {
    /// Frame of a `long` × `short` bar on `spot` (upright on the left and right), `inset` from
    /// the edge and moved `shift` along it. Uses the screen's usable area: below the menu bar
    /// and the notch, beside the Dock.
    static func frame(for spot: EdgeSpot, long: CGFloat, short: CGFloat, inset: CGFloat,
                      shift: CGFloat = 0, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let top = min(vf.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        switch spot {
        case .bottom: return NSRect(x: vf.midX - long / 2 + shift, y: vf.minY + inset, width: long, height: short)
        case .top:    return NSRect(x: vf.midX - long / 2 + shift, y: top - short - inset, width: long, height: short)
        case .left:   return NSRect(x: vf.minX + inset, y: vf.midY - long / 2 + shift, width: short, height: long)
        case .right:  return NSRect(x: vf.maxX - short - inset, y: vf.midY - long / 2 + shift, width: short, height: long)
        }
    }

    static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// The edge `point` is closest to, relative to the screen's size, so each spot owns a
    /// quarter of the screen (split along the diagonals), not just its own neighbourhood.
    static func nearest(to point: NSPoint, on screen: NSScreen) -> EdgeSpot {
        let vf = screen.visibleFrame
        let gaps: [(EdgeSpot, CGFloat)] = [(.left, (point.x - vf.minX) / vf.width),
                                           (.right, (vf.maxX - point.x) / vf.width),
                                           (.bottom, (point.y - vf.minY) / vf.height),
                                           (.top, (vf.maxY - point.y) / vf.height)]
        return gaps.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    /// Damped spring (overshoots a touch, then settles) moving `window` to `origin`.
    /// Invalidate the returned timer to stop it.
    @discardableResult
    static func spring(_ window: NSWindow, to origin: NSPoint, done: (() -> Void)? = nil) -> Timer {
        let from = window.frame.origin, start = Date()
        let w = 2 * Double.pi / 0.38, z = 0.78, wd = w * sqrt(1 - z * z), end = 0.7
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak window] t in
            guard let window else { return t.invalidate() }
            let e = Date().timeIntervalSince(start)
            let p = e >= end ? 1 : 1 - exp(-z * w * e) * (cos(wd * e) + z * w / wd * sin(wd * e))
            window.setFrameOrigin(NSPoint(x: from.x + (origin.x - from.x) * p, y: from.y + (origin.y - from.y) * p))
            if e >= end { t.invalidate(); done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

/// Soft see-through capsules at the four spots while dragging; the nearest one lights up.
/// Sits on the status-bar level like the pill and dock; they reorder themselves above it.
final class DropTargets {
    private let panel: NSPanel
    private let view = TargetsView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false   // stays up even if Utter is hidden
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// Shows `rects` (screen coordinates; true = highlighted) on `screen`, under `above`.
    func show(on screen: NSScreen, rects: [(NSRect, Bool)], under above: NSWindow) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        view.rects = rects.map { ($0.0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).insetBy(dx: -4, dy: -4), $0.1) }
        view.needsDisplay = true
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            above.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }
}

private final class TargetsView: NSView {
    var rects: [(NSRect, Bool)] = []

    override func draw(_ dirtyRect: NSRect) {
        for (r, near) in rects {
            let radius = min(r.width, r.height) / 2
            let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            NSColor.black.withAlphaComponent(near ? 0.4 : 0.18).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(near ? 0.9 : 0.45).setStroke()
            path.lineWidth = near ? 2 : 1.5
            path.stroke()
        }
    }
}
