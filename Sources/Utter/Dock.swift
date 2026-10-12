import AppKit
import SwiftUI
import Combine

final class DockModel: ObservableObject {
    @Published var hovering: String?
    /// Collapsed to a thin handle until the mouse comes near.
    @Published var expanded = false
    /// Which screen edge it sits on; upright on the left and right, lying flat on top and bottom.
    @Published var spot = EdgeSpot.left
    private var collapseWork: DispatchWorkItem?

    func mouseInside(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if !expanded { expanded = true }
        } else {
            let w = DispatchWorkItem { [weak self] in
                self?.expanded = false
                self?.hovering = nil
            }
            collapseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
    }
}

/// Small floating dock on an edge of the screen (left by default): one dark capsule with
/// Dictate (mic) and Notetaker (record). While notes are running it also shows a
/// transcript button and a live timer. It rests as a thin handle and opens on hover.
/// Drag it to the middle of any edge; it never takes focus from the app you're typing in.
final class Dock {
    var onDictate: (() -> Void)?
    var onNotes: (() -> Void)?

    private let panel: NSPanel
    private let tip: NSPanel
    private let tipLabel = NSTextField(labelWithString: "")
    private let model = DockModel()
    /// Long and short side of the dock panel (the capsule plus room for it to open).
    static let long: CGFloat = 168, short: CGFloat = 64
    private let size = NSSize(width: Dock.short, height: Dock.long)
    private var bag = Set<AnyCancellable>()
    private let targets = DropTargets()
    private var springTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        for p in [panel, tip] {
            p.isFloatingPanel = true
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.canHide = false   // stays up even if Utter is hidden
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        panel.hasShadow = false   // the capsule draws its own soft shadow
        tip.ignoresMouseEvents = true

        tipLabel.textColor = .white
        tipLabel.font = Theme.nsSans(13, .medium)
        let tipBG = NSView()
        tipBG.wantsLayer = true
        tipBG.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        tipBG.layer?.cornerRadius = 16
        tipBG.addSubview(tipLabel)
        tip.contentView = tipBG

        let view = DockView(model: model,
                            dictate: { [weak self] in self?.onDictate?() },
                            notes: { [weak self] in self?.onNotes?() },
                            transcript: { MeetingPanel.shared.showLive() },
                            drag: { [weak self] ended in self?.dragMoved(ended: ended) })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        for pub in [model.$expanded.map { _ in () }.eraseToAnyPublisher(),
                    model.$hovering.map { _ in () }.eraseToAnyPublisher(),
                    AppState.shared.$live.map { _ in () }.eraseToAnyPublisher(),
                    AppState.shared.$phase.map { _ in () }.eraseToAnyPublisher()] {
            pub.receive(on: RunLoop.main).sink { [weak self] in
                DispatchQueue.main.async { self?.updateTip() }
            }.store(in: &bag)
        }
        // Resolution, display arrangement or monitor changes: stay on a screen's edge.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.resnap() }
    }

    private static let spotKey = "dockSpot"
    /// The edge the dock sits on (saved), so the pill can step aside on the same edge.
    static var spot: EdgeSpot { EdgeSpot.saved(spotKey, default: .left) }
    private var dragOffset: NSPoint?

    /// Starts on the edge it was last dragged to (the left by default).
    func show() {
        resnap()
        panel.orderFrontRegardless()
    }

    private func frame(for spot: EdgeSpot, on screen: NSScreen) -> NSRect {
        EdgeSnap.frame(for: spot, long: Self.long, short: Self.short, inset: 0, on: screen)
    }

    /// Puts the dock on its spot on the screen it's on (or the main screen if that went away).
    private func resnap() { place(animated: false) }

    private func place(animated: Bool, on screen: NSScreen? = nil) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let spot = Self.spot
        let target = frame(for: spot, on: screen)
        springTimer?.invalidate()
        springTimer = nil
        if model.spot != spot { model.spot = spot }
        if animated {
            // Change shape around the current centre, then spring into place.
            let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            panel.setFrame(NSRect(x: c.x - target.width / 2, y: c.y - target.height / 2,
                                  width: target.width, height: target.height), display: true)
            springTimer = EdgeSnap.spring(panel, to: target.origin) { [weak self] in
                self?.springTimer = nil
                self?.updateTip()
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Follows the mouse while dragging, showing the four spots; springs to the nearest when let go.
    private func dragMoved(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            springTimer?.invalidate()
            springTimer = nil
            dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            tip.orderOut(nil)
        }
        guard let off = dragOffset, let screen = EdgeSnap.screen(at: mouse) else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - off.x, y: mouse.y - off.y))
        let near = EdgeSnap.nearest(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY), on: screen)
        if !ended {
            targets.show(on: screen, rects: EdgeSpot.allCases.map { (frame(for: $0, on: screen), $0 == near) },
                         under: panel)
            return
        }
        dragOffset = nil
        targets.hide()
        near.save(Self.spotKey)
        place(animated: true, on: screen)
        NotificationCenter.default.post(name: .utterDockMoved, object: nil)
    }

    private func updateTip() {
        guard model.expanded, let hovering = model.hovering else { tip.orderOut(nil); return }
        let live = AppState.shared.live != nil
        let text: String
        let y: CGFloat   // the button's centre, along the dock from its top (or left) end
        switch hovering {
        case "mic":
            text = "Dictate   ⌥1"
            y = DockView.micCenter
        case "transcript":
            text = "Show transcript"
            y = DockView.transcriptCenter
        default:
            text = live ? "Stop taking notes"
                : AppState.shared.phase != .idle ? "Finish dictation first"
                : "Start Notetaker"
            y = DockView.notesCenter
        }
        tipLabel.stringValue = text
        tipLabel.sizeToFit()
        let h: CGFloat = 32
        let w = tipLabel.frame.width + 28
        tip.setContentSize(NSSize(width: w, height: h))
        tipLabel.setFrameOrigin(NSPoint(x: 14, y: (h - tipLabel.frame.height) / 2))
        // Beside the button, on the side away from the screen edge. AppKit counts y from the bottom.
        let f = panel.frame
        let origin: NSPoint
        switch model.spot {
        case .left:   origin = NSPoint(x: f.minX + 62, y: f.maxY - y - h / 2)
        case .right:  origin = NSPoint(x: f.maxX - 62 - w, y: f.maxY - y - h / 2)
        case .top:    origin = NSPoint(x: f.minX + y - w / 2, y: f.maxY - 62 - h)
        case .bottom: origin = NSPoint(x: f.minX + y - w / 2, y: f.minY + 62)
        }
        tip.setFrameOrigin(origin)
        tip.orderFrontRegardless()
    }
}

