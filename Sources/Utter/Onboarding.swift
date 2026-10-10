import AppKit
import SwiftUI
import ApplicationServices
import AVFoundation

final class OnboardingModel: ObservableObject {
    @Published var tryText = ""
}

/// First-run setup: every permission Utter needs, with live checkmarks,
/// then a box to try dictation in. Shown at launch until everything required is set.
final class Onboarding {
    static let shared = Onboarding()
    private static let doneKey = "onboardingDone"
    private var window: NSWindow?

    /// Required to dictate at all. Screen Recording is optional (meetings only).
    static var requiredMissing: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !AXIsProcessTrusted()
    }

    func showIfNeeded() {
        if Self.requiredMissing || !UserDefaults.standard.bool(forKey: Self.doneKey) { show() }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: OnboardingView(done: { [weak self] in self?.finish() }))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}

private struct OnboardingView: View {
    @ObservedObject var state = AppState.shared
    @StateObject private var model = OnboardingModel()
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Utter").font(Theme.serif(36))
                Text("Three quick steps. The checkmarks turn green by themselves.")
                    .font(Theme.sans(15)).foregroundColor(.black.opacity(0.6))
            }

            StepRow(n: 1, title: "Microphone", detail: "So Utter can hear you.",
                    ok: state.micOK, button: "Allow") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { AppState.shared.refreshPermissions() }
                }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { open("Privacy_Microphone") }
            }
            StepRow(n: 2, title: "Accessibility", detail: "For the ⌥1 shortcut and to paste your words.",
                    ok: state.axOK, button: "Open Settings") {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                open("Privacy_Accessibility")
            }
            StepRow(n: 3, title: "Screen Recording (for meetings)",
                    detail: "Lets meeting notes hear the other people. Reopen Utter after allowing.",
                    ok: state.screenOK, button: "Open Settings", optional: true) {
                CGRequestScreenCaptureAccess()
                open("Privacy_ScreenCapture")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Try it").font(Theme.sans(17, .semibold))
                Text("Click the box, press ⌥1, say something, then press ⌥1 again.")
                    .font(Theme.sans(14)).foregroundColor(.black.opacity(0.6))
                TextField("Your words show up here…", text: $model.tryText)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(16))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .disabled(!(state.micOK && state.axOK))
            }
            .padding(.top, 4)

            Spacer()

            HStack {
                if !(state.micOK && state.axOK) {
                    Text("Microphone and Accessibility are needed to dictate.")
                        .font(Theme.sans(13)).foregroundColor(.orange)
                }
                Spacer()
                Button(action: done) {
                    Text(state.micOK && state.axOK ? "Done" : "Later")
                        .font(Theme.sans(15, .semibold))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Capsule().fill(state.micOK && state.axOK ? Color.black : Color.black.opacity(0.08)))
                        .foregroundColor(state.micOK && state.axOK ? .white : .black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(width: 560, height: 640)
        .background(Theme.cream)
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct StepRow: View {
    let n: Int
    let title: String
    let detail: String
    let ok: Bool
    let button: String
    var optional = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(ok ? Color.green : Color.black.opacity(0.08)).frame(width: 34, height: 34)
                if ok {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(n)").font(Theme.sans(15, .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.sans(16, .semibold))
                    if optional && !ok {
                        Text("optional").font(Theme.sans(12)).foregroundColor(.black.opacity(0.5))
                    }
                }
                Text(detail).font(Theme.sans(13)).foregroundColor(.black.opacity(0.6))
            }
            Spacer()
            if ok {
                Text("Done").font(Theme.sans(14, .medium)).foregroundColor(.green)
            } else {
                Button(button, action: action)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ok ? Color.green.opacity(0.4) : Theme.line))
    }
}
