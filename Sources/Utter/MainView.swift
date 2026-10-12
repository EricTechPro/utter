import SwiftUI
import ServiceManagement
import AppKit

/// Small observable holders instead of @State: the Command Line Tools SDK
/// ships without the SwiftUI macro plugin that @State needs.
final class SearchModel: ObservableObject {
    @Published var text = ""
    @Published var tab = "dictations"
}
final class RowModel: ObservableObject {
    @Published var hover = false
    @Published var copied = false
}

/// Main window: sidebar (Dictation · Notetaker · Settings) and a setup checklist,
/// with the selected page on a raised card to the right.
struct MainView: View {
    @ObservedObject var state = AppState.shared
    @StateObject private var searchModel = SearchModel()
    private var search: String { searchModel.text }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
                .padding(.top, 38).padding(.trailing, 12).padding(.bottom, 12)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.cream)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .bold))
                Text("Utter").font(Theme.sans(24, .bold))
                Text("Local").font(Theme.sans(13, .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.blue.opacity(0.14)))
                    .foregroundColor(Theme.blue)
            }
            .padding(.leading, 10).padding(.top, 44).padding(.bottom, 22)

            navItem("dictations", "Dictation", "mic")
            navItem("meetings", "Notetaker", "record.circle")
            navItem("settings", "Settings", "gearshape")

            setupCard.padding(.top, 18)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(state.status).font(Theme.sans(13)).foregroundColor(.black.opacity(0.55))
            }
            .padding(.leading, 12).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 236)
    }

    private func navItem(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { searchModel.tab = id } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                Text(title).font(Theme.sans(16, .medium))
                Spacer()
                if id == "meetings" && state.live != nil {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(searchModel.tab == id ? Color.black.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Set up Utter" checklist with a progress bar, ticking itself off.
    private var setupCard: some View {
        let steps: [(String, Bool)] = [
            ("Allow microphone", state.micOK),
            ("Allow accessibility", state.axOK),
            ("Try a dictation", !state.entries.isEmpty),
            ("Try Notetaker", !state.meetings.isEmpty || state.live != nil),
            ("Let meetings hear others", state.screenOK),
        ]
        let done = steps.filter(\.1).count
        return Group {
            if done < steps.count {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Set up Utter").font(Theme.sans(14, .semibold))
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.07))
                            Capsule().fill(Theme.blue).frame(width: g.size.width * CGFloat(done) / CGFloat(steps.count))
                        }
                    }
                    .frame(height: 6)
                    ForEach(steps, id: \.0) { step in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().stroke(step.1 ? Color.clear : Color.black.opacity(0.35), lineWidth: 1.5)
                                if step.1 {
                                    Circle().fill(Theme.blue.opacity(0.14))
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.blue)
                                }
                            }
                            .frame(width: 20, height: 20)
                            Text(step.0).font(Theme.sans(13)).foregroundColor(.black.opacity(step.1 ? 0.5 : 0.85))
                        }
                    }
                    Button("Finish setup") { Onboarding.shared.show() }
                        .font(Theme.sans(13, .medium))
                        .padding(.top, 2)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
            }
        }
    }

    private var dotColor: Color {
        switch state.phase {
        case .recording: return .red
        case .working: return .orange
        case .idle: return state.axOK && state.micOK ? .green : .gray
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch searchModel.tab {
        case "meetings": meetingsPage
        case "settings": SettingsPage()
        default: dictationPage
        }
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    private var dictationPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Welcome back, \(firstName)").font(Theme.sans(30, .semibold))
            HStack(alignment: .top, spacing: 18) {
                hero
                statsCard
            }
            .fixedSize(horizontal: false, vertical: true)
            listHeader("Today's words and more")
            history
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
    }

    /// Dark banner with a short message about the app.
    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.2), Color(red: 0.08, green: 0.25, blue: 0.62)],
                                     startPoint: .leading, endPoint: .trailing))
            HeroWave().padding(.leading, 260).opacity(0.5)
            VStack(alignment: .leading, spacing: 10) {
                (Text("Your voice stays on ").font(Theme.serif(32)) + Text("your Mac").font(Theme.serif(32).italic()))
                    .foregroundColor(.white)
                Text("Press ⌥1 anywhere to talk. Words are written right here, offline.")
                    .font(Theme.sans(15)).foregroundColor(.white.opacity(0.85))
                Button { Onboarding.shared.show() } label: {
                    Text(state.micOK && state.axOK ? "Try it" : "Finish setup")
                        .font(Theme.sans(15, .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(30)
        }
        .frame(minHeight: 200)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            statLine(state.totalWords.formatted(), "total words")
            statLine("\(state.wordsPerMinute)", "wpm")
            statLine(state.todayWords.formatted(), "words today")
        }
        .padding(24)
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
    }

    private func statLine(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(Theme.serif(36))
            Text(label).font(Theme.sans(16)).foregroundColor(.black.opacity(0.75))
        }
    }

    private func listHeader(_ title: String) -> some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchModel.text).textFieldStyle(.plain).font(Theme.sans(14)).frame(width: 170)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.cream))
        }
        .padding(.bottom, -12)
    }

    private var meetingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notetaker").font(Theme.sans(30, .semibold))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .utterToggleNotes, object: nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: state.live == nil ? "record.circle" : "stop.fill")
                        Text(state.live == nil ? "Start Notetaker" : "Stop Notetaker")
                    }
                    .font(Theme.sans(15, .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(state.live == nil ? Color.black : Color.red))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            Text("Live transcripts of your meetings, split into You and Others. Also on the dock at the left edge of your screen.")
                .font(Theme.sans(15)).foregroundColor(.black.opacity(0.6))
            if !state.screenOK { screenBanner }
            listHeader("")
            meetingsList
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
    }

    private var screenBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange)
            Text("To hear the other people in a meeting, allow **Screen Recording** for Utter, then reopen Utter.")
                .font(Theme.sans(13))
            Spacer()
            Button("Screen Recording…") {
                CGRequestScreenCaptureAccess()
                openSettings("Privacy_ScreenCapture")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
    }

    private var meetingsList: some View {
        let items = state.meetings.filter {
            search.isEmpty || $0.transcript.localizedCaseInsensitiveContains(search)
        }
        return Group {
            if items.isEmpty && state.live == nil {
                VStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No meetings yet.").font(Theme.sans(15)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.cream.opacity(0.5)))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let live = state.live {
                            MeetingRow(m: live, live: true)
                            Divider().padding(.leading, 24)
                        }
                        ForEach(items) { m in
                            MeetingRow(m: m, live: false)
                            if m.id != items.last?.id { Divider().padding(.leading, 24) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            }
        }
    }

    private var filtered: [Dictation] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? state.entries : state.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var history: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(state.entries.isEmpty ? "No dictations yet. Press ⌥1 anywhere and talk." : "No matches.")
                        .font(Theme.sans(15)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.cream.opacity(0.5)))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.title) { g in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(g.items) { d in
                                        DictationRow(d: d)
                                        if d.id != g.items.last?.id { Divider() }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                                .padding(.bottom, 18)
                            } header: {
                                Text(g.title.uppercased())
                                    .font(Theme.sans(14, .semibold)).tracking(1.5)
                                    .foregroundColor(.black.opacity(0.55))
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.card)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groups: [(title: String, items: [Dictation])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return byDay.keys.sorted(by: >).map { day in
            let title = cal.isDateInToday(day) ? "Today" : cal.isDateInYesterday(day) ? "Yesterday" : fmt.string(from: day)
            return (title, byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// Soft white bars drawn across the hero banner.
private struct HeroWave: View {
    private let heights: [CGFloat] = [0.2, 0.35, 0.6, 0.4, 0.8, 0.55, 0.95, 0.5, 0.7, 0.3, 0.65, 0.45, 0.85, 0.4, 0.25, 0.5, 0.3, 0.15]
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: g.size.width / CGFloat(heights.count * 2)) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                    Capsule().fill(Color.white.opacity(0.35))
                        .frame(width: g.size.width / CGFloat(heights.count * 2), height: g.size.height * h * 0.8)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// Permissions, shortcuts and where data lives.
private struct SettingsPage: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var login = LoginItemModel.shared
    @AppStorage(Startup.showInDockKey) private var showInDock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(Theme.sans(30, .semibold))
            section("Permissions") {
                row("Microphone", state.micOK, "Privacy_Microphone")
                row("Accessibility (shortcut and pasting)", state.axOK, "Privacy_Accessibility")
                row("Screen Recording (meetings hear others)", state.screenOK, "Privacy_ScreenCapture")
            }
            section("General") {
                Toggle("Open at login", isOn: Binding(get: { login.on }, set: { login.set($0) }))
                .font(Theme.sans(15)).toggleStyle(.switch)
                if login.needsApproval {
                    HStack {
                        Text("Allow Utter in Login Items to finish turning this on.").font(Theme.sans(13))
                            .foregroundColor(.black.opacity(0.55))
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Show in Dock", isOn: $showInDock)
                    .font(Theme.sans(15)).toggleStyle(.switch)
                    .onChange(of: showInDock) { _ in Startup.applyDockPolicy() }
            }
            section("Shortcuts") {
                line("Start / stop dictation", "⌥1")
                line("Cancel while recording", "Esc")
                line("Meeting notes", "Record button on the left edge")
            }
            section("Your data") {
                HStack {
                    Text("History, audio and meeting notes stay on this Mac.").font(Theme.sans(14))
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(state.dataDir) }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 24)
        // The menu-bar menu or System Settings may have changed it.
        .onAppear { login.refresh() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(Theme.sans(13, .semibold)).tracking(1.4).foregroundColor(.black.opacity(0.55))
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        }
    }

    private func row(_ title: String, _ ok: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundColor(ok ? .green : .secondary)
            Text(title).font(Theme.sans(15))
            Spacer()
            if !ok {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.sans(15))
            Spacer()
            Text(value).font(Theme.sans(15, .medium)).foregroundColor(.black.opacity(0.6))
        }
    }
}

private struct StatCard: View {
    let value: Int
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.formatted()).font(Theme.serif(34))
            Text(label).font(Theme.sans(16)).foregroundColor(.black.opacity(0.8))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

private struct DictationRow: View {
    let d: Dictation
    @StateObject private var m = RowModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.time.string(from: d.date)).font(Theme.sans(15)).foregroundColor(.black.opacity(0.55))
                if let app = d.app {
                    Text(app).font(Theme.sans(11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(width: 96, alignment: .leading)

            Text(d.text)
                .font(Theme.sans(17))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                IconButton(symbol: "play.fill", help: "Play audio") { AppState.shared.play(d) }
                IconButton(symbol: m.copied ? "checkmark" : "doc.on.doc", help: "Copy text") {
                    AppState.shared.copy(d)
                    m.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [m] in m.copied = false }
                }
                IconButton(symbol: "trash", help: "Delete") { AppState.shared.delete(d) }
            }
            .opacity(m.hover || m.copied ? 1 : 0.35)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(m.hover ? Color.black.opacity(0.03) : Color.clear)
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
            Image(systemName: symbol).font(Theme.sans(13)).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

extension Notification.Name {
    static let utterToggleNotes = Notification.Name("utterToggleNotes")
}

private struct MeetingRow: View {
    let m: Meeting
    let live: Bool
    @StateObject private var rm = RowModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.time.string(from: m.start)).font(Theme.sans(13)).foregroundStyle(.secondary)
                Text(live ? "Recording…" : "\(max(1, Int(m.duration / 60))) min")
                    .font(Theme.sans(11)).foregroundColor(live ? .red : .secondary)
            }
            .frame(width: 110, alignment: .leading)

            Text(m.segments.isEmpty ? "Listening…" : m.segments.prefix(3).map(\.text).joined(separator: " "))
                .font(Theme.sans(15))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                IconButton(symbol: "text.alignleft", help: "Open transcript") {
                    if live { MeetingPanel.shared.showLive() } else { MeetingPanel.shared.show(m) }
                }
                IconButton(symbol: rm.copied ? "checkmark" : "doc.on.doc", help: "Copy transcript") {
                    AppState.shared.copy(m)
                    rm.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [rm] in rm.copied = false }
                }
                if !live {
                    IconButton(symbol: "record.circle", help: "Resume taking notes") {
                        MeetingPanel.shared.onResume?(m.id)
                    }
                    .disabled(AppState.shared.live != nil)
                    IconButton(symbol: "trash", help: "Delete") { AppState.shared.delete(m) }
                }
            }
            .opacity(rm.hover || rm.copied ? 1 : 0.35)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(rm.hover ? Color.black.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { rm.hover = $0 }
        .onTapGesture(count: 2) {
            if live { MeetingPanel.shared.showLive() } else { MeetingPanel.shared.show(m) }
        }
    }
}
