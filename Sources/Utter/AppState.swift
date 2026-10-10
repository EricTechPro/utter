import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

struct Dictation: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    let seconds: Double
    let app: String?

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Seconds since the meeting started.
    let offset: Double
    /// "You" (mic) or "Others" (what the Mac plays).
    let speaker: String
    let text: String
}

struct Meeting: Codable, Identifiable, Equatable {
    let id: UUID
    let start: Date
    var end: Date?
    var segments: [Segment]

    var duration: Double { (end ?? Date()).timeIntervalSince(start) }

    /// Plain-text transcript, one line per speaker turn.
    var transcript: String {
        var lines: [String] = []
        var last: String?
        for s in segments {
            if s.speaker != last {
                lines.append("\n\(s.speaker):")
                last = s.speaker
            }
            lines.append(s.text)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Everything the UI shows. History is saved as JSON in
/// ~/Library/Application Support/Utter; each dictation's audio is kept as a WAV.
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase { case idle, recording, working }

    @Published var phase = Phase.idle
    @Published var status = "Starting…"
    @Published var micOK = false
    @Published var axOK = false
    @Published var screenOK = false
    @Published private(set) var entries: [Dictation] = []
    @Published private(set) var meetings: [Meeting] = []
    /// The meeting being recorded right now, if any.
    @Published private(set) var live: Meeting?
    /// Another app (Zoom, Meet, …) is using the mic: probably a meeting.
    @Published var meetingLikely = false

    let dataDir: URL
    var audioDir: URL { dataDir.appendingPathComponent("audio", isDirectory: true) }
    private var player: AVAudioPlayer?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDir = support.appendingPathComponent("Utter", isDirectory: true)
        // Keep history from before the app was renamed.
        let old = support.appendingPathComponent("WFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dataDir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dataDir)
        }
        try? FileManager.default.createDirectory(at: dataDir.appendingPathComponent("audio"), withIntermediateDirectories: true)
        entries = load([Dictation].self, from: "history.json") ?? []
        meetings = load([Meeting].self, from: "meetings.json") ?? []
        // Recover notes from a meeting that was cut short by a crash or quit.
        if var orphan = load(Meeting.self, from: "live-meeting.json") {
            orphan.end = orphan.end ?? Date(timeInterval: (orphan.segments.last?.offset ?? 0) + 10, since: orphan.start)
            if !orphan.segments.isEmpty, !meetings.contains(where: { $0.id == orphan.id }) {
                meetings.insert(orphan, at: 0)
                save(meetings, to: "meetings.json")
            }
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("live-meeting.json"))
        }
    }

    // MARK: Meetings

    func startMeeting() {
        live = Meeting(id: UUID(), start: Date(), end: nil, segments: [])
    }

    /// Segments from the mic and the system arrive out of order; keep them sorted by time.
    func addSegment(_ seg: Segment) {
        guard var m = live else { return }
        // On speakers the mic also hears the others. If the same words show up on both
        // tracks at about the same time, keep the "Others" copy.
        if let dup = m.segments.firstIndex(where: {
            $0.speaker != seg.speaker && abs($0.offset - seg.offset) < 12 && Self.overlap($0.text, seg.text) > 0.6
        }) {
            if seg.speaker == "You" { return }
            m.segments.remove(at: dup)
        }
        let i = m.segments.firstIndex { $0.offset > seg.offset } ?? m.segments.endIndex
        m.segments.insert(seg, at: i)
        live = m
        saveLiveDraft()
    }

    /// Share of the shorter text's words that also appear in the other.
    static func overlap(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        let (short, long) = wa.count <= wb.count ? (wa, Set(wb)) : (wb, Set(wa))
        return Double(short.filter(long.contains).count) / Double(short.count)
    }

    func endMeeting() {
        guard var m = live else { return }
        m.end = Date()
        live = nil
        if !m.segments.isEmpty {
            meetings.insert(m, at: 0)
            save(meetings, to: "meetings.json")
        }
        try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("live-meeting.json"))
    }

    func delete(_ m: Meeting) {
        meetings.removeAll { $0.id == m.id }
        save(meetings, to: "meetings.json")
    }

    func copy(_ m: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.transcript, forType: .string)
    }

    /// So a crash mid-meeting doesn't lose the notes.
    private func saveLiveDraft() {
        if let live { save(live, to: "live-meeting.json") }
    }

    // MARK: History

    func add(text: String, seconds: Double, app: String?, samples: [Float]) {
        let d = Dictation(id: UUID(), date: Date(), text: text, seconds: seconds, app: app)
        try? Transcriber.writeWav(samples, to: audioURL(d))
        entries.insert(d, at: 0)
        save(entries, to: "history.json")
    }

    func delete(_ d: Dictation) {
        entries.removeAll { $0.id == d.id }
        try? FileManager.default.removeItem(at: audioURL(d))
        save(entries, to: "history.json")
    }

    func audioURL(_ d: Dictation) -> URL { audioDir.appendingPathComponent("\(d.id.uuidString).wav") }

    func play(_ d: Dictation) {
        player = try? AVAudioPlayer(contentsOf: audioURL(d))
        player?.play()
    }

    func copy(_ d: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
    }

    // MARK: Stats

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    var wordsPerMinute: Int {
        let mins = entries.reduce(0) { $0 + $1.seconds } / 60
        return mins > 0 ? Int((Double(totalWords) / mins).rounded()) : 0
    }

    var todayWords: Int {
        entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.wordCount }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        if mic != micOK { micOK = mic }
        if ax != axOK { axOK = ax }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenOK { screenOK = screen }
    }

    // MARK: Files

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(value).write(to: dataDir.appendingPathComponent(name), options: .atomic)
    }
}
