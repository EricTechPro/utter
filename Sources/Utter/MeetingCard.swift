import AppKit
import SwiftUI

final class MeetingCardModel: ObservableObject {
    @Published var title = ""
    @Published var start = Date()
    @Published var joinURL: URL?
}

/// Black card near the top-right of the screen that offers to join or take notes:
/// "Team sync · In 4 min   [Join] [Start Notetaker]  ✕".
/// Non-activating, so it never steals focus.
final class MeetingCard {
    var onJoin: ((URL) -> Void)?
    var onNotes: (() -> Void)?
    var onClose: (() -> Void)?

    private let model = MeetingCardModel()
    private let panel: NSPanel
    private var visible = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.canHide = false   // stays up even if Utter is hidden
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = MeetingCardView(model: model,
                                   join: { [weak self] in if let u = self?.model.joinURL { self?.onJoin?(u) } },
                                   notes: { [weak self] in self?.onNotes?() },
                                   close: { [weak self] in self?.onClose?() })
        let host = FirstMouseHostingView(rootView: view)
        host.frame = panel.contentView!.bounds
        panel.contentView = host
    }

    func show(title: String, start: Date, joinURL: URL?) {
        if model.title != title { model.title = title }
        if model.start != start { model.start = start }
        if model.joinURL != joinURL { model.joinURL = joinURL }
        guard !visible else { return }
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 440 - 16, y: vf.maxY - 84 - 16))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        Chime.playStart()
        visible = true
    }

    func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            if self?.visible == false { self?.panel.orderOut(nil) }
        })
    }
}

private struct MeetingCardView: View {
    @ObservedObject var model: MeetingCardModel
    let join: () -> Void
    let notes: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(red: 0.98, green: 0.73, blue: 0.2))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(Theme.sans(15, .semibold)).foregroundColor(.white).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            Text(when).font(Theme.sans(12)).foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                Spacer(minLength: 8)
                if model.joinURL != nil {
                    pill("Join", icon: "arrow.up.right", action: join)
                }
                pill("Start Notetaker", icon: "waveform", action: notes)
            }
            .padding(.leading, 18).padding(.trailing, 14)
            .frame(width: 432, height: 70)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
            .padding(.top, 10).padding(.leading, 6)

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color(white: 0.25)))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .frame(width: 440, height: 84, alignment: .topLeading)
    }

    private var when: String {
        let mins = Int((model.start.timeIntervalSinceNow / 60).rounded())
        if mins > 0 { return "In \(mins) min" }
        if mins == 0 { return "Starting now" }
        return "Started \(-mins) min ago"
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(Theme.sans(13, .semibold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}
