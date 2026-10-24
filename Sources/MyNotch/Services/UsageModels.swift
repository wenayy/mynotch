import Foundation

/// One rate-limit window (e.g. Claude's 5-hour session or a weekly cap).
struct UsageWindow: Equatable {
    var label: String
    var percent: Double            // 0…100
    var resetsAt: Date?
    var windowMinutes: Int?

    var remaining: Double { max(0, 100 - percent) }

    /// Linear projection of when the window would hit 100% at the current pace.
    var projectedLimitDate: Date? {
        guard let resetsAt, let mins = windowMinutes, percent > 1 else { return nil }
        let start = resetsAt.addingTimeInterval(-Double(mins) * 60)
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 300 else { return nil }
        let rate = percent / elapsed                  // % per second
        let secondsToFull = (100 - percent) / rate
        let date = Date().addingTimeInterval(secondsToFull)
        return date < resetsAt ? date : nil
    }

    static func label(forMinutes m: Int) -> String {
        switch m {
        case ..<1: return "Window"
        case 1...1440: return m % 60 == 0 ? "\(m / 60)h window" : "\(m)m window"
        case 10080: return "Weekly"
        case 40000...46000: return "Monthly"
        default: return "\(m / 1440)-day"
        }
    }
}

struct DayUsage: Equatable {
    var day: Int                   // yyyymmdd
    var tokens = 0
    var output = 0
    var messages = 0
}

struct TokenBreakdown: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var total: Int { input + output + cacheWrite + cacheRead }

    static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: a.input + b.input, output: a.output + b.output,
                       cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}

struct LocalStats: Equatable {
    var today = TokenBreakdown()
    var todayMessages = 0
    var todaySessions = 0
    var todayToolCalls = 0
    var windowTokens = 0            // tokens inside the current 5h window
    var lastHourTokens = 0
    var days: [DayUsage] = []       // oldest → newest, contiguous, ends today
    var topProjects: [(name: String, tokens: Int)] = []
    var models: [(name: String, tokens: Int)] = []
    var streak = 0
    var bestStreak = 0
    var allTimeTokens = 0
    var lastActivity: Date?

    static func == (a: LocalStats, b: LocalStats) -> Bool {
        a.today == b.today && a.todayMessages == b.todayMessages && a.days == b.days &&
        a.windowTokens == b.windowTokens && a.streak == b.streak && a.lastActivity == b.lastActivity &&
        a.topProjects.map(\.name) == b.topProjects.map(\.name) && a.topProjects.map(\.tokens) == b.topProjects.map(\.tokens)
    }
}

enum AgentStatus: String {
    case busy, waiting, idle
}

struct AgentSession: Identifiable, Equatable {
    enum Source { case claude, codex }
    var id: String
    var source: Source
    var pid: pid_t
    var name: String
    var cwd: String
    var status: AgentStatus
    var waitingFor: String?
    var statusSince: Date
    var startedAt: Date?
    var entrypoint: String?

    var projectName: String { (cwd as NSString).lastPathComponent }
}
