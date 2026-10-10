import AppKit
import SwiftUI

// Dock app with a history window. Option+1 starts and stops dictation.
let app = NSApplication.shared

// `Utter --snapshot out.png` renders the main window to a PNG and exits (for checking the UI).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    Theme.registerFonts()
    let view = NSHostingView(rootView: MainView())
    view.frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
    let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `Utter --test-notes in.wav` runs a 16 kHz mono WAV through the meeting chunker + whisper.
if let i = CommandLine.arguments.firstIndex(of: "--test-notes"), i + 1 < CommandLine.arguments.count {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let samples = pcm.map { Float($0) / Float(Int16.max) }
    let t = try! Transcriber.fromBundle()
    let chunker = Chunker { s, off in
        let text = (try? t.transcribe(samples: s)) ?? "<error>"
        print(String(format: "[%5.1fs +%4.1fs] %@", off, Double(s.count) / 16000, text))
    }
    // Feed it in 40 ms pieces, like the live mic.
    stride(from: 0, to: samples.count, by: 640).forEach { chunker.append(Array(samples[$0..<min($0 + 640, samples.count)])) }
    chunker.flush()
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
