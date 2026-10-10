import AVFoundation

/// Converts any PCM buffer to 16 kHz mono Float32, the rate whisper expects.
final class Resampler {
    static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Recorder.sampleRate,
                                         channels: 1,
                                         interleaved: false)!
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inFormat != buffer.format {
            inFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.outFormat)
        }
        guard let converter else { return [] }
        let ratio = Self.outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return [] }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    static func rms<C: Collection>(_ s: C) -> Float where C.Element == Float {
        s.isEmpty ? 0 : sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
    }
}

/// Captures the default mic as 16 kHz mono.
final class Recorder {
    static let sampleRate: Double = 16_000

    /// Keep everything in memory (dictation). Meetings stream through `onSamples` instead.
    var accumulate = true
    /// Echo cancellation, so the mic doesn't re-hear meeting audio from the speakers.
    var voiceProcessing = false
    /// RMS loudness of each converted buffer, delivered on the main thread.
    var onLevel: ((Float) -> Void)?
    /// Each converted chunk, on the audio thread.
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    // Don't turn down the meeting audio while we listen.
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                NSLog("Utter: voice processing unavailable: \(error)")
            }
        }
        let inFormat = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        if accumulate {
            lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        }
        onSamples?(chunk)
        if let onLevel {
            let rms = Resampler.rms(chunk)
            DispatchQueue.main.async { onLevel(rms) }
        }
    }
}
