import AppKit
import SwiftUI
import Combine

final class DockModel: ObservableObject {
    @Published var hovering: String?
    /// First click on stop arms this; a second click within 3 s really stops.
    @Published var confirmStop = false
    /// Collapsed to a thin line until the mouse comes near.
    @Published var expanded = false
    private var collapseWork: DispatchWorkItem?

    func mouseInside(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if !expanded { expanded = true }
        } else {
            let w = DispatchWorkItem { [weak self] in
                guard let self, !self.confirmStop else { return }
                self.expanded = false
                self.hovering = nil
            }
            collapseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        }
    }
}

/// Small floating dock at the middle of the left edge:
/// a mic button (dictate) and a record button (meeting notes).
/// It rests as a thin line and slides open on hover. Drag it up or down;
/// it never takes focus from the app you're typing in.
final class Dock {
    var onDictate: (() -> Void)?
    var onNotes: (() -> Void)?

    private let panel: NSPanel
    private let tip: NSPanel
    private let tipLabel = NSTextField(labelWithString: "")
    private let model = DockModel()
    private let size = NSSize(width: 60, height: 108)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
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
        panel.hasShadow = true
        tip.ignoresMouseEvents = true

        tipLabel.textColor = .white
        tipLabel.font = Theme.nsSans(14, .medium)
        let tipBG = NSView()
        tipBG.wantsLayer = true
        tipBG.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        tipBG.layer?.cornerRadius = 17
        tipBG.addSubview(tipLabel)
        tip.contentView = tipBG

        let view = DockView(model: model,
                            dictate: { [weak self] in self?.onDictate?() },
                            notes: { [weak self] in self?.notesTapped() },
                            drag: { [weak self] ended in self?.dragMoved(ended: ended) })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        model.$expanded.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.panel.invalidateShadow(); self?.updateTip() }
        }.store(in: &bag)
        model.$hovering.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateTip() }.store(in: &bag)
        model.$confirmStop.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTip() }
        }.store(in: &bag)
        AppState.shared.$live.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTip() }
        }.store(in: &bag)
    }

    private var bag = Set<AnyCancellable>()

    private static let originKey = "dockOrigin"
    private var dragOffset: NSPoint?

    /// Starts a bit above the middle of the left edge, or wherever it was last dragged.
    func show() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        var origin = NSPoint(x: vf.minX, y: vf.midY - size.height / 2 + 120)
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
            // Snap flush to a side edge when dropped close to it.
            if let vf = panel.screen?.visibleFrame {
                var o = panel.frame.origin
                if o.x - vf.minX < 24 { o.x = vf.minX }
                if vf.maxX - panel.frame.maxX < 24 { o.x = vf.maxX - size.width }
                o.y = min(max(o.y, vf.minY), vf.maxY - size.height)
                panel.setFrameOrigin(o)
            }
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
            updateTip()
        }
    }

    private func notesTapped() {
        if AppState.shared.live == nil {
            onNotes?()
        } else if model.confirmStop {
            model.confirmStop = false
            onNotes?()
        } else {
            model.confirmStop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.model.confirmStop = false }
        }
    }

    private func updateTip() {
        let live = AppState.shared.live != nil
        guard model.expanded else { tip.orderOut(nil); return }
        let text: String?
        switch model.hovering {
        case "mic": text = "Dictate  ⌥1"
        case "notes":
            if live { text = model.confirmStop ? "Click again to stop notes" : "Stop taking notes" }
            else { text = AppState.shared.meetingLikely ? "Meeting? Start Notetaker" : "Start Notetaker" }
        default: text = model.confirmStop ? "Click again to stop notes" : nil
        }
        guard let text else { tip.orderOut(nil); return }
        tipLabel.stringValue = text
        tipLabel.sizeToFit()
        let w = tipLabel.frame.width + 32
        tip.setContentSize(NSSize(width: w, height: 34))
        tipLabel.setFrameOrigin(NSPoint(x: 16, y: (34 - tipLabel.frame.height) / 2))
        let y = model.hovering == "mic" ? panel.frame.minY + 62 : panel.frame.minY + 10
        let x = panel.frame.minX + 64
        tip.setFrameOrigin(NSPoint(x: x, y: y))
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
    let drag: (_ ended: Bool) -> Void

    private var busy: Bool { state.phase != .idle || state.live != nil }

    var body: some View {
        ZStack(alignment: .leading) {
            if model.expanded {
                buttons.padding(.leading, 8).transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                // Resting state: a small line on the edge. Light fill with a dark rim,
                // so it shows up on both light and dark windows.
                Capsule()
                    .fill(Color(white: 0.92).opacity(0.9))
                    .overlay(Capsule().stroke(Color.black.opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .frame(width: 5, height: 34)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .frame(width: 60, height: 108, alignment: .leading)
        // Near-invisible strip so the edge still catches the mouse when collapsed.
        .background(Color.black.opacity(0.001).frame(width: model.expanded ? 60 : 16), alignment: .leading)
        .contentShape(Rectangle())
        .onHover { model.mouseInside($0) }
        // Drag from anywhere on the dock (buttons still click when you don't move).
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in drag(false) }
                .onEnded { _ in drag(true) }
        )
        .animation(.easeOut(duration: 0.18), value: model.expanded)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: dictate) {
                Image(systemName: state.phase == .recording ? "mic.fill" : "mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(state.phase == .recording ? .red : .white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .onHover { model.hovering = $0 ? "mic" : (model.hovering == "mic" ? nil : model.hovering) }

            Button(action: notes) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if state.live != nil {
                            RoundedRectangle(cornerRadius: 3).fill(model.confirmStop ? Color.orange : Color.red)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "record.circle").font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.9)))
                    if state.live == nil && state.meetingLikely {
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { model.hovering = $0 ? "notes" : (model.hovering == "notes" ? nil : model.hovering) }
        }
        .padding(.vertical, 4)
    }
}