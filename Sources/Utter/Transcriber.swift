import Foundation

/// Runs whisper.cpp locally. Nothing leaves the Mac.
struct Transcriber {
    let whisperPath: String
    let modelPath: String

    enum Failure: LocalizedError {
        case missing(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return "Missing \(what)."
            case .failed(let why): return "whisper-cli failed: \(why)"
            }
        }
    }

    /// The model ships inside the app (Resources/model.bin). whisper-cli is bundled next to the
    /// app binary when available, otherwise taken from Homebrew.
    static func fromBundle() throws -> Transcriber {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-cli").path
        let whisper = FileManager.default.isExecutableFile(atPath: bundled)
            ? bundled
            : info["UtterWhisperPath"] as? String ?? "/opt/homebrew/bin/whisper-cli"
        let model = Bundle.main.path(forResource: "model", ofType: "bin") ?? ""
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: whisper) else { throw Failure.missing("whisper-cli at \(whisper) (brew install whisper-cpp)") }
        guard fm.fileExists(atPath: model) else { throw Failure.missing("model at \(model)") }
        let t = Transcriber(whisperPath: whisper, modelPath: model)
        t.warmUp()
        return t
    }

    /// The first run on a Mac compiles GPU shaders (~20 s); do it once in the background
    /// with a second of silence so the user's first dictation is fast.
    private static var warmed = false
    func warmUp() {
        guard !Self.warmed else { return }
        Self.warmed = true
        DispatchQueue.global(qos: .utility).async {
            _ = try? self.transcribe(samples: [Float](repeating: 0, count: Int(Recorder.sampleRate)))
        }
    }

    func transcribe(samples: [Float]) throws -> String {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("utter-\(UUID().uuidString).wav")
        try Self.writeWav(samples, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperPath)
        // "auto": whisper picks the spoken language (English, Chinese, …) on each recording.
        p.arguments = ["-m", modelPath, "-f", wav.path, "-l", "auto", "-nt", "-np", "-t", "6"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.failed(why)
        }
        return Self.clean(String(data: data, encoding: .utf8) ?? "")
    }

    /// Joins lines and drops whisper's non-speech tags like [BLANK_AUDIO] or (music).
    static func clean(_ raw: String) -> String {
        let joined = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        let stripped = joined.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
        let text = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.range(of: #"\p{Han}"#, options: .regularExpression) == nil ? text : chinese(text)
    }

    /// Chinese output: Simplified characters, full-width punctuation, no spaces between characters.
    static func chinese(_ t: String) -> String {
        var s = t.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? t
        let han = #"\p{Han}"#
        for (ascii, full) in [(",", "，"), (".", "。"), ("?", "？"), ("!", "！"), (":", "："), (";", "；")] {
            let esc = NSRegularExpression.escapedPattern(for: ascii)
            s = s.replacingOccurrences(of: "(?<=\(han))\(esc)", with: full, options: .regularExpression)
        }
        // Lines joined with spaces split Chinese text; drop spaces between Chinese characters/punctuation.
        s = s.replacingOccurrences(of: #"(?<=[\p{Han}，。？！：；])\s+(?=[\p{Han}，。？！：；])"#, with: "", options: .regularExpression)
        return s
    }

    /// 16-bit PCM mono WAV.
    static func writeWav(_ samples: [Float], to url: URL) throws {
        let rate = UInt32(Recorder.sampleRate)
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        h.append("RIFF".data(using: .ascii)!); u32(36 + UInt32(pcm.count))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        try (h + pcm).write(to: url)
    }
}
