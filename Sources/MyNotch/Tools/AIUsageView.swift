import SwiftUI
import AppKit

struct AIUsageView: View {
    enum Page: String, CaseIterable { case overview = "Limits", sessions = "Sessions", history = "History" }
    @State private var page: Page = .overview
    private var ai: AIUsageCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { p in
                    Button { withAnimation(.easeInOut(duration: 0.15)) { page = p } } label: {
                        HStack(spacing: 4) {
                            Text(p.rawValue)
                            if p == .sessions, !ai.allSessions.isEmpty {
                                Text("\(ai.allSessions.count)").font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.15)))
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(page == p ? .white : Theme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(page == p ? Color.white.opacity(0.13) : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if ai.claude.limitsLoading || ai.codex.limitsLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                }
                IconButton(symbol: "arrow.clockwise", size: 10, help: "Refresh now") { ai.refresh() }
            }
            Group {
                switch page {
                case .overview: overview
                case .sessions: SessionsList()
                case .history: HistoryPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                // Opening this tab is exactly when stale numbers are most visible — refresh if the
                // last successful fetch is older than the refresh interval (covers a missed timer
                // tick, e.g. right after waking from sleep or App Nap throttling).
                let staleAfter = max(60, AppSettings.shared.usageRefreshMinutes * 60)
                if ai.claude.limits == nil || Date().timeIntervalSince(ai.claude.limits!.fetchedAt) > staleAfter
                    || ai.codex.limits == nil || Date().timeIntervalSince(ai.codex.limits!.fetchedAt) > staleAfter {
                    ai.refresh()
                }
            }
        }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            if AppSettings.shared.claudeEnabled { ClaudeCard() }
            if AppSettings.shared.codexEnabled { CodexCard() }
            if !AppSettings.shared.claudeEnabled && !AppSettings.shared.codexEnabled {
                EmptyState(symbol: "sparkle", title: "AI tracking is off", subtitle: "Turn on Claude or Codex in Settings › AI Usage.")
            }
        }
    }
}

// MARK: - Cards

