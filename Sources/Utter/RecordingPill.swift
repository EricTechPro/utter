import AppKit

/// Black pill at the bottom of the screen while recording:
/// ✕ (cancel) · live waveform · ✓ (stop and paste).
/// It's a non-activating panel, so clicking it doesn't steal focus from the
/// text box the words should go into.
final class RecordingPill {
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private let panel: NSPanel
    private let wave = WaveformView()
    private let spinner = NSProgressIndicator()
    private let size = NSSize(width: 190, height: 44)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bg.layer?.borderWidth = 1

        let cancel = CircleButton(symbol: "xmark", fill: NSColor(white: 0.35, alpha: 1), tint: .white)
        cancel.target = self; cancel.action = #selector(cancelTapped)
        cancel.toolTip = "Cancel (Esc)"
        let done = CircleButton(symbol: "checkmark", fill: .white, tint: .black)
        done.target = self; done.action = #selector(doneTapped)
        done.toolTip = "Stop and paste (Option+1)"

        cancel.frame = NSRect(x: 7, y: 7, width: 30, height: 30)
        done.frame = NSRect(x: size.width - 37, y: 7, width: 30, height: 30)
        wave.frame = NSRect(x: 46, y: 8, width: size.width - 92, height: 28)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.frame = NSRect(x: (size.width - 16) / 2, y: (size.height - 16) / 2, width: 16, height: 16)
        spinner.isHidden = true

        [cancel, wave, spinner, done].forEach(bg.addSubview)
        panel.contentView = bg
    }

    func showRecording() {
        wave.reset()
        wave.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        place()
        panel.orderFrontRegardless()
    }

    func showWorking() {
        wave.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func hide() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    func push(level: Float) { wave.push(level) }

    /// Bottom-centre of the screen the mouse is on.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 24))
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func doneTapped() { onDone?() }
}

private final class CircleButton: NSButton {
    init(symbol: String, fill: NSColor, tint: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 15
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        contentTintColor = tint
        imagePosition = .imageOnly
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks register even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Scrolling bars driven by mic loudness.
private final class WaveformView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 22)

    func reset() { levels = levels.map { _ in 0 }; needsDisplay = true }

    func push(_ rms: Float) {
        // RMS -> 0...1 on a -50...-10 dB scale.
        let db = 20 * log10(max(rms, 1e-6))
        let v = CGFloat(min(max((db + 50) / 40, 0), 1))
        levels.removeFirst()
        levels.append(v)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        let n = CGFloat(levels.count)
        let barW: CGFloat = 2.5
        let gap = (bounds.width - barW * n) / max(n - 1, 1)
        for (i, v) in levels.enumerated() {
            let h = max(3, v * bounds.height)
            let x = CGFloat(i) * (barW + gap)
            let r = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