/// Lets the first click on a non-activating panel hit the button.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var state = AppState.shared
    let dictate: () -> Void
    let notes: () -> Void
    let transcript: () -> Void
    let drag: (_ ended: Bool) -> Void

    // Vertical centres of the buttons, from the top of the dock (for tooltips).
    static let micCenter: CGFloat = 32
    static let notesCenter: CGFloat = 80
    static let transcriptCenter: CGFloat = 128

    private var dictating: Bool { state.phase != .idle }
    private var live: Bool { state.live != nil }
    private var vertical: Bool { model.spot.vertical }
    /// The screen edge the dock hugs, and where its buttons start (top, or left when lying flat).
    private var edge: Edge {
        switch model.spot { case .left: .leading; case .right: .trailing; case .top: .top; case .bottom: .bottom }
    }
    private var start: Edge { vertical ? .top : .leading }
    private var corner: Alignment {
        switch model.spot { case .left: .topLeading; case .right: .topTrailing; case .top: .topLeading; case .bottom: .bottomLeading }
    }
    private var edgeAlignment: Alignment {
        switch model.spot { case .left: .leading; case .right: .trailing; case .top: .top; case .bottom: .bottom }
    }

    var body: some View {
        ZStack(alignment: corner) {
            if model.expanded {
                capsule
                    .padding(Edge.Set(edge), 8).padding(Edge.Set(start), 6)
                    .transition(.move(edge: edge).combined(with: .opacity))
            } else {
                handle
                    .padding(Edge.Set(edge), 3).padding(Edge.Set(start), 50)
                    .transition(.opacity)
            }
        }
        .frame(width: vertical ? Dock.short : Dock.long, height: vertical ? Dock.long : Dock.short, alignment: corner)
        // Near-invisible strip so the edge still catches the mouse when collapsed.
        .background(Color.black.opacity(0.001)
                        .frame(width: vertical ? (model.expanded ? Dock.short : 18) : nil,
                               height: vertical ? nil : (model.expanded ? Dock.short : 18)),
                    alignment: edgeAlignment)
        .contentShape(Rectangle())
        .onHover { model.mouseInside($0) }
        // Drag from anywhere on the dock (buttons still click when you don't move).
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in drag(false) }
                .onEnded { _ in drag(true) }
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.expanded)
        .animation(.easeOut(duration: 0.2), value: live)
    }

    /// Resting state: a slim pill on the edge. Red while recording, so you always know.
    private var handle: some View {
        Capsule()
            .fill(dictating || live ? Color.red : Color(white: 0.18).opacity(0.75))
            .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: vertical ? 6 : (live ? 56 : 40), height: vertical ? (live ? 56 : 40) : 6)
    }

    private var capsule: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return stack {
            DockButton(active: dictating, activeColor: .red, help: "mic") {
                Image(systemName: dictating ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .semibold))
            } action: { dictate() }
            .onHover { hover("mic", $0) }

            DockButton(active: live, activeColor: .red, help: "notes") {
                if live {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 13, height: 13)
                } else {
                    Image(systemName: "record.circle").font(.system(size: 19, weight: .semibold))
                }
            } action: { notes() }
            // No meeting while dictating: greyed out until the dictation ends.
            .disabled(dictating && !live)
            .opacity(dictating && !live ? 0.35 : 1)
            .onHover { hover("notes", $0) }

            if live, let m = state.live {
                DockButton(active: false, activeColor: .clear, help: "transcript") {
                    Image(systemName: "text.alignleft").font(.system(size: 15, weight: .semibold))
                } action: { transcript() }
                .onHover { hover("transcript", $0) }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.clock(m.duration))
                        .font(Theme.sans(11, .semibold)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(vertical ? .bottom : .trailing, 4)
            }
        }
        .padding(4)
        .background(
            Capsule().fill(Color(white: 0.07).opacity(0.94))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        )
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside { model.hovering = id } else if model.hovering == id { model.hovering = nil }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Round 40 pt button inside the dock capsule; fills with a colour when active.
private struct DockButton<Label: View>: View {
    let active: Bool
    let activeColor: Color
    let help: String
    @ViewBuilder let label: () -> Label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(active ? activeColor : Color.white.opacity(0.001)))
                .contentShape(Circle())
        }
        .buttonStyle(DockPressStyle())
    }
}

/// Subtle highlight on hover-press, so clicks feel responsive.
private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