private struct ProviderHeader: View {
    var symbol: String
    var name: String
    var color: Color
    var plan: String?
    var updated: Date?
    var busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if name == "Claude" {
                SparkIcon(color: color, animating: busy, size: 12)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            }
            Text(name).font(.system(size: 12.5, weight: .bold))
            if let plan {
                Text(plan).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            Spacer()
            if let updated {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(Fmt.ago(updated)).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

private struct WindowRing: View {
    var window: UsageWindow?
    var title: String
    var color: Color
    var size: CGFloat = 60
    var body: some View {
        VStack(spacing: 3) {
            UsageRing(percent: window?.percent, color: color, size: size, lineWidth: 6)
            Text(window?.label ?? title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(window?.resetsAt != nil ? "resets \(Fmt.reset(window?.resetsAt))" : " ")
                    .font(.system(size: 8.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
        .frame(minWidth: size + 10)
    }
}

private struct StatLine: View {
    var label: String
    var value: String
    var color: Color = .white
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
    }
}

private struct ClaudeCard: View {
    private var c: ClaudeService { AIUsageCenter.shared.claude }
    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeader(symbol: "asterisk", name: "Claude", color: .claude, plan: c.plan,
                               updated: c.limits?.fetchedAt, busy: c.sessions.contains { $0.status == .busy })
                HStack(alignment: .top, spacing: 10) {
                    WindowRing(window: c.limits?.session, title: "Session", color: .claude)
                    WindowRing(window: c.limits?.weekly, title: "Weekly", color: .claude)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.tokens(c.stats.today.total)).font(.rounded(20, .bold)).contentTransition(.numericText())
                        Text("tokens today").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).padding(.top, -4)
                        StatLine(label: "Output", value: Fmt.tokens(c.stats.today.output))
                        StatLine(label: "This window", value: Fmt.tokens(c.stats.windowTokens))
                        StatLine(label: "Msgs · tools", value: "\(c.stats.todayMessages) · \(c.stats.todayToolCalls)")
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                MiniTrend(days: c.stats.days, color: .claude)
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let err = c.limitsError, c.limits == nil {
            Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
        } else if let s = c.limits?.session {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let hit = s.projectedLimitDate {
                    Label("At this pace you'll hit the limit ~\(Fmt.time(hit))", systemImage: "flame.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Label(s.percent < 1 ? "Fresh window — all yours" : "On track — the window resets before you run out",
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.green.opacity(0.9)).lineLimit(1)
                }
            }
        } else if !c.installed {
            Text("Claude Code not found on this Mac").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct CodexCard: View {
    private var c: CodexService { AIUsageCenter.shared.codex }
    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                ProviderHeader(symbol: "chevron.left.forwardslash.chevron.right", name: "Codex", color: .codex,
                               plan: c.limits?.plan, updated: c.limits?.fetchedAt, busy: !c.active.isEmpty)
                HStack(alignment: .top, spacing: 10) {
                    WindowRing(window: c.limits?.primary, title: "Primary", color: .codex)
                    if let s = c.limits?.secondary {
                        WindowRing(window: s, title: "Secondary", color: .codex)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.tokens(c.stats.today.total)).font(.rounded(20, .bold)).contentTransition(.numericText())
                        Text("tokens today").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).padding(.top, -4)
                        StatLine(label: "Output", value: Fmt.tokens(c.stats.today.output))
                        StatLine(label: "Last 5h", value: Fmt.tokens(c.stats.windowTokens))
                        if let r = c.limits?.resetCredits, r > 0 {
                            StatLine(label: "Free resets", value: "\(r) available", color: .codex)
                        } else {
                            StatLine(label: "Turns today", value: "\(c.stats.todayMessages)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
                MiniTrend(days: c.stats.days, color: .codex)
                if let reached = c.limits?.limitReached {
                    Label("Limit reached (\(reached))", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.red)
                } else if let err = c.limitsError {
                    Label(err, systemImage: "info.circle").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                } else if let p = c.limits?.primary, let hit = p.projectedLimitDate {
                    Label("At this pace you'll hit the limit ~\(Fmt.reset(hit))", systemImage: "flame.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                } else if c.limits != nil {
                    Label("Via \(c.limits?.source ?? "Codex")", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.green.opacity(0.9)).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Sessions

private struct SessionsList: View {
    private var ai: AIUsageCenter { .shared }
    var body: some View {
        if ai.allSessions.isEmpty {
            EmptyState(symbol: "terminal", title: "No live agent sessions",
                       subtitle: "Start `claude` or `codex` in a terminal. Running sessions appear here with their status, and the notch tells you when they finish or need you.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(ai.allSessions) { s in SessionRow(session: s) }
                }
            }
        }
    }
}

private struct SessionRow: View {
    var session: AgentSession
    private var color: Color {
        switch session.status {
        case .busy: session.source == .claude ? .claude : .codex
        case .waiting: .yellow
        case .idle: Color.white.opacity(0.35)
        }
    }

    var body: some View {
        HoverRow(action: jump) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 26, height: 26)
                    if session.source == .claude {
                        SparkIcon(color: color, animating: session.status == .busy, size: 11)
                    } else {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(session.source == .claude ? "Claude" : "Codex").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Text(session.cwd.replacingOccurrences(of: Paths.home.path, with: "~"))
                        .font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(statusText).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                }
                if session.pid > 0 {
                    IconButton(symbol: "arrow.up.forward.app", size: 10, help: "Jump to terminal") { jump() }
                }
                if FileManager.default.fileExists(atPath: session.cwd) {
                    IconButton(symbol: "folder", size: 10, help: "Reveal folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
                    }
                }
            }
        }
    }

    private var statusText: String {
        let since = Fmt.duration(Date().timeIntervalSince(session.statusSince), short: true)
        switch session.status {
        case .busy: return session.source == .codex ? "Active" : "Working · \(since)"
        case .waiting: return "Needs you · \(session.waitingFor ?? "input")"
        case .idle: return "Idle · \(since)"
        }
    }

    private func jump() {
        if session.pid > 0 { AppInfo.activateHostApp(ofPID: session.pid) }
        NotchManager.shared?.closeAll()
    }
}

// MARK: - History

private struct HistoryPage: View {
    private var ai: AIUsageCenter { .shared }
    @State private var hoverDay: Int?

    var body: some View {
        HStack(spacing: 10) {
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Last 14 days", trailing: hoverLabel)
                    bars
                    HStack(spacing: 10) {
                        legend(.claude, "Claude"); legend(.codex, "Codex")
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Claude streak", trailing: "best \(ai.claude.stats.bestStreak)d")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(ai.claude.stats.streak)").font(.rounded(24, .bold))
                        Text(ai.claude.stats.streak == 1 ? "day" : "days").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Image(systemName: "flame.fill").foregroundStyle(ai.claude.stats.streak > 0 ? .orange : Theme.tertiary)
                    }
                    Heatmap(days: ai.claude.stats.days, color: .claude)
                }
            }
            .frame(width: 210)
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Today by project")
                    let projects = mergedProjects
                    if projects.isEmpty {
                        Text("No activity yet today").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    }
                    ForEach(projects.prefix(4), id: \.name) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(Fmt.tokens(p.tokens)).font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondary)
                            }
                            LinearMeter(value: Double(p.tokens) / Double(max(1, projects.first?.tokens ?? 1)), color: p.color, height: 3)
                        }
                    }
                    Spacer(minLength: 0)
                    if let m = ai.claude.stats.models.first {
                        Text("Mostly \(m.name)").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .frame(width: 190)
        }
    }

    private var mergedProjects: [(name: String, tokens: Int, color: Color)] {
        let c = ai.claude.stats.topProjects.map { (name: $0.name, tokens: $0.tokens, color: Color.claude) }
        let x = ai.codex.stats.topProjects.map { (name: $0.name, tokens: $0.tokens, color: Color.codex) }
        return (c + x).sorted { $0.tokens > $1.tokens }
    }

    private var hoverLabel: String? {
        guard let d = hoverDay else { return nil }
        let c = ai.claude.stats.days.first { $0.day == d }?.tokens ?? 0
        let x = ai.codex.stats.days.first { $0.day == d }?.tokens ?? 0
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return "\(f.string(from: LocalDay.date(d))) · \(Fmt.tokens(c + x))"
    }

    private var bars: some View {
        let today = LocalDay.today
        let range = Array((today - 13)...today)
        let claude = Dictionary(uniqueKeysWithValues: ai.claude.stats.days.map { ($0.day, $0.tokens) })
        let codex = Dictionary(uniqueKeysWithValues: ai.codex.stats.days.map { ($0.day, $0.tokens) })
        let maxV = max(1, range.map { (claude[$0] ?? 0) + (codex[$0] ?? 0) }.max() ?? 1)
        return GeometryReader { g in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(range, id: \.self) { d in
                    let c = Double(claude[d] ?? 0), x = Double(codex[d] ?? 0)
                    let h = g.size.height - 12
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        VStack(spacing: 1) {
                            if x > 0 { RoundedRectangle(cornerRadius: 2).fill(Color.codex).frame(height: max(2, h * x / Double(maxV))) }
                            if c > 0 { RoundedRectangle(cornerRadius: 2).fill(Color.claude).frame(height: max(2, h * c / Double(maxV))) }
                            if c == 0 && x == 0 { RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08)).frame(height: 2) }
                        }
                        .opacity(hoverDay == nil || hoverDay == d ? 1 : 0.45)
                        Text(dayLetter(d)).font(.system(size: 7.5, weight: d == today ? .bold : .regular))
                            .foregroundStyle(d == today ? .white : Theme.tertiary).frame(height: 10)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hoverDay = $0 ? d : (hoverDay == d ? nil : hoverDay) }
                }
            }
        }
    }

    private func dayLetter(_ d: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"
        return f.string(from: LocalDay.date(d))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t).font(.system(size: 9.5)).foregroundStyle(Theme.secondary) }
    }
}

