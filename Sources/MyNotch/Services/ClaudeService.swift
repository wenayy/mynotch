import AppKit
import SwiftUI
import Observation

struct ClaudeLimits: Equatable {
    struct Share: Equatable { var name: String; var percent: Double }
    var session: UsageWindow?
    var weekly: UsageWindow?
    var weeklyOpus: UsageWindow?
    var weeklySonnet: UsageWindow?
    var extraEnabled = false
    var extraUsed = 0.0
    var extraLimit = 0.0
    var currency = "USD"
    var shares: [Share] = []
    var fetchedAt = Date()
}

/// Claude Code: live plan limits (OAuth usage endpoint — the same numbers `/usage` shows),
/// local token stats from transcripts, and live sessions from ~/.claude/sessions.
@Observable
final class ClaudeService {
    var limits: ClaudeLimits?
    var limitsError: String?
    var limitsLoading = false
    var plan: String?
    var sessions: [AgentSession] = []
    var stats = LocalStats()
    var statsReady = false
    var installed = FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path)

    @ObservationIgnored private let index = ClaudeTranscriptIndex()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "mynotch.claude.scan", qos: .utility)
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "mynotch.claude.io", qos: .utility)
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var nextFetch = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var previous: [String: AgentStatus] = [:]
    @ObservationIgnored private var busySince: [String: Date] = [:]
    @ObservationIgnored private var alertedWindow: Date? = {
        let t = UserDefaults.standard.double(forKey: "claudeAlertedWindow")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    @ObservationIgnored private var lastResetSeen: Date?
    @ObservationIgnored private var cliVersion = "2.1.0"
    @ObservationIgnored private var timers: [Timer] = []

    private var settings: AppSettings { .shared }

    func start() {
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.pollSessions() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.scan() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.fetchLimitsIfDue() })
        pollSessions()
        scan()
        fetchLimitsIfDue()
    }

    func refreshNow() {
        nextFetch = .distantPast
        fetchLimitsIfDue(force: true)
        scan()
    }

    // MARK: Live limits

    private func fetchLimitsIfDue(force: Bool = false) {
        guard settings.claudeEnabled, settings.claudeLimitsEnabled, !limitsLoading else { return }
        guard force || Date() >= nextFetch else { return }
        limitsLoading = true
        let version = cliVersion
        ioQueue.async { [weak self] in
            let result = ClaudeService.fetchLimits(cliVersion: version)
            DispatchQueue.main.async {
                guard let self else { return }
                self.limitsLoading = false
                let interval = max(60, self.settings.usageRefreshMinutes * 60)
                switch result {
                case let .success((limits, plan)):
                    self.failures = 0
                    self.limitsError = nil
                    self.plan = plan
                    self.applyAlerts(old: self.limits, new: limits)
                    withAnimation(.easeInOut(duration: 0.3)) { self.limits = limits }
                    self.nextFetch = Date().addingTimeInterval(interval)
                case let .failure(err):
                    self.failures += 1
                    self.limitsError = err.message
                    // Back off on rate limits / errors so we never hammer the endpoint.
                    let backoff = min(interval * pow(2, Double(min(self.failures, 4))), 1800)
                    self.nextFetch = Date().addingTimeInterval(err.retryAfter ?? backoff)
                }
            }
        }
    }

    struct FetchError: Error {
        var message: String
        var retryAfter: TimeInterval?
    }

    private static func readCredentials() -> [String: Any]? {
        let (status, out) = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 5)
        if status == 0, let data = out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        let file = Paths.home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

    private static func fetchLimits(cliVersion: String) -> Result<(ClaudeLimits, String?), FetchError> {
        guard let creds = readCredentials(), let oauth = creds["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(FetchError(message: "Sign in to Claude Code to see live limits", retryAfter: 600))
        }
        let plan = (oauth["subscriptionType"] as? String).map { $0.capitalized }
        if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
            // We never refresh Claude Code's token ourselves (that would rotate it under the CLI).
            return .failure(FetchError(message: "Token expired — open Claude Code once to refresh", retryAfter: 300))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-cli/\(cliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(ClaudeLimits, String?), FetchError> = .failure(FetchError(message: "No response"))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(FetchError(message: err.localizedDescription)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let retry = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                let msg = code == 429 ? "Rate limited — retrying later" : (code == 401 ? "Claude token rejected — reopen Claude Code" : "Usage API error \(code)")
                result = .failure(FetchError(message: msg, retryAfter: retry))
                return
            }
            result = .success((parse(json), plan))
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return result
    }

    static func parse(_ json: [String: Any]) -> ClaudeLimits {
        func window(_ key: String, _ label: String, _ minutes: Int) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(label: label, percent: u, resetsAt: DateParse.iso8601(w["resets_at"] as? String), windowMinutes: minutes)
        }
        var l = ClaudeLimits()
        l.session = window("five_hour", "Session", 300)
        l.weekly = window("seven_day", "Weekly", 10080)
        l.weeklyOpus = window("seven_day_opus", "Opus weekly", 10080)
        l.weeklySonnet = window("seven_day_sonnet", "Sonnet weekly", 10080)
        if let e = json["extra_usage"] as? [String: Any] {
            l.extraEnabled = e["is_enabled"] as? Bool ?? false
            l.extraUsed = (e["used_credits"] as? NSNumber)?.doubleValue ?? 0
            l.extraLimit = (e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
            l.currency = e["currency"] as? String ?? "USD"
        }
        if let b = json["seven_day_breakdown"] as? [String: Any], let rows = b["rows"] as? [[String: Any]] {
            l.shares = rows.compactMap { r in
                guard let n = r["display_name"] as? String, let p = (r["percent"] as? NSNumber)?.doubleValue else { return nil }
                return ClaudeLimits.Share(name: n, percent: p)
            }
        }
        l.fetchedAt = Date()
        return l
    }

    private func applyAlerts(old: ClaudeLimits?, new: ClaudeLimits) {
        guard let s = new.session else { return }
        let threshold = settings.usageAlertThreshold
        // Once per 5-hour window (remembered across relaunches; reset times jitter by a second, so compare loosely).
        let sameWindow = alertedWindow.map { abs($0.timeIntervalSince(s.resetsAt ?? .distantPast)) < 120 } ?? false
        if threshold > 0, s.percent >= threshold, (old?.session?.percent ?? 0) < threshold, !sameWindow {
            alertedWindow = s.resetsAt
            UserDefaults.standard.set(s.resetsAt?.timeIntervalSince1970 ?? 0, forKey: "claudeAlertedWindow")
            PeekCenter.shared.post(Peek(symbol: "gauge.with.dots.needle.67percent", tint: s.percent >= 95 ? .red : .orange,
                                        title: "Claude session at \(Fmt.percent(s.percent))",
                                        subtitle: "Resets \(Fmt.reset(s.resetsAt))", tool: .ai, duration: 5, style: .warning,
                                        sound: NSSound.Name("Funk")))
        }
        if let oldS = old?.session, let oldReset = oldS.resetsAt, oldS.percent > 20, s.percent < 5,
           s.resetsAt != oldReset, lastResetSeen != s.resetsAt {
            lastResetSeen = s.resetsAt
            PeekCenter.shared.post(Peek(symbol: "arrow.counterclockwise.circle.fill", tint: .claude,
                                        title: "Claude session reset", subtitle: "Fresh 5-hour window — go build",
                                        tool: .ai, duration: 4, style: .success))
        }
    }

    // MARK: Live sessions

    private func pollSessions() {
        guard settings.claudeEnabled else { if !sessions.isEmpty { sessions = [] }; return }
        ioQueue.async { [weak self] in
            let found = ClaudeService.readSessions()
            DispatchQueue.main.async { self?.applySessions(found.sessions, version: found.version) }
        }
    }

    private static func readSessions() -> (sessions: [AgentSession], version: String?) {
        let dir = Paths.home.appendingPathComponent(".claude/sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return ([], nil) }
        var out: [AgentSession] = []
        var version: String?
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, AppInfo.isAlive(pid) else { continue }
            version = version ?? (o["version"] as? String)
            let cwd = o["cwd"] as? String ?? ""
            let raw = o["status"] as? String ?? "idle"
            let waiting = (o["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let status: AgentStatus = waiting != nil ? .waiting : (raw == "busy" ? .busy : .idle)
            let ms = (o["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (o["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            let started = (o["startedAt"] as? NSNumber)?.doubleValue
            var display = o["name"] as? String ?? (cwd as NSString).lastPathComponent
            if o["nameSource"] as? String == "derived" || display.isEmpty { display = (cwd as NSString).lastPathComponent }
            out.append(AgentSession(id: o["sessionId"] as? String ?? "\(pid)", source: .claude, pid: pid,
                                    name: display.isEmpty ? "Claude" : display, cwd: cwd, status: status,
                                    waitingFor: waiting, statusSince: Date(timeIntervalSince1970: ms / 1000),
                                    startedAt: started.map { Date(timeIntervalSince1970: $0 / 1000) },
                                    entrypoint: o["entrypoint"] as? String))
        }
        let rank: (AgentStatus) -> Int = { $0 == .waiting ? 0 : ($0 == .busy ? 1 : 2) }
        out.sort { rank($0.status) != rank($1.status) ? rank($0.status) < rank($1.status) : $0.statusSince > $1.statusSince }
        return (out, version)
    }

    private func applySessions(_ list: [AgentSession], version: String?) {
        if let version { cliVersion = version }
        for s in list {
            let prev = previous[s.id]
            if s.status == .busy && prev != .busy { busySince[s.id] = s.statusSince }
            if let prev, prev != s.status {
                if prev == .busy && s.status == .idle && settings.notifyAgentFinished {
                    let took = busySince[s.id].map { Date().timeIntervalSince($0) } ?? 0
                    if took > 4 {
                        PeekCenter.shared.post(Peek(symbol: "checkmark.circle.fill", tint: .claude,
                                                    title: "Claude finished · \(s.name)",
                                                    subtitle: took > 0 ? "Worked for \(Fmt.duration(took))" : nil,
                                                    tool: .ai, duration: 4.5, style: .success,
                                                    sound: NSSound.Name("Glass")))
                    }
                }
                if s.status == .waiting && settings.notifyAgentWaiting {
                    PeekCenter.shared.post(Peek(symbol: "hand.raised.fill", tint: .yellow,
                                                title: "Claude needs you · \(s.name)",
                                                subtitle: (s.waitingFor ?? "waiting").capitalized, tool: .ai,
                                                duration: 6, style: .warning, sound: NSSound.Name("Tink")))
                }
            }
            previous[s.id] = s.status
        }
        let ids = Set(list.map(\.id))
        previous = previous.filter { ids.contains($0.key) }
        if list != sessions {
            withAnimation(.easeInOut(duration: 0.25)) { sessions = list }
        }
    }

    // MARK: Local stats

    func scan() {
        guard settings.claudeEnabled, !scanning else { return }
        scanning = true
        let days = max(7, settings.historyDays)
        let windowStart = limits?.session?.resetsAt.map { $0.addingTimeInterval(-5 * 3600).timeIntervalSince1970 }
        scanQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.index.refresh(days: days)
            let stats = ClaudeService.aggregate(entries, days: days, models: self.index.models,
                                                projects: self.index.projects, windowStart: windowStart)
            DispatchQueue.main.async {
                self.scanning = false
                self.installed = FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".claude").path)
                if stats != self.stats { self.stats = stats }
                self.statsReady = true
            }
        }
    }

    private static func aggregate(_ entries: [ClaudeTranscriptIndex.Entry], days: Int, models: [String],
                                  projects: [String], windowStart: Double?) -> LocalStats {
        var s = LocalStats()
        let today = LocalDay.today
        let first = today - days + 1
        var perDay = [Int: DayUsage]()
        var projectTokens = [Int32: Int]()
        var modelTokens = [Int16: Int]()
        var sessionsToday = Set<Int32>()
        let now = Date().timeIntervalSince1970
        // Without a known window, approximate the active 5h block like ccusage does.
        let wStart = windowStart ?? (now - 5 * 3600)
        var last: Double = 0

        for e in entries {
            let day = Int(e.day)
            guard day >= first else { continue }
            let total = e.tokens.total
            var d = perDay[day] ?? DayUsage(day: day)
            d.tokens += total
            d.output += e.tokens.output
            d.messages += 1
            perDay[day] = d
            s.allTimeTokens += total
            last = max(last, e.time)
            if e.time >= wStart { s.windowTokens += total }
            if now - e.time < 3600 { s.lastHourTokens += total }
            if day == today {
                s.today = s.today + e.tokens
                s.todayMessages += 1
                s.todayToolCalls += Int(e.tools)
                sessionsToday.insert(e.session)
                projectTokens[e.project, default: 0] += total
                modelTokens[e.model, default: 0] += total
            }
        }
        s.todaySessions = sessionsToday.count
        s.days = (first...today).map { perDay[$0] ?? DayUsage(day: $0) }
        s.topProjects = projectTokens.sorted { $0.value > $1.value }.prefix(5)
            .map { (name: Int($0.key) < projects.count ? projects[Int($0.key)] : "?", tokens: $0.value) }
        s.models = modelTokens.sorted { $0.value > $1.value }
            .map { (name: Int($0.key) < models.count ? ClaudeService.prettyModel(models[Int($0.key)]) : "?", tokens: $0.value) }
        s.lastActivity = last > 0 ? Date(timeIntervalSince1970: last) : nil

        // Streaks: consecutive active days ending today (or yesterday if today is still empty).
        var run = 0, best = 0
        for d in s.days { if d.messages > 0 { run += 1; best = max(best, run) } else { run = 0 } }
        s.bestStreak = best
        var streak = 0
        var idx = s.days.count - 1
        if idx >= 0, s.days[idx].messages == 0 { idx -= 1 }
        while idx >= 0, s.days[idx].messages > 0 { streak += 1; idx -= 1 }
        s.streak = streak
        return s
    }

    static func prettyModel(_ id: String) -> String {
        // claude-opus-5-5 → Opus 5.5, claude-sonnet-4-5-20250929 → Sonnet 4.5
        var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}
