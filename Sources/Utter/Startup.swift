import AppKit
import ServiceManagement

/// Open-at-login state for the Settings switch.
final class LoginItemModel: ObservableObject {
    static let shared = LoginItemModel()
    @Published private(set) var on = Startup.openAtLogin
    @Published private(set) var needsApproval = Startup.loginNeedsApproval

    func set(_ value: Bool) { Startup.setOpenAtLogin(value); refresh() }

    func refresh() {
        if on != Startup.openAtLogin { on = Startup.openAtLogin }
        if needsApproval != Startup.loginNeedsApproval { needsApproval = Startup.loginNeedsApproval }
    }
}

/// Opening at login and whether Utter shows in the Dock.
/// Utter lives in the menu bar; the Dock icon is optional ("Show in Dock", off by default).
enum Startup {
    static let showInDockKey = "showInDock"
    private static let loginConfiguredKey = "openAtLoginConfigured"

    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: showInDockKey) }
        set { UserDefaults.standard.set(newValue, forKey: showInDockKey); applyDockPolicy() }
    }

    /// Menu-bar only unless "Show in Dock" is on. Accessory apps also keep their floating
    /// panels (pill, dock capsule) reliably on every Space, full-screen apps included.
    static func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    static var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS turned the login item off in System Settings, or it's waiting for approval there.
    static var loginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Utter: open at login \(on ? "on" : "off") failed: \(error)")
        }
    }

    /// Open at login is on by default: turned on once, the first time Utter runs from
    /// /Applications. After that it's whatever you chose in Settings or the menu.
    static func configureOnFirstRun() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: loginConfiguredKey) else { return }
        UserDefaults.standard.set(true, forKey: loginConfiguredKey)
        setOpenAtLogin(true)
    }

    /// True when macOS opened Utter because you logged in (so it starts quietly).
    /// Read it before the launch finishes, while the "open application" event is current.
    static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
