import AppKit
import EventKit

/// Watches the Mac's Calendar for upcoming meetings with a video link, and pops up
/// a card a few minutes before: Join (opens the link) or Start Notetaker.
/// Also offers notes when another app grabs the mic and there's no calendar event.
final class MeetingReminder {
    var onStartNotes: (() -> Void)?

    private let store = EKEventStore()
    private let card = MeetingCard()
    private var timer: Timer?
    private var dismissed = Set<String>()
    private var shownKey: String?
    private var micSince: Date?

    /// Show the card this long before a meeting starts, and keep it until this long after.
    private let lead: TimeInterval = 5 * 60
    private let grace: TimeInterval = 10 * 60

    init() {
        card.onJoin = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.dismissCurrent()
        }
        card.onNotes = { [weak self] in
            self?.onStartNotes?()
            self?.dismissCurrent()
        }
        card.onClose = { [weak self] in self?.dismissCurrent() }
    }

    func start() {
        requestAccess { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    private func requestAccess(_ done: @escaping () -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { _, _ in done() }
        } else {
            store.requestAccess(to: .event) { _, _ in done() }
        }
    }

    private var hasAccess: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return s == .fullAccess }
        return s == .authorized
    }

    private func tick() {
        // Never nag while notes are already running.
        if AppState.shared.live != nil { card.hide(); shownKey = nil; return }

        if hasAccess, let (event, url) = nextMeeting() {
            let key = event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)"
            shownKey = key
            card.show(title: event.title ?? "Meeting", start: event.startDate, joinURL: url)
            return
        }

        // No calendar meeting: if another app has held the mic for a few seconds, offer notes.
        if AppState.shared.meetingLikely {
            micSince = micSince ?? Date()
            if Date().timeIntervalSince(micSince!) > 8, !dismissed.contains("mic") {
                shownKey = "mic"
                card.show(title: "Looks like you're in a call", start: nil, joinURL: nil)
                return
            }
        } else {
            micSince = nil
            dismissed.remove("mic")
        }
        if shownKey != nil { card.hide(); shownKey = nil }
    }

    private func nextMeeting() -> (EKEvent, URL)? {
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-grace),
                                            end: now.addingTimeInterval(lead), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(lead) && $0.startDate >= now.addingTimeInterval(-grace) }
            .filter { !dismissed.contains($0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)") }
            .sorted { $0.startDate < $1.startDate }
            .lazy
            .compactMap { e in Self.meetingURL(e).map { (e, $0) } }
            .first
    }

    private func dismissCurrent() {
        if let k = shownKey { dismissed.insert(k) }
        shownKey = nil
        card.hide()
    }

    /// Finds a Google Meet / Zoom / Teams / Webex link in the event's URL, location or notes.
    static func meetingURL(_ e: EKEvent) -> URL? {
        let pattern = #"https?://(meet\.google\.com/[a-z0-9\-]+|[\w.-]*zoom\.us/(j|my|w)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[\w.-]*webex\.com/[^\s<>"]+)"#
        let haystacks = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for h in haystacks {
            if let r = h.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let url = URL(string: String(h[r])) {
                return url
            }
        }
        return nil
    }
}
