import SwiftUI
import ServiceManagement
import AppKit

/// Small observable holders instead of @State: the Command Line Tools SDK
/// ships without the SwiftUI macro plugin that @State needs.
final class SearchModel: ObservableObject {
    @Published var text = ""
    @Published var tab = "history"
}
final class RowModel: ObservableObject {
    @Published var hover = false
    @Published var copied = false
    @Published var expanded = false
}

/// A deleted dictation stays undoable for a few seconds; its audio is removed after that.
final class HistoryUndo: ObservableObject {
    static let shared = HistoryUndo()
    @Published private(set) var pending: Dictation?
    private var commit: DispatchWorkItem?

    func delete(_ d: Dictation) {
        finish()
        AppState.shared.remove(d)
        pending = d
        let w = DispatchWorkItem { [weak self] in self?.finish() }
        commit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    func undo() {
        commit?.cancel()
        if let d = pending { AppState.shared.restore(d) }
        pending = nil
    }

    /// Deletes the pending one for good (its audio too). Also called when Utter quits.
    func finish() {
        commit?.cancel()
        if let d = pending { AppState.shared.delete(d) }
        pending = nil
    }
}

/// What the menu-bar icon opens: History · Notes · Settings, with Start Dictation and Quit below.
struct MenuBarView: View {
    static let size = NSSize(width: 380, height: 560)

    @ObservedObject var state = AppState.shared
    @ObservedObject var undo = HistoryUndo.shared
    @StateObject private var model: SearchModel
    let dictate: () -> Void
    let toggleNotes: () -> Void

