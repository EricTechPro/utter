import Foundation

/// Transcribes a dictation while you're still talking: each finished sentence
/// (a chunk cut at a pause) is sent to whisper right away, so when you stop only
/// the last few seconds are left to do. Long dictations finish about as fast as short ones.
final class StreamingDictation {
    private let transcriber: Transcriber
    private let audioQueue = DispatchQueue(label: "utter.dictation.audio")
    private let whisperQueue = DispatchQueue(label: "utter.dictation.whisper")
    private var chunker: Chunker?
    private var parts: [Int: String] = [:]
    private var failed = false
    private var next = 0
    private var session = 0

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func start() {
        audioQueue.async {
            self.session += 1
            let session = self.session
            self.parts = [:]
            self.failed = false
            self.next = 0
            // Longer chunks than meeting notes: fewer cuts, better accuracy.
            self.chunker = Chunker(minSeconds: 6, maxSeconds: 25) { [weak self] samples, _ in
                self?.enqueue(samples, session: session)
            }
        }
    }

    /// Called from the mic thread with each 16 kHz piece.
    func feed(_ samples: [Float]) {
        audioQueue.async { self.chunker?.append(samples) }
    }

    func cancel() {
        audioQueue.async { self.session += 1; self.chunker = nil }
    }

    /// Transcribes what's left and returns the whole text on the main thread.
    /// Returns nil if any piece failed, so the caller can fall back to one full pass.
    func finish(_ done: @escaping (String?) -> Void) {
        audioQueue.async {
            self.chunker?.flush()
            self.chunker = nil
            let session = self.session
            // The whisper queue is serial: this runs after every chunk queued above.
            self.whisperQueue.async {
                self.audioQueue.async {
                    guard session == self.session else { return }
                    let text = self.failed ? nil
                        : Transcriber.clean(self.parts.keys.sorted().compactMap { self.parts[$0] }.joined(separator: " "))
                    DispatchQueue.main.async { done(text) }
                }
            }
        }
    }

    private func enqueue(_ samples: [Float], session: Int) {
        let index = next
        next += 1
        whisperQueue.async {
            let result = Result { try self.transcriber.transcribe(samples: samples) }
            self.audioQueue.async {
                guard session == self.session else { return }
                switch result {
                case .success(let t): self.parts[index] = t
                case .failure: self.failed = true
                }
            }
        }
    }
}
