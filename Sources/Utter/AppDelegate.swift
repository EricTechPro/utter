import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let pill = RecordingPill()
    private let dock = Dock()
    private let reminder = MeetingReminder()
    private var notetaker: Notetaker?
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private var transcriber: Transcriber?
    private var hotkeyStarted = false
    private var permissionTimer: Timer?
    private var targetApp: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic", "Utter: idle")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Utter", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

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
        showWindow()
        dock.onDictate = { [weak self] in self?.toggle() }
        dock.onNotes = { [weak self] in self?.toggleNotes() }
        dock.show()
        // Calendar meeting card: Join the call or start notes.
        reminder.onStartNotes = { [weak self] in
            if self?.notetaker?.isRunning != true { self?.toggleNotes() }
        }
        reminder.start()
        MeetingPanel.shared.onStop = { [weak self] in self?.toggleNotes() }
        NotificationCenter.default.addObserver(forName: .utterToggleNotes, object: nil, queue: .main) { [weak self] _ in
            self?.toggleNotes()
        }

        registerLoginItem()

        do {
            let t = try Transcriber.fromBundle()
            transcriber = t
            notetaker = Notetaker(transcriber: t)
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

    /// Start Utter when the Mac starts. Only works from /Applications.
    private func registerLoginItem() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch { NSLog("Utter: login item failed: \(error)") }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if notetaker?.isRunning == true { state.endMeeting() }
    }

    private func toggleNotes() {
        guard let notetaker else { return }
        if notetaker.isRunning {
            notetaker.stop()
            Chime.playStop()
        } else {
            MeetingPanel.shared.model.warning = nil
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            notetaker.start()
            Chime.playStart()
            MeetingPanel.shared.showLive()
        }
    }

    private func checkPermissions() {
        state.refreshPermissions()
        // A meeting app has the mic open while we're idle: hint on the dock.
        let likely = state.phase == .idle && notetaker?.isRunning != true && Notetaker.micInUseSomewhere()
        if likely != state.meetingLikely { state.meetingLikely = likely }
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
        Chime.playCancel()
        reset("Cancelled")
    }

    private func finish() {
        guard state.phase == .recording, let transcriber else { return }
        let samples = recorder.stop()
        Chime.playStop()
        let seconds = Double(samples.count) / Recorder.sampleRate

        // Ignore recordings shorter than 0.3 s.
        guard seconds > 0.3 else { return reset("Too short") }

        state.phase = .working
        pill.showWorking()
        setIcon("ellipsis.circle", "Utter: transcribing")
        state.status = "Writing it down…"
        let app = targetApp
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try transcriber.transcribe(samples: samples) }
            DispatchQueue.main.async {
                switch result {
                case .success(let text) where !text.isEmpty:
                    Paster.insert(text) { PasteFallback.shared.show($0) }
                    self.state.add(text: text, seconds: seconds, app: app, samples: samples)
                    self.reset("Ready")
                case .success:
                    self.reset("Heard nothing")
                case .failure(let error):
                    NSLog("Utter: \(error.localizedDescription)")
                    self.reset("❌ Transcription failed")
                }
            }
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
    }
}
