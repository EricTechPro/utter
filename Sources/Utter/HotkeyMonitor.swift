import AppKit
import Carbon.HIToolbox

/// Option+1 toggles recording; Escape cancels while recording.
/// Uses an active CGEventTap (needs Accessibility) so the keys are swallowed
/// instead of typing "¡" into the focused app.
final class HotkeyMonitor {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Escape is only swallowed while this returns true.
    var isRecording: () -> Bool = { false }

    private var tap: CFMachPort?

    /// Returns false until Accessibility has been granted.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns slow taps off; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if code == kVK_ANSI_1 && mods == .maskAlternate {
            if !isRepeat { DispatchQueue.main.async { self.onToggle?() } }
            return nil
        }
        if code == kVK_Escape && mods.isEmpty && isRecording() {
            DispatchQueue.main.async { self.onCancel?() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
