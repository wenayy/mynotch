import AppKit
import SwiftUI
import Observation

struct CodexLimits: Equatable {
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var extra: [UsageWindow] = []
    var plan: String?
    var hasCredits = false
    var unlimitedCredits = false
    var creditBalance: String?
    var resetCredits: Int?
    var limitReached: String?
    var source: String = "Codex"
    var fetchedAt = Date()
}

/// Codex: limits via the official `codex app-server` JSON-RPC (which also keeps its own
/// OAuth token fresh), falling back to the last `rate_limits` event in session logs.
@Observable
final class CodexService {
    var limits: CodexLimits?
    var limitsError: String?
    var limitsLoading = false
    var stats = LocalStats()
    var statsReady = false
    var active: [AgentSession] = []
    var installed = false

    @ObservationIgnored private let index = CodexTranscriptIndex()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "mynotch.codex.scan", qos: .utility)
    @ObservationIgnored private let rpcQueue = DispatchQueue(label: "mynotch.codex.rpc", qos: .utility)
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var nextFetch = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var wasActive = Set<String>()
    @ObservationIgnored private lazy var codexPath: String? = Shell.which("codex")

    private var settings: AppSettings { .shared }

    func start() {
        installed = codexPath != nil || FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".codex").path)
        timers.append(Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.scan() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.fetchIfDue() })
        scan()
        fetchIfDue()
    }

    func refreshNow() {
        nextFetch = .distantPast
        fetchIfDue(force: true)
        scan()
    }

    // MARK: Limits

    private func fetchIfDue(force: Bool = false) {
        guard settings.codexEnabled, !limitsLoading, force || Date() >= nextFetch else { return }
        guard let path = codexPath else {
            applyFallback(reason: "Codex CLI not found")
            nextFetch = Date().addingTimeInterval(600)
            return
        }
        limitsLoading = true
        rpcQueue.async { [weak self] in
            let result = CodexService.readViaAppServer(codex: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.limitsLoading = false
                let interval = max(120, self.settings.usageRefreshMinutes * 60 * 1.5)
                if let result {
                    self.failures = 0
                    self.limitsError = nil
                    withAnimation(.easeInOut(duration: 0.3)) { self.limits = result }
                    self.nextFetch = Date().addingTimeInterval(interval)
                } else {
                    self.failures += 1
                    self.applyFallback(reason: "Live limits unavailable — showing last seen")
                    self.nextFetch = Date().addingTimeInterval(min(interval * Double(self.failures + 1), 1800))
                }
            }
        }
    }

    private func applyFallback(reason: String) {
        if let latest = index.latestLimits {
            var l = CodexService.parseSnake(latest.json)
            l.source = "Session log"
            l.fetchedAt = Date(timeIntervalSince1970: latest.time)
            limits = l
        }
        limitsError = reason
    }

    /// Spawns `codex app-server`, performs `initialize` + `account/rateLimits/read`, then exits.
    private static func readViaAppServer(codex: String) -> CodexLimits? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.richPath
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data()
        var responses: [Int: [String: Any]] = [:]
        let gotInit = DispatchSemaphore(value: 0)
        let gotLimits = DispatchSemaphore(value: 0)

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (obj["id"] as? NSNumber)?.intValue else { continue }
                responses[id] = obj
                if id == 1 { gotInit.signal() }
                if id == 2 { gotLimits.signal() }
            }
        }
        func send(_ obj: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }
        do { try p.run() } catch { return nil }
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "mynotch", "title": "MyNotch", "version": AppInfo.version]]])
        guard gotInit.wait(timeout: .now() + 15) == .success else { return nil }
        send(["method": "initialized"])
        send(["id": 2, "method": "account/rateLimits/read"])
        guard gotLimits.wait(timeout: .now() + 15) == .success else { return nil }
        lock.lock(); let resp = responses[2]; lock.unlock()
        guard let result = resp?["result"] as? [String: Any] else { return nil }
        return parseCamel(result)
    }

    private static func window(_ o: Any?, camel: Bool) -> UsageWindow? {
        guard let w = o as? [String: Any] else { return nil }
        let pct = (w[camel ? "usedPercent" : "used_percent"] as? NSNumber)?.doubleValue ?? 0
        let mins = (w[camel ? "windowDurationMins" : "window_minutes"] as? NSNumber)?.intValue
        var reset = (w[camel ? "resetsAt" : "resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if reset == nil, let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { reset = Date().addingTimeInterval(secs) }
        return UsageWindow(label: UsageWindow.label(forMinutes: mins ?? 0), percent: pct, resetsAt: reset, windowMinutes: mins)
    }

    static func parseCamel(_ result: [String: Any]) -> CodexLimits {
        var l = CodexLimits()
        let rl = result["rateLimits"] as? [String: Any] ?? [:]
        l.primary = window(rl["primary"], camel: true)
        l.secondary = window(rl["secondary"], camel: true)
        l.plan = (rl["planType"] as? String)?.capitalized
        l.limitReached = rl["rateLimitReachedType"] as? String
        if let c = rl["credits"] as? [String: Any] {
            l.hasCredits = c["hasCredits"] as? Bool ?? false
            l.unlimitedCredits = c["unlimited"] as? Bool ?? false
            l.creditBalance = c["balance"] as? String
        }
        if let by = result["rateLimitsByLimitId"] as? [String: Any] {
            for (key, v) in by where key != (rl["limitId"] as? String ?? "codex") {
                guard let o = v as? [String: Any] else { continue }
                let name = (o["limitName"] as? String) ?? key.capitalized
                for slot in ["primary", "secondary"] {
                    if var w = window(o[slot], camel: true) { w.label = "\(name) · \(w.label)"; l.extra.append(w) }
                }
            }
        }
        if let rc = result["rateLimitResetCredits"] as? [String: Any] {
            l.resetCredits = (rc["availableCount"] as? NSNumber)?.intValue
        }
        l.source = "Codex app-server"
        l.fetchedAt = Date()
        return l
    }

    static func parseSnake(_ rl: [String: Any]) -> CodexLimits {
        var l = CodexLimits()
        l.primary = window(rl["primary"], camel: false)
        l.secondary = window(rl["secondary"], camel: false)
        l.plan = (rl["plan_type"] as? String)?.capitalized
        if let c = rl["credits"] as? [String: Any] {
            l.hasCredits = c["has_credits"] as? Bool ?? false
            l.unlimitedCredits = c["unlimited"] as? Bool ?? false
            l.creditBalance = c["balance"] as? String
        }
        return l
    }

    // MARK: Local stats + activity

    func scan() {
        guard settings.codexEnabled, !scanning else { return }
        scanning = true
        let days = max(7, settings.historyDays)
        scanQueue.async { [weak self] in
            guard let self else { return }
            let r = self.index.refresh(days: days)
            let stats = CodexService.aggregate(r.entries, days: days, index: self.index)
            let sessions = r.active.map {
                AgentSession(id: $0.path, source: .codex, pid: 0, name: $0.project, cwd: $0.project,
                             status: .busy, waitingFor: nil, statusSince: $0.lastActivity, startedAt: nil, entrypoint: "codex")
            }
            DispatchQueue.main.async {
                self.scanning = false
                if stats != self.stats { self.stats = stats }
                self.statsReady = true
                let ids = Set(sessions.map(\.id))
                for gone in self.wasActive.subtracting(ids) where self.settings.notifyAgentFinished {
                    let name = self.active.first { $0.id == gone }?.name ?? "Codex"
                    PeekCenter.shared.post(Peek(symbol: "checkmark.circle.fill", tint: .codex, title: "Codex went quiet · \(name)",
                                                subtitle: "No new activity for a bit", tool: .ai, duration: 3.5, style: .success, short: "Codex done"))
                }
                self.wasActive = ids
                if sessions != self.active { withAnimation { self.active = sessions } }
                if self.limits == nil, self.index.latestLimits != nil, self.codexPath == nil { self.applyFallback(reason: "Showing last seen limits") }
            }
        }
    }

    private static func aggregate(_ entries: [CodexTranscriptIndex.Entry], days: Int, index: CodexTranscriptIndex) -> LocalStats {
        var s = LocalStats()
        let today = LocalDay.today
        let first = today - days + 1
        var perDay = [Int: DayUsage]()
        var projects = [Int32: Int]()
        let now = Date().timeIntervalSince1970
        var last: Double = 0
        for e in entries {
            let day = Int(e.day)
            guard day >= first else { continue }
            var d = perDay[day] ?? DayUsage(day: day)
            d.tokens += e.tokens; d.output += e.output; d.messages += 1
            perDay[day] = d
            s.allTimeTokens += e.tokens
            last = max(last, e.time)
            if now - e.time < 5 * 3600 { s.windowTokens += e.tokens }
            if now - e.time < 3600 { s.lastHourTokens += e.tokens }
            if day == today {
                s.today.input += e.tokens - e.output
                s.today.output += e.output
                s.todayMessages += 1
                projects[e.project, default: 0] += e.tokens
            }
        }
        s.days = (first...today).map { perDay[$0] ?? DayUsage(day: $0) }
        s.topProjects = projects.sorted { $0.value > $1.value }.prefix(5).map { (name: index.projectName($0.key), tokens: $0.value) }
        s.lastActivity = last > 0 ? Date(timeIntervalSince1970: last) : nil
        var run = 0, best = 0
        for d in s.days { if d.messages > 0 { run += 1; best = max(best, run) } else { run = 0 } }
        s.bestStreak = best
        var idx = s.days.count - 1, streak = 0
        if idx >= 0, s.days[idx].messages == 0 { idx -= 1 }
        while idx >= 0, s.days[idx].messages > 0 { streak += 1; idx -= 1 }
        s.streak = streak
        return s
    }
}

/// Aggregates both agents for the notch's live activity and the menu bar.
@Observable
final class AIUsageCenter {
    static let shared = AIUsageCenter()
    let claude = ClaudeService()
    let codex = CodexService()

    func start() {
        claude.start()
        codex.start()
    }

    func refresh() {
        claude.refreshNow()
        codex.refreshNow()
    }

    enum Activity: Equatable { case claudeBusy(Int), claudeWaiting(Int), codexBusy(Int) }

    var agentActivity: Activity? {
        let waiting = claude.sessions.filter { $0.status == .waiting }.count
        if waiting > 0 { return .claudeWaiting(waiting) }
        let busy = claude.sessions.filter { $0.status == .busy }.count
        if busy > 0 { return .claudeBusy(busy) }
        if !codex.active.isEmpty { return .codexBusy(codex.active.count) }
        return nil
    }

    var allSessions: [AgentSession] { claude.sessions + codex.active }
}
