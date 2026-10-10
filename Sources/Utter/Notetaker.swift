import Foundation
import CoreAudio

/// Splits a live 16 kHz stream into speech chunks: cut at a pause after 5 s,
/// or force a cut at 15 s. Quiet chunks are dropped (whisper invents words in silence).
final class Chunker {
    private let rate = Int(Recorder.sampleRate)
    private var buf: [Float] = []
    private var consumed = 0
    private let onChunk: ([Float], Double) -> Void

    init(onChunk: @escaping (_ samples: [Float], _ offset: Double) -> Void) { self.onChunk = onChunk }

    func append(_ s: [Float]) {
        buf.append(contentsOf: s)
        if buf.count >= 15 * rate { flush(); return }
        if buf.count >= 5 * rate, Resampler.rms(buf.suffix(rate / 2)) < 0.008 { flush() }
    }

    func flush() {
        guard !buf.isEmpty else { return }
        let offset = Double(consumed) / Double(rate)
        consumed += buf.count
        let chunk = buf
        buf.removeAll(keepingCapacity: true)
        if Resampler.rms(chunk) > 0.004 { onChunk(chunk, offset) }
    }
}

/// Meeting notes: records you (mic, echo-cancelled) and everyone else (system audio)
/// as two tracks, transcribes them in chunks while the meeting runs, and
/// streams the text into AppState.live.
final class Notetaker {
    private let state = AppState.shared
    private let transcriber: Transcriber
    private let mic = Recorder()
    private let system = SystemAudioCapture()
    private let audioQueue = DispatchQueue(label: "utter.notes.audio")
    private let whisperQueue = DispatchQueue(label: "utter.notes.whisper")
    private var micChunker: Chunker!
    private var systemChunker: Chunker!
    private(set) var isRunning = false
    var onWarning: ((String) -> Void)?

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        mic.accumulate = false
        // Voice processing on macOS needs the output side of the engine too; with
        // an input-only engine it delivered no audio. Echo is handled by AppState's
        // duplicate check instead.
        mic.voiceProcessing = false
    }

    /// Small log at ~/Library/Application Support/Utter/notes-debug.log.
    private func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let url = state.dataDir.appendingPathComponent("notes-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        state.startMeeting()

        micChunker = Chunker { [weak self] s, off in self?.transcribe(s, offset: off, speaker: "You") }
        systemChunker = Chunker { [weak self] s, off in self?.transcribe(s, offset: off, speaker: "Others") }

        mic.onSamples = { [weak self] s in self?.audioQueue.async { self?.micChunker.append(s) } }
        do {
            try mic.start()
            log("mic started")
        } catch {
            log("mic failed: \(error)")
            onWarning?("Mic didn't start: \(error.localizedDescription)")
        }

        system.onSamples = { [weak self] s in self?.audioQueue.async { self?.systemChunker.append(s) } }
        Task {
            do {
                try await system.start()
                self.log("system audio started")
            } catch {
                self.log("system audio failed: \(error)")
                NSLog("Utter: system audio failed: \(error)")
                await MainActor.run {
                    self.onWarning?("Only your voice is being recorded. Allow Screen Recording for Utter to hear the others.")
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        _ = mic.stop()
        system.stop()
        // Flush the last bits, then close the meeting once whisper has caught up.
        audioQueue.async {
            self.micChunker.flush()
            self.systemChunker.flush()
            self.whisperQueue.async {
                DispatchQueue.main.async { self.state.endMeeting() }
            }
        }
    }

    private func transcribe(_ samples: [Float], offset: Double, speaker: String) {
        log("\(speaker) chunk at \(Int(offset))s, \(String(format: "%.1f", Double(samples.count) / Recorder.sampleRate))s long, rms \(String(format: "%.3f", Resampler.rms(samples)))")
        whisperQueue.async {
            let result = Result { try self.transcriber.transcribe(samples: samples) }
            if case .failure(let e) = result { self.log("whisper failed: \(e)") }
            guard let text = try? result.get(), !text.isEmpty, !Self.isHallucination(text) else { return }
            self.log("\(speaker): \(text.prefix(80))")
            DispatchQueue.main.async {
                self.state.addSegment(Segment(offset: offset, speaker: speaker, text: text))
            }
        }
    }

    /// Phrases whisper tends to produce from near-silence.
    private static func isHallucination(_ t: String) -> Bool {
        let s = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["thank you", "thanks for watching", "you", "bye", "thank you for watching", "okay"].contains(s)
    }

    /// True when the default mic is in use by any process (e.g. Zoom or a browser call).
    static func micInUseSomewhere() -> Bool {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr && running != 0
    }
}
