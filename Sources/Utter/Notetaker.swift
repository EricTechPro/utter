import Foundation

/// Splits a live 16 kHz stream into speech chunks: cut at a pause after 3 s,
/// or force a cut at 10 s. Quiet chunks are dropped (whisper invents words in silence).
/// `snapshot()` exposes the chunk still being spoken, for live draft text.
final class Chunker {
    private let rate = Int(Recorder.sampleRate)
    private let minSamples: Int
    private let maxSamples: Int
    private var buf: [Float] = []
    private var consumed = 0
    private let onChunk: ([Float], Double) -> Void
    /// Bumped on every cut, so a late draft for an already-finished chunk can be ignored.
    private(set) var generation = 0

    init(minSeconds: Double = 3, maxSeconds: Double = 10,
         onChunk: @escaping (_ samples: [Float], _ offset: Double) -> Void) {
        minSamples = Int(minSeconds * Recorder.sampleRate)
        maxSamples = Int(maxSeconds * Recorder.sampleRate)
        self.onChunk = onChunk
    }

    func append(_ s: [Float]) {
        buf.append(contentsOf: s)
        if buf.count >= maxSamples { flush(); return }
        if buf.count >= minSamples, Resampler.rms(buf.suffix(rate / 2)) < 0.008 { flush() }
    }

    func flush() {
        guard !buf.isEmpty else { return }
        let offset = Double(consumed) / Double(rate)
        consumed += buf.count
        let chunk = buf
        buf.removeAll(keepingCapacity: true)
        generation += 1
        if Resampler.rms(chunk) > 0.004 { onChunk(chunk, offset) }
    }

    /// The in-progress chunk if it's at least 1 s of non-silent audio.
    func snapshot() -> (samples: [Float], generation: Int)? {
        guard buf.count >= rate, Resampler.rms(buf) > 0.004 else { return nil }
        return (buf, generation)
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
    /// Drafts run on their own queue so they never hold up the final text.
    private let draftQueue = DispatchQueue(label: "utter.notes.draft")
    private var draftBusy = Set<String>()
    /// Length of each track's in-progress chunk at its last draft, so we only redo it when there's new speech.
    private var draftedLength: [String: Int] = [:]
    private var draftTimer: DispatchSourceTimer?
    private var panel: MeetingPanelModel { MeetingPanel.shared.model }
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

    /// Seconds to add to chunk offsets, so a resumed meeting keeps its timeline.
    private var offsetBase: Double = 0

    /// Starts a new meeting, or continues a finished one when `resume` is its id.
    func start(resume: UUID? = nil) {
        guard !isRunning else { return }
        isRunning = true
        if let resume, let base = state.resumeMeeting(resume) {
            offsetBase = base
        } else {
            offsetBase = 0
            state.startMeeting()
        }

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
        startDrafts()
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
        draftTimer?.cancel()
        draftTimer = nil
        DispatchQueue.main.async { self.panel.drafts = [:] }
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

    /// Every 3 s, transcribe what's been said so far in each track and show it as a draft —
    /// but only if there's at least 1 s of new audio. Running whisper back to back keeps the GPU
    /// busy nonstop, which some Macs answer with an audible coil whine.
    private func startDrafts() {
        let t = DispatchSource.makeTimerSource(queue: audioQueue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for (speaker, chunker) in [("You", self.micChunker!), ("Others", self.systemChunker!)] {
                guard !self.draftBusy.contains(speaker), let snap = chunker.snapshot() else { continue }
                // A new chunk starts shorter than the last draft; otherwise require 1 s of new audio.
                let last = self.draftedLength[speaker] ?? 0
                if snap.samples.count > last, snap.samples.count - last < Int(Recorder.sampleRate) { continue }
                self.draftedLength[speaker] = snap.samples.count
                self.draftBusy.insert(speaker)
                self.draftQueue.async {
                    let text = Self.clean((try? self.transcriber.transcribe(samples: snap.samples)) ?? "")
                    self.audioQueue.async {
                        self.draftBusy.remove(speaker)
                        // Drop it if that chunk has already been finished.
                        guard chunker.generation == snap.generation, self.isRunning else { return }
                        DispatchQueue.main.async {
                            if text.isEmpty || Self.isHallucination(text) { return }
                            self.panel.drafts[speaker] = text
                        }
                    }
                }
            }
        }
        t.resume()
        draftTimer = t
    }

    private func transcribe(_ samples: [Float], offset: Double, speaker: String) {
        log("\(speaker) chunk at \(Int(offset))s, \(String(format: "%.1f", Double(samples.count) / Recorder.sampleRate))s long, rms \(String(format: "%.3f", Resampler.rms(samples)))")
        whisperQueue.async {
            let result = Result { try self.transcriber.transcribe(samples: samples) }
            if case .failure(let e) = result { self.log("whisper failed: \(e)") }
            // The draft for this chunk is replaced by the final text (or cleared if it was noise).
            DispatchQueue.main.async { self.panel.drafts[speaker] = nil }
            guard let raw = try? result.get() else { return }
            let text = Self.clean(raw)
            guard !text.isEmpty, !Self.isHallucination(text) else { return }
            self.log("\(speaker): \(text.prefix(80))")
            DispatchQueue.main.async {
                self.state.addSegment(Segment(offset: offset + self.offsetBase, speaker: speaker, text: text))
            }
        }
    }

    /// Removes sound tags whisper writes for noises, like *sniff* or ♪.
    static func clean(_ t: String) -> String {
        t.replacingOccurrences(of: #"\*[^*]*\*|♪+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Phrases whisper tends to produce from near-silence.
    private static func isHallucination(_ t: String) -> Bool {
        let s = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["thank you", "thanks for watching", "you", "bye", "thank you for watching", "okay"].contains(s)
    }
}
