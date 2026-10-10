import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Save the clipboard, put the text on it,
/// send Cmd+V (keycode 9 + Command flag), then put the old clipboard back.
///
/// The text is offered lazily, so we can tell whether any app actually asked for it.
/// If nothing did (no text box was focused), the text stays on the clipboard and
/// `onFail` is called so the user can be shown a Copy popup.
enum Paster {
    static func insert(_ text: String, onFail: @escaping (String) -> Void = { _ in }) {
        // Password fields turn on secure input; synthetic keys won't land there.
        if IsSecureEventInputEnabled() {
            NSLog("Utter: secure input is on, not pasting")
            putOnClipboard(text)
            onFail(text)
            return
        }

        // Nothing focused at all (e.g. the desktop): don't send a stray Cmd+V.
        if !hasFocusedElement() {
            putOnClipboard(text)
            onFail(text)
            return
        }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        let provider = LazyText(text + " ")
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pb.clearContents()
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        postCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Don't clobber something the user copied in the meantime.
            guard pb.changeCount == ourChange else { return }
            if provider.requested {
                restore(saved, to: pb)
            } else {
                // No app took it: leave the words on the clipboard instead of the old contents.
                putOnClipboard(text)
                onFail(text)
            }
        }
    }

    static func putOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func hasFocusedElement() -> Bool {
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                kAXFocusedUIElementAttribute as CFString, &focused)
        // Only skip when AX positively says nothing is focused. Apps that don't answer
        // (.noValue / errors, common in Electron and Chrome) still get the paste; the
        // lazy-provider check below decides whether it landed.
        return err != .success || focused != nil
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

/// Hands the text to whichever app pastes, and remembers that someone asked.
private final class LazyText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    private(set) var requested = false

    init(_ text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requested = true
        item.setString(text, forType: type)
    }
}
