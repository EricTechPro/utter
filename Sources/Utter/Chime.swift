import AVFoundation

/// Soft two-note chimes made in code, so there are no sound files to ship.
/// Start rises (E5 → A5), stop falls (A5 → E5).
enum Chime {
    private static let rate = 44_100.0
    private static let start = player(notes: [659.25, 880.0])
    private static let stop = player(notes: [880.0, 659.25])
    private static let cancel = player(notes: [440.0, 349.23])

    static func playStart() { replay(start) }
    static func playStop() { replay(stop) }
    static func playCancel() { replay(cancel) }

    private static func replay(_ p: AVAudioPlayer?) {
        p?.currentTime = 0
        p?.play()
    }

    private static func player(notes: [Double]) -> AVAudioPlayer? {
        let noteLen = 0.09, tail = 0.22
        let total = Int((noteLen * Double(notes.count - 1) + tail) * rate)
        var buf = [Float](repeating: 0, count: total)
        for (i, f) in notes.enumerated() {
            let startIdx = Int(Double(i) * noteLen * rate)
            let len = Int(tail * rate)
            for n in 0..<len where startIdx + n < total {
                let t = Double(n) / rate
                // Quick attack, exponential decay; a little 2nd harmonic for a bell-ish tone.
                let env = min(t / 0.005, 1) * exp(-t * 18)
                let s = sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)
                buf[startIdx + n] += Float(s * env * 0.18)
            }
        }
        var pcm = Data(capacity: total * 2)
        for s in buf {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        let r = UInt32(rate)
        h.append("RIFF".data(using: .ascii)!); u32(36 + UInt32(pcm.count))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(r); u32(r * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        let p = try? AVAudioPlayer(data: h + pcm)
        p?.prepareToPlay()
        return p
    }
}
