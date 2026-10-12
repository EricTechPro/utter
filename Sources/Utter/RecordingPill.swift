import AppKit

/// Black pill on an edge of the screen while recording:
/// ✕ (cancel) · live waveform · ✓ (stop and paste).
/// Drag it to one of four spots (top, bottom, left, right middle); it remembers the last one.
/// On the left and right edges it stands upright. It's a non-activating panel, so clicking
/// or dragging it doesn't steal focus from the text box the words should go into.
final class RecordingPill {
    typealias Spot = EdgeSpot

    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private let panel: NSPanel
    private let bg = PillView()
    private let cancel = CircleButton(symbol: "xmark", fill: NSColor(white: 0.35, alpha: 1), tint: .white)
    private let done = CircleButton(symbol: "checkmark", fill: .white, tint: .black)
    private let wave = WaveformView()
    private let spinner = NSProgressIndicator()
    private let targets = DropTargets()
    /// Long and short side of the pill; it swaps them when standing upright.
    private static let long: CGFloat = 190, short: CGFloat = 44
    private static let spotKey = "pillSpot"
    private var spot = Spot.saved(RecordingPill.spotKey, default: .bottom)
    private var spaceObserver: NSObjectProtocol?
    private var dragOffset: NSPoint?
    private var springTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.long, height: Self.short),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Status-bar level sits above full-screen apps without covering system alerts.
        // Set it after isFloatingPanel, which resets the level to .floating.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.canHide = false   // stays up even if Utter is hidden
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        bg.layer?.cornerRadius = Self.short / 2
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bg.layer?.borderWidth = 1

        cancel.target = self; cancel.action = #selector(cancelTapped)
        cancel.toolTip = "Cancel (Esc)"
        done.target = self; done.action = #selector(doneTapped)
        done.toolTip = "Stop and paste (Option+1)"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isHidden = true

        [cancel, wave, spinner, done].forEach(bg.addSubview)
        bg.buttons = [cancel, done]
        bg.onDrag = { [weak self] phase in self?.drag(phase) }
        panel.contentView = bg
        layout(vertical: false)

        // Display changes, or the dock moving onto the pill's edge: put the pill back on its spot.
        for name in [NSApplication.didChangeScreenParametersNotification, .utterDockMoved] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.panel.isVisible, self.dragOffset == nil else { return }
                self.snap(animated: name == .utterDockMoved)
            }
        }
    }

    func showRecording() {
        wave.reset()
        wave.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        snap(animated: false, screen: EdgeSnap.screen(at: NSEvent.mouseLocation))
        panel.orderFrontRegardless()
        // Swiping to another Space (or a full-screen app) can leave the pill behind; re-show it there.
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.panel.orderFrontRegardless() }
        }
    }

    func showWorking() {
        wave.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func hide() {
        spinner.stopAnimation(nil)
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        springTimer?.invalidate()
        springTimer = nil
        dragOffset = nil
        targets.hide()
        panel.orderOut(nil)
    }

    func push(level: Float) { wave.push(level) }

    // MARK: Spots

    /// Where the pill sits for `spot` on `screen`: 24 pt above the bottom, 16 pt below the top,
    /// 6 pt from the sides. On the dock's edge it steps past the dock so they don't overlap.
    private func frame(for spot: Spot, on screen: NSScreen) -> NSRect {
        let inset: CGFloat = spot.vertical ? 6 : spot == .bottom ? 24 : 16
        var shift: CGFloat = 0
        if spot == Dock.spot {
            let gap = Dock.long / 2 + Self.long / 2 + 12
            shift = spot.vertical ? -gap : gap   // below the dock on the sides, right of it on top/bottom
        }
        return EdgeSnap.frame(for: spot, long: Self.long, short: Self.short, inset: inset, shift: shift, on: screen)
    }

    /// Moves to the current spot on `screen` (default: the screen the pill is on).
    private func snap(animated: Bool, screen: NSScreen? = nil) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let target = frame(for: spot, on: screen)
        springTimer?.invalidate()
        springTimer = nil
        layout(vertical: spot.vertical)
        if animated {
            // Change shape around the current centre, then spring into place.
            let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            panel.setFrame(NSRect(x: c.x - target.width / 2, y: c.y - target.height / 2,
                                  width: target.width, height: target.height), display: true)
            springTimer = EdgeSnap.spring(panel, to: target.origin) { [weak self] in self?.springTimer = nil }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func drag(_ phase: PillView.DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .began:
            springTimer?.invalidate()
            springTimer = nil
            dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            fallthrough
        case .moved:
            guard let off = dragOffset else { return }
            panel.setFrameOrigin(NSPoint(x: mouse.x - off.x, y: mouse.y - off.y))
            guard let screen = EdgeSnap.screen(at: mouse) else { return }
            let near = EdgeSnap.nearest(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY), on: screen)
            targets.show(on: screen, rects: Spot.allCases.map { (frame(for: $0, on: screen), $0 == near) }, under: panel)
        case .ended:
            guard dragOffset != nil else { return }
            dragOffset = nil
            targets.hide()
            guard let screen = EdgeSnap.screen(at: mouse) else { return }
            spot = EdgeSnap.nearest(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY), on: screen)
            spot.save(Self.spotKey)
            snap(animated: true, screen: screen)
        }
    }

    /// Lays out ✕, waveform and ✓ across (top/bottom) or upright (left/right, ✕ on top).
    private func layout(vertical: Bool) {
        let size = vertical ? NSSize(width: Self.short, height: Self.long) : NSSize(width: Self.long, height: Self.short)
        bg.frame = NSRect(origin: .zero, size: size)
        if vertical {
            cancel.frame = NSRect(x: 7, y: size.height - 37, width: 30, height: 30)
            done.frame = NSRect(x: 7, y: 7, width: 30, height: 30)
            wave.frame = NSRect(x: 8, y: 46, width: 28, height: size.height - 92)
        } else {
            cancel.frame = NSRect(x: 7, y: 7, width: 30, height: 30)
            done.frame = NSRect(x: size.width - 37, y: 7, width: 30, height: 30)
            wave.frame = NSRect(x: 46, y: 8, width: size.width - 92, height: 28)
        }
        wave.vertical = vertical
        spinner.frame = NSRect(x: (size.width - 16) / 2, y: (size.height - 16) / 2, width: 16, height: 16)
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func doneTapped() { onDone?() }
}

