import AppKit
import SwiftUI

/// Shows which meeting the transcript window displays: the live one or a saved one.
final class MeetingPanelModel: ObservableObject {
    @Published var savedID: UUID?
    @Published var copied = false
    @Published var warning: String?
}

/// Side window with the live meeting transcript.
final class MeetingPanel {
    static let shared = MeetingPanel()
    var onStop: (() -> Void)?

    let model = MeetingPanelModel()
    private var window: NSWindow?

    func showLive() { model.savedID = nil; present() }
    func show(_ m: Meeting) { model.savedID = m.id; present() }

    private func present() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: TranscriptView(model: model, stop: { [weak self] in self?.onStop?() }))
            if let vf = NSScreen.main?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: vf.maxX - 460, y: vf.maxY - 700))
            }
            window = w
        }
        window?.orderFrontRegardless()
    }
}

private struct TranscriptView: View {
    @ObservedObject var model: MeetingPanelModel
    @ObservedObject var state = AppState.shared
    let stop: () -> Void

    private let cream = Theme.cream

    private var meeting: Meeting? {
        if let id = model.savedID { return state.meetings.first { $0.id == id } }
        return state.live ?? state.meetings.first
    }
    private var isLive: Bool { model.savedID == nil && state.live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.serif(26, .regular))
                HStack(spacing: 10) {
                    if isLive {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Recording").font(Theme.sans(13, .medium))
                    }
                    if let m = meeting { ElapsedText(meeting: m, live: isLive) }
                    Spacer()
                    Button {
                        if let m = meeting { state.copy(m) }
                        model.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [model] in model.copied = false }
                    } label: {
                        Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(meeting?.segments.isEmpty ?? true)
                }
                .foregroundStyle(.secondary)
                if let w = model.warning, isLive {
                    Text(w).font(Theme.sans(12)).foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if meeting?.segments.isEmpty ?? true {
                            Text(isLive ? "Listening… the transcript shows up here every few seconds."
                                        : "Nothing was said.")
                                .foregroundStyle(.secondary).padding(.top, 20)
                        }
                        ForEach(rows, id: \.seg.id) { row in
                            if row.showSpeaker {
                                Text(row.seg.speaker).font(Theme.sans(13, .semibold))
                                    .foregroundStyle(.secondary).padding(.top, 10)
                            }
                            Text(row.seg.text)
                                .font(Theme.sans(15))
                                .textSelection(.enabled)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(row.seg.speaker == "You" ? Color.black.opacity(0.05) : Color.white))
                                .id(row.seg.id)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                }
                .onChange(of: meeting?.segments.count ?? 0) { _ in
                    if isLive, let last = meeting?.segments.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if isLive {
                Divider()
                HStack {
                    Text("Always get consent when transcribing others.")
                        .font(Theme.sans(12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: stop) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.red).frame(width: 12, height: 12)
                            Text("Stop").font(Theme.sans(14, .semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(Color.white))
                        .overlay(Capsule().stroke(Color.black.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(cream)
    }

    private var title: String {
        guard let m = meeting else { return "Meeting notes" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return "Meeting · \(f.string(from: m.start))"
    }

    private var rows: [(seg: Segment, showSpeaker: Bool)] {
        let segs = meeting?.segments ?? []
        return segs.enumerated().map { i, s in (s, i == 0 || segs[i - 1].speaker != s.speaker) }
    }
}

/// Ticks every second while live.
private struct ElapsedText: View {
    let meeting: Meeting
    let live: Bool
    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { _ in Text(Self.format(meeting.duration)).monospacedDigit() }
        } else {
            Text(Self.format(meeting.duration)).monospacedDigit()
        }
    }
    static func format(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
