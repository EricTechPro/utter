import AVFoundation
import ScreenCaptureKit

/// Captures what the Mac is playing (the other people in a meeting) as 16 kHz mono.
/// Uses ScreenCaptureKit audio, which needs the Screen Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private let resampler = Resampler()
    private let queue = DispatchQueue(label: "utter.system-audio")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Utter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture audio from"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true   // don't record our own chimes
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        // Video is required by the API; keep it tiny and slow.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = Self.pcmBuffer(from: sb) else { return }
        let chunk = resampler.convert(pcm)
        if !chunk.isEmpty { onSamples?(chunk) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Utter: system audio stopped: \(error)")
        onStopped?(error)
    }

    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                                  into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }
}
