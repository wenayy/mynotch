import AppKit
import SwiftUI
import Observation
import EventKit

// MARK: - Calendar

struct AgendaEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var color: Color
    var calendar: String
    var location: String?
    var meetingURL: URL?

    var isNow: Bool { start <= Date() && end > Date() }
}

@Observable
final class CalendarService {
    static let shared = CalendarService()
    var events: [AgendaEvent] = []
    var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var timer: Timer?

    var authorized: Bool { status == .fullAccess || status == .authorized }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }

    func requestAccess() {
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.status = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard authorized else { return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 8, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let list = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                AgendaEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                            title: e.title ?? "Untitled", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                            color: Color(cgColor: e.calendar.cgColor), calendar: e.calendar.title,
                            location: e.location, meetingURL: Self.meetingURL(e))
            }
        if list != events { events = list }
    }

    func events(on day: Date) -> [AgendaEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDate($0.start, inSameDayAs: day) || ($0.start < day && $0.end > day) }
    }

    var next: AgendaEvent? {
        let now = Date()
        return events.first { !$0.allDay && $0.end > now && $0.start < now.addingTimeInterval(24 * 3600) }
    }

    private static let meetingPattern = try! NSRegularExpression(pattern:
        #"https://([a-zA-Z0-9.-]*zoom\.us/(j|my|w)/[^\s<>"]+|meet\.google\.com/[a-z0-9-]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|[a-zA-Z0-9.-]*webex\.com/[^\s<>"]+|whereby\.com/[^\s<>"]+|meet\.around\.co/[^\s<>"]+|app\.slack\.com/huddle/[^\s<>"]+|discord\.gg/[^\s<>"]+)"#)

    static func meetingURL(_ e: EKEvent) -> URL? {
        if let u = e.url, isMeeting(u.absoluteString) { return u }
        for text in [e.location, e.notes].compactMap({ $0 }) {
            let r = NSRange(text.startIndex..., in: text)
            if let m = meetingPattern.firstMatch(in: text, range: r), let range = Range(m.range, in: text) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }

    private static func isMeeting(_ s: String) -> Bool {
        meetingPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

// MARK: - Timers

struct Countdown: Identifiable, Equatable, Codable {
    var id = UUID()
    var label: String
    var duration: TimeInterval
    var endDate: Date?
    var pausedRemaining: TimeInterval?

    var remaining: TimeInterval {
        if let p = pausedRemaining { return p }
        return max(0, (endDate ?? Date()).timeIntervalSinceNow)
    }
    var running: Bool { endDate != nil && pausedRemaining == nil }
    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }
}

@Observable
final class TimerEngine {
    static let shared = TimerEngine()

    enum PomodoroPhase: String { case focus = "Focus", shortBreak = "Break", longBreak = "Long break" }

    var countdowns: [Countdown] = []
    var pomodoro: Countdown?
    var pomodoroPhase: PomodoroPhase = .focus
    var pomodoroRounds = 0
    var stopwatchStart: Date?
    var stopwatchAccumulated: TimeInterval = 0
    var laps: [TimeInterval] = []
    var tick = Date()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hydrationTimer: Timer?

    var stopwatchElapsed: TimeInterval { stopwatchElapsed(at: Date()) }
    func stopwatchElapsed(at now: Date) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { now.timeIntervalSince($0) } ?? 0)
    }
    var stopwatchRunning: Bool { stopwatchStart != nil }

    /// The timer shown in the closed notch (soonest to finish).
    var primary: Countdown? {
        let all = (countdowns + [pomodoro].compactMap { $0 }).filter { $0.running }
        return all.min { $0.remaining < $1.remaining }
    }

    func start() {
        rescheduleHydration()
    }

    private func ensureTicking() {
        let active = countdowns.contains { $0.running } || (pomodoro?.running ?? false) || stopwatchRunning
        if active && timer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    private func step() {
        tick = Date()
        for c in countdowns where c.running && c.remaining <= 0 {
            countdowns.removeAll { $0.id == c.id }
            PeekCenter.shared.post(Peek(symbol: "bell.fill", tint: .orange, title: "\(c.label) is done",
                                        subtitle: Fmt.duration(c.duration) + " timer", tool: .timers, duration: 6,
                                        style: .success, sound: NSSound.Name("Glass")))
        }
        if let p = pomodoro, p.running, p.remaining <= 0 { finishPomodoroPhase() }
        ensureTicking()
    }

    // Countdowns
    func addCountdown(minutes: Double, label: String? = nil) {
        let d = minutes * 60
        let c = Countdown(label: label ?? Fmt.duration(d), duration: d, endDate: Date().addingTimeInterval(d))
        withAnimation { countdowns.append(c) }
        ensureTicking()
    }

    func toggle(_ c: Countdown) {
        guard let i = countdowns.firstIndex(where: { $0.id == c.id }) else { return }
        if let p = countdowns[i].pausedRemaining {
            countdowns[i].endDate = Date().addingTimeInterval(p)
            countdowns[i].pausedRemaining = nil
        } else {
            countdowns[i].pausedRemaining = countdowns[i].remaining
        }
        ensureTicking()
    }

    func remove(_ c: Countdown) {
        withAnimation { countdowns.removeAll { $0.id == c.id } }
        ensureTicking()
    }

    func addMinute(_ c: Countdown) {
        guard let i = countdowns.firstIndex(where: { $0.id == c.id }) else { return }
        countdowns[i].duration += 60
        if let p = countdowns[i].pausedRemaining { countdowns[i].pausedRemaining = p + 60 }
        else { countdowns[i].endDate = countdowns[i].endDate?.addingTimeInterval(60) }
    }

    // Pomodoro
    private func length(of phase: PomodoroPhase) -> TimeInterval {
        let s = AppSettings.shared
        switch phase {
        case .focus: return s.pomodoroFocus * 60
        case .shortBreak: return s.pomodoroBreak * 60
        case .longBreak: return s.pomodoroLongBreak * 60
        }
    }

    func togglePomodoro() {
        if var p = pomodoro {
            if let rem = p.pausedRemaining { p.endDate = Date().addingTimeInterval(rem); p.pausedRemaining = nil }
            else { p.pausedRemaining = p.remaining }
            pomodoro = p
        } else {
            let d = length(of: pomodoroPhase)
            pomodoro = Countdown(label: pomodoroPhase.rawValue, duration: d, endDate: Date().addingTimeInterval(d))
        }
        ensureTicking()
    }

    func resetPomodoro() {
        pomodoro = nil
        pomodoroPhase = .focus
        pomodoroRounds = 0
        ensureTicking()
    }

    func skipPomodoro() { finishPomodoroPhase(silent: true) }

    func addMinuteToPomodoro() {
        guard var p = pomodoro else { return }
        p.duration += 60
        if let r = p.pausedRemaining { p.pausedRemaining = r + 60 } else { p.endDate = p.endDate?.addingTimeInterval(60) }
        pomodoro = p
    }

    private func finishPomodoroPhase(silent: Bool = false) {
        let finished = pomodoroPhase
        if finished == .focus {
            pomodoroRounds += 1
            pomodoroPhase = pomodoroRounds % 4 == 0 ? .longBreak : .shortBreak
        } else {
            pomodoroPhase = .focus
        }
        let d = length(of: pomodoroPhase)
        pomodoro = Countdown(label: pomodoroPhase.rawValue, duration: d, endDate: Date().addingTimeInterval(d))
        if !silent {
            PeekCenter.shared.post(Peek(symbol: finished == .focus ? "cup.and.saucer.fill" : "brain.head.profile",
                                        tint: finished == .focus ? .green : .orange,
                                        title: finished == .focus ? "Focus done — take a break" : "Break over — back to it",
                                        subtitle: "Round \(pomodoroRounds) · next: \(pomodoroPhase.rawValue) \(Fmt.duration(d))",
                                        tool: .timers, duration: 6, style: .success, sound: NSSound.Name("Hero")))
        }
        ensureTicking()
    }

    // Stopwatch
    func toggleStopwatch() {
        if let s = stopwatchStart { stopwatchAccumulated += Date().timeIntervalSince(s); stopwatchStart = nil }
        else { stopwatchStart = Date() }
        tick = Date()
        ensureTicking()
    }

    func lap() { if stopwatchRunning { withAnimation { laps.insert(stopwatchElapsed, at: 0) } } }

    func resetStopwatch() {
        stopwatchStart = nil; stopwatchAccumulated = 0; laps = []
        ensureTicking()
    }

    // Hydration
    func rescheduleHydration() {
        hydrationTimer?.invalidate()
        hydrationTimer = nil
        let s = AppSettings.shared
        guard s.hydrationReminder else { return }
        hydrationTimer = Timer.scheduledTimer(withTimeInterval: max(5, s.hydrationMinutes) * 60, repeats: true) { _ in
            PeekCenter.shared.post(Peek(symbol: "drop.fill", tint: .cyan, title: "Time for some water",
                                        subtitle: "Stay hydrated 💧", duration: 5, sound: NSSound.Name("Purr")))
        }
    }
}