/// The pill's background. It takes every click itself: a press that moves more than a few
/// points drags the pill, otherwise letting go over ✕ or ✓ clicks that button.
private final class PillView: NSView {
    enum DragPhase { case began, moved, ended }
    var buttons: [NSButton] = []
    var onDrag: ((DragPhase) -> Void)?
    private var downAt: NSPoint?
    private var pressed: NSButton?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragging = false
        let p = convert(event.locationInWindow, from: nil)
        pressed = buttons.first { $0.frame.contains(p) }
        pressed?.alphaValue = 0.7
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let m = NSEvent.mouseLocation
        if !dragging, hypot(m.x - downAt.x, m.y - downAt.y) > 4 {
            dragging = true
            pressed?.alphaValue = 1
            pressed = nil
            onDrag?(.began)
        } else if dragging {
            onDrag?(.moved)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onDrag?(.ended)
        } else if let b = pressed, b.frame.contains(convert(event.locationInWindow, from: nil)) {
            b.performClick(nil)
        }
        pressed?.alphaValue = 1
        pressed = nil
        downAt = nil
        dragging = false
    }
}

private final class CircleButton: NSButton {
    init(symbol: String, fill: NSColor, tint: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 15
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        contentTintColor = tint
        imagePosition = .imageOnly
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks register even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Scrolling bars driven by mic loudness.
private final class WaveformView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 22)
    /// Upright pill: bars lie across and scroll downwards.
    var vertical = false { didSet { needsDisplay = true } }

    func reset() { levels = levels.map { _ in 0 }; needsDisplay = true }

    func push(_ rms: Float) {
        // RMS -> 0...1 on a -50...-10 dB scale.
        let db = 20 * log10(max(rms, 1e-6))
        let v = CGFloat(min(max((db + 50) / 40, 0), 1))
        levels.removeFirst()
        levels.append(v)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let n = CGFloat(levels.count)
        let barW: CGFloat = 2.5
        let along = vertical ? bounds.height : bounds.width, across = vertical ? bounds.width : bounds.height
        let gap = (along - barW * n) / max(n - 1, 1)
        for (i, v) in levels.enumerated() {
            let h = max(3, v * across)
            let pos = CGFloat(i) * (barW + gap)
            let r = vertical
                ? NSRect(x: (across - h) / 2, y: along - pos - barW, width: h, height: barW)
                : NSRect(x: pos, y: (across - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