    init(tab: String = "history", dictate: @escaping () -> Void, toggleNotes: @escaping () -> Void) {
        let m = SearchModel()
        m.tab = tab
        _model = StateObject(wrappedValue: m)
        self.dictate = dictate
        self.toggleNotes = toggleNotes
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("History").tag("history")
                Text("Notes").tag("notes")
                Text("Settings").tag("settings")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            Group {
                switch model.tab {
                case "notes": notes
                case "settings": SettingsPage()
                default: history
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .font(Theme.sans(13))
    }

    // MARK: History

    private var filtered: [Dictation] {
        let q = model.text.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? state.entries : state.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var history: some View {
        VStack(spacing: 8) {
            searchField
            if filtered.isEmpty {
                empty("mic", state.entries.isEmpty ? "No dictations yet. Press ⌥1 anywhere and talk." : "No matches.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { d in
                            DictationRow(d: d)
                            if d.id != filtered.last?.id { Divider().padding(.horizontal, 14) }
                        }
                    }
                }
            }
            if undo.pending != nil {
                HStack {
                    Text("Dictation deleted").foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { undo.undo() }.keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    // MARK: Notes

    private var dictating: Bool { state.phase != .idle }

    private var notes: some View {
        let items = state.meetings.filter {
            model.text.isEmpty || $0.transcript.localizedCaseInsensitiveContains(model.text)
        }
        return VStack(spacing: 8) {
            Button(action: toggleNotes) {
                HStack(spacing: 6) {
                    Image(systemName: state.live == nil ? "record.circle" : "stop.fill")
                    Text(state.live == nil ? "Start Notetaker" : "Stop Notetaker")
                }
                .font(Theme.sans(13, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(state.live == nil ? Color.accentColor : Color.red))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            // No meeting while dictating.
            .disabled(dictating && state.live == nil)
            .opacity(dictating && state.live == nil ? 0.4 : 1)
            .help(dictating && state.live == nil ? "Finish dictation first" : "")
            .padding(.horizontal, 14)

            if !state.screenOK {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange)
                    Text("Allow Screen Recording so notes hear the others.").font(Theme.sans(12))
                    Spacer(minLength: 4)
                    Button("Allow") {
                        CGRequestScreenCaptureAccess()
                        SettingsPage.openPrivacy("Privacy_ScreenCapture")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                .padding(.horizontal, 14)
            }
            searchField
            if items.isEmpty && state.live == nil {
                empty("record.circle", "No meetings yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let live = state.live {
                            MeetingRow(m: live, live: true)
                            Divider().padding(.horizontal, 14)
                        }
                        ForEach(items) { m in
                            MeetingRow(m: m, live: false)
                            if m.id != items.last?.id { Divider().padding(.horizontal, 14) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.text).textFieldStyle(.plain)
            if !model.text.isEmpty {
                Button { model.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14)
    }

    private func empty(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button(action: dictate) {
                HStack(spacing: 6) {
                    Image(systemName: state.phase == .recording ? "stop.fill" : "mic.fill")
                    Text(state.phase == .recording ? "Stop Dictation" : "Start Dictation")
                    Text("⌥1").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(state.phase == .working)
            Spacer()
            Button("Quit Utter") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
            Text("⌘Q").foregroundStyle(.secondary)
        }
        .font(Theme.sans(13, .medium))
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Permissions, startup options, shortcuts and where data lives.
private struct SettingsPage: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var login = LoginItemModel.shared
    @AppStorage(Startup.showInDockKey) private var showInDock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Permissions") {
                    row("Microphone", state.micOK, "Privacy_Microphone")
                    row("Accessibility (shortcut, pasting)", state.axOK, "Privacy_Accessibility")
                    row("Screen Recording (notes hear others)", state.screenOK, "Privacy_ScreenCapture")
                    if !(state.micOK && state.axOK) {
                        Button("Finish setup…") { Onboarding.shared.show() }
                    }
                }
                section("General") {
                    toggle("Open at login", Binding(get: { login.on }, set: { login.set($0) }))
                    if login.needsApproval {
                        HStack {
                            Text("Allow Utter in Login Items to finish.").font(Theme.sans(12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    toggle("Show in Dock", $showInDock)
                        .onChange(of: showInDock) { _ in Startup.applyDockPolicy() }
                }
                section("Shortcuts") {
                    line("Start / stop dictation", "⌥1")
                    line("Cancel while recording", "Esc")
                    line("Meeting notes", "Record button on the dock")
                }
                section("Speech") {
                    line("Model", "Whisper, on this Mac")
                    HStack {
                        Text("History, audio and notes stay on this Mac.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.open(state.dataDir) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
        // The menu or System Settings may have changed it.
        .onAppear { login.refresh() }
    }

    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.sans(11, .semibold)).tracking(1.2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    private func row(_ title: String, _ ok: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundColor(ok ? .green : .secondary)
            Text(title)
            Spacer()
            if !ok { Button("Open") { Self.openPrivacy(pane) } }
        }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Time, the full text (four lines, then More), and copy · play · delete icons.
private struct DictationRow: View {
    let d: Dictation
    @StateObject private var m = RowModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Roughly more than four lines (wide characters such as Chinese count double).
    private var long: Bool { d.text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } > 190 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(Self.time.string(from: d.date)).font(Theme.sans(11)).foregroundStyle(.secondary)
                if let app = d.app {
                    Text("· \(app)").font(Theme.sans(11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                IconButton(symbol: m.copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    AppState.shared.copy(d)
                    m.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [m] in m.copied = false }
                }
                .foregroundColor(m.copied ? .green : nil)
                IconButton(symbol: "play.fill", help: "Play") { AppState.shared.play(d) }
                IconButton(symbol: "trash", help: "Delete") { HistoryUndo.shared.delete(d) }
            }
            Text(d.text)
                .font(Theme.sans(14))
                .lineSpacing(2)
                .lineLimit(m.expanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(m.expanded ? "Less" : "More") { m.expanded.toggle() }
                    .buttonStyle(.borderless).font(Theme.sans(12, .medium))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(m.hover ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { m.hover = $0 }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct MeetingRow: View {
    let m: Meeting
    let live: Bool
    @StateObject private var rm = RowModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(Self.time.string(from: m.start)).font(Theme.sans(11)).foregroundStyle(.secondary)
                Text(live ? "· Recording…" : "· \(max(1, Int(m.duration / 60))) min")
                    .font(Theme.sans(11)).foregroundColor(live ? .red : .secondary)
                Spacer()
                IconButton(symbol: "text.alignleft", help: "Open transcript") { open() }
                IconButton(symbol: rm.copied ? "checkmark" : "doc.on.doc", help: "Copy transcript") {
                    AppState.shared.copy(m)
                    rm.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [rm] in rm.copied = false }
                }
                .foregroundColor(rm.copied ? .green : nil)
                if !live {
                    IconButton(symbol: "record.circle", help: "Resume taking notes") {
                        MeetingPanel.shared.onResume?(m.id)
                    }
                    .disabled(AppState.shared.live != nil || AppState.shared.phase != .idle)
                    IconButton(symbol: "trash", help: "Delete") { AppState.shared.delete(m) }
                }
            }
            Text(m.segments.isEmpty ? "Listening…" : m.segments.prefix(3).map(\.text).joined(separator: " "))
                .font(Theme.sans(14))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(rm.hover ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { rm.hover = $0 }
        .onTapGesture(count: 2) { open() }
    }

    private func open() {
        if live { MeetingPanel.shared.showLive() } else { MeetingPanel.shared.show(m) }
    }
}
