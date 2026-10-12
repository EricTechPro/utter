import AppKit
import SwiftUI

// Dock app with a history window. Option+1 starts and stops dictation.
let app = NSApplication.shared

// `Utter --snapshot out.png [--tab history|notes|settings] [--dark]` renders the menu-bar panel to a PNG and exits (for checking the UI).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    Theme.registerFonts()
    let args = CommandLine.arguments
    let tab = args.firstIndex(of: "--tab").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "history"
    let view = NSHostingView(rootView: MenuBarView(tab: tab, dictate: {}, toggleNotes: {}))
    view.frame = NSRect(origin: .zero, size: MenuBarView.size)
    view.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    view.wantsLayer = true
    view.appearance?.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
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

// `Utter --test-dictation in.wav` plays a 16 kHz WAV in real time through streaming dictation
// and prints how long the text took after the audio ended.
if let i = CommandLine.arguments.firstIndex(of: "--test-dictation"), i + 1 < CommandLine.arguments.count {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let samples = pcm.map { Float($0) / Float(Int16.max) }
    let t = try! Transcriber.fromBundle()
    Thread.sleep(forTimeInterval: 3)   // let the warm-up finish
    let s = StreamingDictation(transcriber: t)
    s.start()
    for start in stride(from: 0, to: samples.count, by: 640) {
        s.feed(Array(samples[start..<min(start + 640, samples.count)]))
        Thread.sleep(forTimeInterval: 0.04)
    }
    let stopped = Date()
    s.finish { text in
        print(String(format: "streamed: %.0f ms after stop", Date().timeIntervalSince(stopped) * 1000))
        print(text ?? "<failed>")
        let one = Date()
        let full = (try? t.transcribe(samples: samples)) ?? ""
        print(String(format: "one pass at the end would take: %.0f ms", Date().timeIntervalSince(one) * 1000))
        print(full)
        exit(0)
    }
    RunLoop.main.run()
}

let delegate = AppDelegate()
app.delegate = delegate
Startup.applyDockPolicy()
app.run()
