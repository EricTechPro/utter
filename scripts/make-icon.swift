// Renders the Utter app icon (1024x1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(colors: [NSColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
                    NSColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)])!.draw(in: path, angle: -90)
// Waveform bars
let heights: [Double] = [0.22, 0.42, 0.62, 0.36, 0.52, 0.30, 0.18]
let barW = size * 0.055, gap = size * 0.035
let total = Double(heights.count) * barW + Double(heights.count - 1) * gap
var x = size / 2 - total / 2
NSColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1).setFill()
for h in heights {
    let bh = size * h
    NSBezierPath(roundedRect: NSRect(x: x, y: size / 2 - bh / 2, width: barW, height: bh),
                 xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
