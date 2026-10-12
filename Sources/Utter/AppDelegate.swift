import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let pill = RecordingPill()
    private let dock = Dock()
    private let reminder = MeetingReminder()
    private var notetaker: Notetaker?
    private var streaming: StreamingDictation?
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private var transcriber: Transcriber?
    private var hotkeyStarted = false
    private var permissionTimer: Timer?
    private var targetApp: String?
    /// Opened by macOS at login: start quietly (menu bar and dock capsule, no window).
    private var quietLaunch = false
    private var bag = Set<AnyCancellable>()
    private let dictateItem = NSMenuItem(title: "Start Dictation", action: #selector(menuDictate), keyEquivalent: "1")
    private let notesItem = NSMenuItem(title: "Start Notetaker", action: #selector(menuNotes), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(menuLogin), keyEquivalent: "")
    private let dockItem = NSMenuItem(title: "Show in Dock", action: #selector(menuDock), keyEquivalent: "")

    func applicationWillFinishLaunching(_ notification: Notification) {
        quietLaunch = Startup.launchedAtLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic", "Utter: idle")
        // Menu-bar menu: dictate, notes, open the window, startup options, quit.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        dictateItem.keyEquivalentModifierMask = .option   // shows ⌥1, the global shortcut
        for item in [dictateItem, notesItem, loginItem, dockItem] { item.target = self }
        menu.addItem(dictateItem)
        menu.addItem(notesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Utter", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(dockItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        // Red while dictating or taking notes.
        for pub in [state.$phase.map { _ in () }.eraseToAnyPublisher(), state.$live.map { _ in () }.eraseToAnyPublisher()] {
            pub.receive(on: RunLoop.main).sink { [weak self] in
                DispatchQueue.main.async { self?.refreshTint() }
            }.store(in: &bag)
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Utter"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView())
        window.setFrameAutosaveName("UtterMain")
        if window.frame.origin == .zero { window.center() }
        if !quietLaunch { showWindow() }
        dock.onDictate = { [weak self] in self?.toggle() }
        dock.onNotes = { [weak self] in self?.toggleNotes() }
        dock.show()
        // Calendar meeting card: Join the call or start notes.
        reminder.onStartNotes = { [weak self] in
            if self?.notetaker?.isRunning != true { self?.toggleNotes() }
        }
        reminder.start()
        MeetingPanel.shared.onStop = { [weak self] in self?.toggleNotes() }
        MeetingPanel.shared.onResume = { [weak self] id in self?.toggleNotes(resume: id) }
        NotificationCenter.default.addObserver(forName: .utterToggleNotes, object: nil, queue: .main) { [weak self] _ in
            self?.toggleNotes()
        }

        Startup.configureOnFirstRun()

        // `--start-notes` starts meeting notes a moment after launch (for testing the panel).
        if CommandLine.arguments.contains("--start-notes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.toggleNotes() }
        }

        do {
            let t = try Transcriber.fromBundle()
            transcriber = t
            notetaker = Notetaker(transcriber: t)
            streaming = StreamingDictation(transcriber: t)
            notetaker?.onWarning = { MeetingPanel.shared.model.warning = $0 }
        } catch {
            state.status = "❌ \(error.localizedDescription)"
        }


        // Setup walkthrough for anything not allowed yet; the timer below keeps checking.
        state.refreshPermissions()
        Onboarding.shared.showIfNeeded()

        hotkey.onToggle = { [weak self] in self?.toggle() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.isRecording = { [weak self] in self?.state.phase == .recording }
        pill.onDone = { [weak self] in self?.finish() }
        pill.onCancel = { [weak self] in self?.cancel() }
        recorder.onLevel = { [weak self] level in self?.pill.push(level: level) }
        recorder.onSamples = { [weak self] s in self?.streaming?.feed(s) }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
        checkPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let live = notetaker?.isRunning == true
        dictateItem.title = state.phase == .recording ? "Stop Dictation" : "Start Dictation"
        dictateItem.isEnabled = state.phase != .working && transcriber != nil
        notesItem.title = live ? "Stop Notetaker" : "Start Notetaker"
        notesItem.isEnabled = notetaker != nil && (live || state.phase == .idle)
        loginItem.state = Startup.openAtLogin ? .on : .off
        dockItem.state = Startup.showInDock ? .on : .off
    }

    @objc private func menuDictate() { toggle() }
    @objc private func menuNotes() { toggleNotes() }
    @objc private func menuLogin() { LoginItemModel.shared.set(!Startup.openAtLogin) }
    @objc private func menuDock() { Startup.showInDock.toggle() }

    func applicationWillTerminate(_ notification: Notification) {
        if notetaker?.isRunning == true { state.endMeeting() }
    }

    private func toggleNotes() { toggleNotes(resume: nil) }

    /// Starts or stops meeting notes. With `resume`, continues that finished meeting.
    private func toggleNotes(resume: UUID?) {
        guard let notetaker else { return }
        // No meeting while dictating (dock button, calendar card, resume or any other caller).
        if !notetaker.isRunning, state.phase != .idle { return }
        if notetaker.isRunning {
            notetaker.stop()
            Chime.playStop()
        } else {
            MeetingPanel.shared.model.warning = nil
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            notetaker.start(resume: resume)
            Chime.playStart()
            MeetingPanel.shared.showLive()
        }
    }

    private func checkPermissions() {
        state.refreshPermissions()
        guard !hotkeyStarted, transcriber != nil else { return }
        if state.axOK, hotkey.start() {
            hotkeyStarted = true
            state.status = "Ready"
        } else {
            state.status = "Waiting for Accessibility…"
        }
    }

    private func toggle() {
        switch state.phase {
        case .idle: start()
        case .recording: finish()
        case .working: break
        }
    }

    private func start() {
        do {
            targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            streaming?.start()
            try recorder.start()
            state.phase = .recording
            Chime.playStart()
            pill.showRecording()
            setIcon("mic.fill", "Utter: listening")
            state.status = "Listening…"
        } catch {
            NSLog("Utter: recorder failed: \(error)")
            setIcon("mic.slash", "Utter: mic error")
            state.status = "❌ Mic error"
        }
    }

    private func cancel() {
        guard state.phase == .recording else { return }
        _ = recorder.stop()
        streaming?.cancel()
        Chime.playCancel()
        reset("Cancelled")
    }

    private func finish() {
        guard state.phase == .recording, let transcriber else { return }
        let samples = recorder.stop()
        Chime.playStop()
        let seconds = Double(samples.count) / Recorder.sampleRate

        // Ignore recordings shorter than 0.3 s.
        guard seconds > 0.3 else { streaming?.cancel(); return reset("Too short") }

        state.phase = .working
        pill.showWorking()
        setIcon("ellipsis.circle", "Utter: transcribing")
        state.status = "Writing it down…"
        let app = targetApp
        let started = Date()
        // Most of the text was already written while you talked; this only does the last bit.
        // If any piece failed, fall back to one pass over the whole recording.
        streaming?.finish { streamed in
            if let streamed, !streamed.isEmpty || seconds < 1 {
                NSLog("Utter: dictation ready \(Int(Date().timeIntervalSince(started) * 1000)) ms after stop (\(Int(seconds)) s of audio)")
                self.deliver(.success(streamed), seconds: seconds, app: app, samples: samples)
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try transcriber.transcribe(samples: samples) }
                    DispatchQueue.main.async { self.deliver(result, seconds: seconds, app: app, samples: samples) }
                }
            }
        }
    }

    private func deliver(_ result: Result<String, Error>, seconds: Double, app: String?, samples: [Float]) {
        switch result {
        case .success(let text) where !text.isEmpty:
            Paster.insert(text) { PasteFallback.shared.show($0) }
            state.add(text: text, seconds: seconds, app: app, samples: samples)
            reset("Ready")
        case .success:
            reset("Heard nothing")
        case .failure(let error):
            NSLog("Utter: \(error.localizedDescription)")
            reset("❌ Transcription failed")
        }
    }

    private func reset(_ status: String) {
        state.phase = .idle
        state.status = status
        pill.hide()
        setIcon("mic", "Utter: idle")
    }

    private func setIcon(_ symbol: String, _ label: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        statusItem.button?.toolTip = label
        refreshTint()
    }

    private func refreshTint() {
        let active = state.phase != .idle || state.live != nil
        statusItem.button?.contentTintColor = active ? .systemRed : nil
    }
}
