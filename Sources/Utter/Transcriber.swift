import Foundation
import CWhisper

/// Runs whisper.cpp locally. Nothing leaves the Mac.
/// The model is loaded once into the app and stays in memory; whisper-cli is only
/// the fallback if that fails.
struct Transcriber {
    let whisperPath: String
    let modelPath: String
    private let engine: WhisperEngine

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
        let t = Transcriber(whisperPath: whisper, modelPath: model, engine: WhisperEngine.shared(modelPath: model))
        t.warmUp()
        return t
    }

    /// Loads the model and, on the first run on a Mac, compiles GPU shaders (~20 s); do it
    /// once in the background with a second of silence so the user's first dictation is fast.
    private static var warmed = false
    func warmUp() {
        guard !Self.warmed else { return }
        Self.warmed = true
        DispatchQueue.global(qos: .utility).async {
            _ = try? self.transcribe(samples: [Float](repeating: 0, count: Int(Recorder.sampleRate)))
        }
    }

    func transcribe(samples: [Float]) throws -> String {
        try transcribe(samples: samples, language: "auto").text
    }

    /// `language` is "auto" (whisper detects it, which costs an extra encoder pass) or a code
    /// like "en". Returns the language whisper used, so later chunks can skip detecting it again.
    func transcribe(samples: [Float], language: String) throws -> (text: String, language: String) {
        if let result = engine.transcribe(samples, language: language) {
            return (Self.clean(result.text), result.language)
        }
        return (try transcribeWithCLI(samples: samples, language: language), language)
    }

    /// The old path: one whisper-cli process per call (loads the model every time).
    private func transcribeWithCLI(samples: [Float], language: String) throws -> String {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("utter-\(UUID().uuidString).wav")
        try Self.writeWav(samples, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisperPath)
        // "auto": whisper picks the spoken language (English, Chinese, …) on each recording.
        p.arguments = ["-m", modelPath, "-f", wav.path, "-l", language, "-nt", "-np", "-t", "6", "-bs", "1", "-bo", "1"]
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

/// whisper.cpp linked into the app, with the model kept loaded between calls.
/// One context, one call at a time (dictation and meeting notes take turns).
final class WhisperEngine {
    private static var engines: [String: WhisperEngine] = [:]
    private static let enginesLock = NSLock()

    static func shared(modelPath: String) -> WhisperEngine {
        enginesLock.lock(); defer { enginesLock.unlock() }
        if let e = engines[modelPath] { return e }
        let e = WhisperEngine(modelPath: modelPath)
        engines[modelPath] = e
        return e
    }

    private let modelPath: String
    private let lock = NSLock()
    private var ctx: OpaquePointer?
    private var loadFailed = false

    private init(modelPath: String) { self.modelPath = modelPath }

    /// nil if the model couldn't be loaded or whisper failed; the caller falls back to whisper-cli.
    func transcribe(_ samples: [Float], language: String) -> (text: String, language: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = loadedContext() else { return nil }

        // Greedy decoding (one candidate): much faster than beam search, nearly the same text.
        // Temperature fallback stays on for chunks whisper isn't sure about.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = 6
        params.greedy.best_of = 1
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false

        let status = language.withCString { lang -> Int32 in
            params.language = lang
            return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else {
            NSLog("Utter: whisper_full failed (\(status))")
            return nil
        }
        let lines = (0..<whisper_full_n_segments(ctx)).map { String(cString: whisper_full_get_segment_text(ctx, $0)) }
        let id = whisper_full_lang_id(ctx)
        let used = id >= 0 ? String(cString: whisper_lang_str(id)) : language
        return (lines.joined(separator: "\n"), used)
    }

    private func loadedContext() -> OpaquePointer? {
        if let ctx { return ctx }
        guard !loadFailed else { return nil }
        // whisper logs every load and run to stderr; keep the app's output quiet.
        whisper_log_set({ _, _, _ in }, nil)
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        ctx = whisper_init_from_file_with_params(modelPath, cparams)
        if ctx == nil {
            loadFailed = true
            NSLog("Utter: couldn't load the model in-process; using whisper-cli")
        } else {
            // ggml's Metal device is torn down at exit and aborts if a model still holds GPU
            // memory, so free it first. Registered after loading so it runs before that teardown.
            atexit { WhisperEngine.freeAll() }
        }
        return ctx
    }

    /// At exit: free each loaded model. One busy mid-transcription is left alone (and stays locked).
    private static func freeAll() {
        enginesLock.lock(); defer { enginesLock.unlock() }
        for e in engines.values where e.lock.try() {
            if let ctx = e.ctx { whisper_free(ctx) }
            e.ctx = nil
        }
    }
}
