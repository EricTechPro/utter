import AppKit
import SwiftUI

final class PasteFallbackModel: ObservableObject {
    @Published var text = ""
    @Published var copied = false
}

/// Small card above the recording pill when the words couldn't be pasted anywhere:
/// "Copied to clipboard" + the text + a Copy button. Hides itself after a few seconds.
final class PasteFallback {
    static let shared = PasteFallback()

    private let model = PasteFallbackModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 420, height: 112)

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = PasteFallbackView(model: model,
                                     copy: { [weak self] in self?.copy() },
                                     close: { [weak self] in self?.hide() })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show(_ text: String) {
        model.text = text
        model.copied = false
        // Bottom-centre of the screen the mouse is on, just above where the pill sits.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 80))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide(after: 8)
    }

    private func copy() {
        Paster.putOnClipboard(model.text)
        model.copied = true
        scheduleHide(after: 1.5)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }
}

private struct PasteFallbackView: View {
    @ObservedObject var model: PasteFallbackModel
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 13, weight: .semibold))
                Text(model.copied ? "Copied" : "No text box to paste into. It's on your clipboard.")
                    .font(Theme.sans(13, .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.6))
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text(model.text)
                    .font(Theme.sans(14))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Image(systemName: model.copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        Text(model.copied ? "Copied" : "Copy").font(Theme.sans(13, .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(width: size.width - 8, height: size.height - 8, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.92)))
        .frame(width: size.width, height: size.height)
    }

    private var size: NSSize { NSSize(width: 420, height: 112) }
}
