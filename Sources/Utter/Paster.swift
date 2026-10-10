import AppKit
import Carbon.HIToolbox

/// Save the clipboard, put the text on it,
/// send Cmd+V (keycode 9 + Command flag), then put the old clipboard back.
enum Paster {
    static func insert(_ text: String) {
        // Password fields turn on secure input; synthetic keys won't land there.
        if IsSecureEventInputEnabled() {
            NSLog("Utter: secure input is on, not pasting")
            NSSound.beep()
            return
        }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text + " ", forType: .string)
        let ourChange = pb.changeCount

        postCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Don't clobber something the user copied in the meantime.
            guard pb.changeCount == ourChange else { return }
            restore(saved, to: pb)
        }
    }

    private static func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { entry[t] = d } }
            return entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in entry { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }
}
