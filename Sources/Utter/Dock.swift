import AppKit
import SwiftUI
import Combine

final class DockModel: ObservableObject {
    @Published var hovering: String?
    /// Collapsed to a thin handle until the mouse comes near.
    @Published var expanded = false
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

/// Small floating dock on the left edge of the screen: one dark capsule with
/// Dictate (mic) and Notetaker (record). While notes are running it also shows a
/// transcript button and a live timer. It rests as a thin handle and opens on hover.
/// Drag it anywhere; it never takes focus from the app you're typing in.
final class Dock {
    var onDictate: (() -> Void)?
    var onNotes: (() -> Void)?

    private let panel: NSPanel
    private let tip: NSPanel
    private let tipLabel = NSTextField(labelWithString: "")
    private let model = DockModel()
    private let size = NSSize(width: 64, height: 168)
    private var bag = Set<AnyCancellable>()

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        for p in [panel, tip] {
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
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
                    AppState.shared.$live.map { _ in () }.eraseToAnyPublisher()] {
            pub.receive(on: RunLoop.main).sink { [weak self] in
                DispatchQueue.main.async { self?.updateTip() }
            }.store(in: &bag)
        }
    }

    private static let originKey = "dockOrigin"
    private var dragOffset: NSPoint?

    /// Starts a bit above the middle of the left edge, or wherever it was last dragged.
    func show() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        var origin = NSPoint(x: vf.minX, y: vf.midY - size.height / 2 + 100)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -10, dy: -10).contains(p) }) { origin = p }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Follows the mouse while dragging; remembers the spot when let go.
    private func dragMoved(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil {
            dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            tip.orderOut(nil)
        }
        guard let off = dragOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - off.x, y: mouse.y - off.y))
        if ended {
            dragOffset = nil
            // Snap flush to the left edge when dropped close to it.
            if let vf = panel.screen?.visibleFrame {
                var o = panel.frame.origin
                if o.x - vf.minX < 32 { o.x = vf.minX }
                o.y = min(max(o.y, vf.minY), vf.maxY - size.height)
                panel.setFrameOrigin(o)
            }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
            updateTip()
        }
    }

    private func updateTip() {
        guard model.expanded, let hovering = model.hovering else { tip.orderOut(nil); return }
        let live = AppState.shared.live != nil
        let text: String
        let y: CGFloat
        switch hovering {
        case "mic":
            text = "Dictate   ⌥1"
            y = DockView.micCenter
        case "transcript":
            text = "Show transcript"
            y = DockView.transcriptCenter
        default:
            text = live ? "Stop taking notes" : (AppState.shared.meetingLikely ? "Meeting? Start Notetaker" : "Start Notetaker")
            y = DockView.notesCenter
        }
        tipLabel.stringValue = text
        tipLabel.sizeToFit()
        let h: CGFloat = 32
        tip.setContentSize(NSSize(width: tipLabel.frame.width + 28, height: h))
        tipLabel.setFrameOrigin(NSPoint(x: 14, y: (h - tipLabel.frame.height) / 2))
        // y is measured from the top of the dock; AppKit counts from the bottom.
        tip.setFrameOrigin(NSPoint(x: panel.frame.minX + 62, y: panel.frame.maxY - y - h / 2))
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.expanded {
                capsule
                    .padding(.leading, 8).padding(.top, 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                handle
                    .padding(.leading, 3).padding(.top, 50)
                    .transition(.opacity)
            }
        }
        .frame(width: 64, height: 168, alignment: .topLeading)
        // Near-invisible strip so the edge still catches the mouse when collapsed.
        .background(Color.black.opacity(0.001).frame(width: model.expanded ? 64 : 18), alignment: .leading)
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
            .frame(width: 6, height: live ? 56 : 40)
    }

    private var capsule: some View {
        VStack(spacing: 4) {
            DockButton(active: dictating, activeColor: .red, help: "mic") {
                Image(systemName: dictating ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .semibold))
            } action: { dictate() }
            .onHover { hover("mic", $0) }

            DockButton(active: live, activeColor: .red, help: "notes") {
                if live {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 13, height: 13)
                } else {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "record.circle").font(.system(size: 19, weight: .semibold))
                        if state.meetingLikely {
                            Circle().fill(Color.green).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                                .offset(x: 4, y: -3)
                        }
                    }
                }
            } action: { notes() }
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
                .padding(.bottom, 4)
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