/// GitHub-style activity grid (columns = weeks).
struct Heatmap: View {
    var days: [DayUsage]
    var color: Color
    var weeks = 12

    var body: some View {
        let recent = Array(days.suffix(weeks * 7))
        let maxV = max(1, recent.map(\.tokens).max() ?? 1)
        let padded = Array(repeating: DayUsage(day: -1), count: max(0, weeks * 7 - recent.count)) + recent
        HStack(spacing: 2.5) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 2.5) {
                    ForEach(0..<7, id: \.self) { d in
                        let item = padded[w * 7 + d]
                        let level = item.tokens == 0 ? 0 : 0.25 + 0.75 * sqrt(Double(item.tokens) / Double(maxV))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.tokens == 0 ? Color.white.opacity(item.day < 0 ? 0.02 : 0.07) : color.opacity(level))
                            .frame(width: 11, height: 11)
                            .help(item.day >= 0 ? "\(Fmt.tokens(item.tokens)) tokens" : "")
                    }
                }
            }
        }
    }
}

/// Seven tiny bars: tokens per day, today on the right.
private struct MiniTrend: View {
    var days: [DayUsage]
    var color: Color
    var body: some View {
        let last = Array(days.suffix(7))
        let maxV = max(1, last.map(\.tokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            Text("7d").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiary).frame(width: 14, alignment: .leading)
            ForEach(Array(last.enumerated()), id: \.offset) { i, d in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(d.tokens > 0 ? color.opacity(i == last.count - 1 ? 1 : 0.55) : Color.white.opacity(0.08))
                        .frame(height: max(2, 16 * CGFloat(d.tokens) / CGFloat(maxV)))
                }
                .frame(maxWidth: .infinity)
                .help("\(LocalDay.date(d.day).formatted(.dateTime.weekday(.abbreviated))): \(Fmt.tokens(d.tokens)) tokens")
            }
            Text(Fmt.tokens(last.reduce(0) { $0 + $1.tokens })).font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondary).frame(width: 36, alignment: .trailing)
        }
        .frame(height: 18)
    }
}
