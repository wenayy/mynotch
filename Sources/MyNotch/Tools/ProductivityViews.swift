import SwiftUI
import AppKit

// MARK: - Calendar

struct CalendarView: View {
    private var cal: CalendarService { .shared }
    @State private var selected = Calendar.current.startOfDay(for: Date())

    var body: some View {
        if !cal.authorized {
            EmptyState(symbol: "calendar.badge.exclamationmark", title: "Calendar access needed",
                       subtitle: "MyNotch reads your events to show today's agenda and meeting join buttons. Nothing leaves your Mac.",
                       actionTitle: "Allow Calendar Access") { cal.requestAccess() }
        } else {
            HStack(alignment: .top, spacing: 12) {
                weekStrip.frame(width: 238)
                agenda
            }
            .onAppear { cal.reload() }
        }
    }

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekStrip: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selected, format: .dateTime.month(.wide).year()).font(.system(size: 12, weight: .bold))
                HStack(spacing: 3) {
                    ForEach(days, id: \.self) { d in
                        let isSel = Calendar.current.isDate(d, inSameDayAs: selected)
                        let count = cal.events(on: d).count
                        VStack(spacing: 3) {
                            Text(d, format: .dateTime.weekday(.narrow)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            Text(d, format: .dateTime.day()).font(.rounded(13, isSel ? .bold : .medium))
                                .foregroundStyle(isSel ? .black : .white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(isSel ? Theme.accent : .clear))
                            HStack(spacing: 2) {
                                ForEach(0..<min(count, 3), id: \.self) { _ in Circle().fill(Theme.accent.opacity(0.8)).frame(width: 3.5, height: 3.5) }
                            }.frame(height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selected = d } }
                    }
                }
                Spacer(minLength: 0)
                if let next = cal.next {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UP NEXT").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.tertiary)
                        Text(next.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(next.isNow ? "Happening now" : "\(Fmt.reset(next.start)) · \(Fmt.time(next.start))")
                            .font(.system(size: 9.5)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    private var agenda: some View {
        let list = cal.events(on: selected)
        return VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: Calendar.current.isDateInToday(selected) ? "Today" : selected.formatted(.dateTime.weekday(.wide).day().month()),
                         trailing: "\(list.count) event\(list.count == 1 ? "" : "s")")
            if list.isEmpty {
                EmptyState(symbol: "sun.max", title: "Nothing scheduled", subtitle: "Enjoy the free time.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(list) { e in EventRow(event: e) }
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    var event: AgendaEvent
    var body: some View {
        HoverRow {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3.5, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .strikethrough(event.end < Date(), color: Theme.tertiary)
                        .foregroundStyle(event.end < Date() ? Theme.secondary : .white)
                    Text(event.allDay ? "All day · \(event.calendar)" :
                            "\(Fmt.time(event.start)) – \(Fmt.time(event.end))" + (event.location.map { " · \($0)" } ?? ""))
                        .font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer()
                if event.isNow {
                    Text("NOW").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Color.green))
                }
                if let url = event.meetingURL, event.end > Date() {
                    PillButton(title: "Join", symbol: "video.fill", prominent: true, tint: .green) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

// MARK: - Timers

struct TimersView: View {
    private var t: TimerEngine { .shared }
    @State private var customMinutes: Double = 15

    var body: some View {
        HStack(spacing: 10) {
            pomodoro.frame(width: 210)
            countdowns
            stopwatch.frame(width: 180)
        }
    }

    private var pomodoro: some View {
        Card(padding: 11) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let p = t.pomodoro
                VStack(spacing: 6) {
                    HStack {
                        Text("Pomodoro").font(.system(size: 11.5, weight: .bold))
                        Spacer()
                        Text(t.pomodoroPhase.rawValue).font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(t.pomodoroPhase == .focus ? .orange : .green)
                    }
                    ZStack {
                        Ring(progress: p?.progress ?? 0, color: t.pomodoroPhase == .focus ? .orange : .green, lineWidth: 7)
                        VStack(spacing: 0) {
                            Text(Fmt.clock(p?.remaining ?? AppSettings.shared.pomodoroFocus * 60))
                                .font(.rounded(22, .bold)).monospacedDigit()
                            Text("round \(t.pomodoroRounds + 1)").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(width: 104, height: 104)
                    HStack(spacing: 6) {
                        IconButton(symbol: (p?.running ?? false) ? "pause.fill" : "play.fill", size: 12, active: true, tint: .orange) { t.togglePomodoro() }
                        IconButton(symbol: "goforward.plus", size: 11, help: "+1 minute") { t.addMinuteToPomodoro() }
                        IconButton(symbol: "forward.end.fill", size: 11, help: "Skip phase") { t.skipPomodoro() }
                        IconButton(symbol: "arrow.counterclockwise", size: 11, help: "Reset") { t.resetPomodoro() }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var countdowns: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Countdowns").font(.system(size: 11.5, weight: .bold))
                HStack(spacing: 5) {
                    ForEach([1, 5, 10, 25, 45], id: \.self) { m in
                        PillButton(title: "\(m)m") { t.addCountdown(minutes: Double(m)) }
                    }
                }
                HStack(spacing: 6) {
                    Slider(value: $customMinutes, in: 1...120).controlSize(.mini)
                    PillButton(title: "\(Int(customMinutes.rounded()))m", symbol: "plus", prominent: true) { t.addCountdown(minutes: customMinutes.rounded()) }
                }
                if t.countdowns.isEmpty {
                    Text("Start one — it shows in the notch while it runs.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(t.countdowns) { c in
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    HStack(spacing: 8) {
                                        Ring(progress: c.progress, color: .orange, lineWidth: 3).frame(width: 18, height: 18)
                                        Text(c.label).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                                        Spacer()
                                        Text(Fmt.clock(c.remaining)).font(.rounded(13, .bold)).monospacedDigit()
                                            .foregroundStyle(c.running ? .white : Theme.tertiary)
                                        IconButton(symbol: "goforward.plus", size: 9) { t.addMinute(c) }
                                        IconButton(symbol: c.running ? "pause.fill" : "play.fill", size: 9) { t.toggle(c) }
                                        IconButton(symbol: "xmark", size: 9) { t.remove(c) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var stopwatch: some View {
        Card(padding: 11) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stopwatch").font(.system(size: 11.5, weight: .bold))
                    Text(stopwatchText(t.stopwatchElapsed)).font(.rounded(24, .bold)).monospacedDigit()
                    HStack(spacing: 6) {
                        IconButton(symbol: t.stopwatchRunning ? "pause.fill" : "play.fill", size: 11, active: true, tint: .cyan) { t.toggleStopwatch() }
                        IconButton(symbol: "flag.fill", size: 10, help: "Lap") { t.lap() }
                        IconButton(symbol: "arrow.counterclockwise", size: 10, help: "Reset") { t.resetStopwatch() }
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(t.laps.enumerated()), id: \.offset) { i, lap in
                                HStack {
                                    Text("Lap \(t.laps.count - i)").foregroundStyle(Theme.tertiary)
                                    Spacer()
                                    Text(stopwatchText(lap)).monospacedDigit()
                                }
                                .font(.system(size: 10))
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopwatchText(_ s: TimeInterval) -> String {
        let cs = Int((s * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }
}

// MARK: - System stats

struct StatsView: View {
    enum Page: String, CaseIterable { case system = "System", screenTime = "Screen Time" }
    @State private var page: Page = .system
    private var s: SystemStats { .shared }
    private var st: ScreenTime { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $page) { ForEach(Page.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220).controlSize(.small)
            if page == .system { system } else { screenTime }
        }
        .onAppear { s.attach() }
        .onDisappear { s.detach() }
    }

    private var system: some View {
        HStack(spacing: 10) {
            gauge("CPU", s.cpu, "\(Int(s.cpu * 100))%", Color(hex: 0x4F8BFF), thermalNote)
            gauge("Memory", s.memoryFraction, "\(Int(s.memoryFraction * 100))%", Color(hex: 0x9D7BFF),
                  "\(Fmt.bytes(Int64(s.memoryUsed))) of \(Fmt.bytes(Int64(s.memoryTotal)))")
            gauge("Disk", s.diskFraction, "\(Int(s.diskFraction * 100))%", Color(hex: 0xFFB547), "\(Fmt.bytes(s.diskFree)) free")
            battery
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Network").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    Label(Fmt.rate(s.netDown), systemImage: "arrow.down").font(.rounded(12, .semibold)).foregroundStyle(.green)
                    Label(Fmt.rate(s.netUp), systemImage: "arrow.up").font(.rounded(12, .semibold)).foregroundStyle(.cyan)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var thermalNote: String {
        switch s.thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot — throttling"
        case .critical: return "Critical heat"
        @unknown default: return ""
        }
    }

    private func gauge(_ title: String, _ value: Double, _ label: String, _ color: Color, _ sub: String) -> some View {
        Card(padding: 10) {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                ZStack {
                    Ring(progress: value, color: color, lineWidth: 7)
                    Text(label).font(.rounded(15, .bold)).monospacedDigit()
                        .contentTransition(.numericText(value: value))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
                .frame(width: 74, height: 74)
                Text(sub).font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var battery: some View {
        Card(padding: 10) {
            VStack(spacing: 5) {
                Text("Battery").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                if let p = s.batteryPercent {
                    ZStack {
                        Ring(progress: Double(p) / 100, color: p <= 20 ? .red : .green, lineWidth: 7)
                        VStack(spacing: 0) {
                            if s.charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green) }
                            Text("\(p)%").font(.rounded(15, .bold))
                        }
                    }
                    .frame(width: 74, height: 74)
                    Text([s.timeRemaining.map { (s.charging ? "full in " : "") + Fmt.duration(Double($0) * 60, short: false) },
                          s.health.map { "health \($0)%" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                    if let c = s.cycleCount { Text("\(c) cycles").font(.system(size: 8.5)).foregroundStyle(Theme.tertiary) }
                } else {
                    Spacer(); Text("No battery").font(.system(size: 10)).foregroundStyle(Theme.tertiary); Spacer()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var screenTime: some View {
        HStack(spacing: 10) {
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                    Text(Fmt.duration(st.totalToday)).font(.rounded(24, .bold))
                    Spacer(minLength: 0)
                    let maxW = max(1, st.week.map(\.seconds).max() ?? 1)
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(st.week, id: \.day) { d in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2).fill(d.day == LocalDay.today ? Theme.accent : Color.white.opacity(0.3))
                                    .frame(height: max(2, 60 * d.seconds / maxW))
                                Text(LocalDay.date(d.day), format: .dateTime.weekday(.narrow)).font(.system(size: 8)).foregroundStyle(Theme.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(width: 210)
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Most used today")
                    if st.today.isEmpty { Text("Tracking starts now — check back later.").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
                    ForEach(st.today.prefix(5), id: \.id) { app in
                        HStack(spacing: 8) {
                            if let icon = AppInfo.icon(forBundleID: app.id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(AppInfo.name(forBundleID: app.id) ?? app.id).font(.system(size: 11)).lineLimit(1).frame(width: 120, alignment: .leading)
                            LinearMeter(value: app.seconds / max(1, st.today.first?.seconds ?? 1), color: Theme.accent, height: 4)
                            Text(Fmt.duration(app.seconds, short: true)).font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondary).frame(width: 34, alignment: .trailing)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Notes

struct NotesView: View {
    let vm: NotchViewModel
    private var store: NotesStore { .shared }
    @State private var text = ""
    @State private var thought = ""
    @State private var justSaved = false
    @FocusState private var focus: Field?
    enum Field { case thought, editor }

    var body: some View {
        VStack(spacing: 8) {
            captureBar
            HStack(spacing: 10) {
                list.frame(width: 178)
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    .focused($focus, equals: .editor)
                    .onChange(of: text) { _, v in if let id = store.selected?.id { store.update(id, text: v) } }
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.focusToken) { _, _ in focus = .thought }
        .onChange(of: store.pendingTyping) { _, v in
            guard !v.isEmpty else { return }
            thought += v
            store.pendingTyping = ""
            focus = .thought
        }
        .onChange(of: focus) { _, f in if f != nil { vm.takeKeyboard() } }
    }

    private var captureBar: some View {
        HStack(spacing: 8) {
            Image(systemName: justSaved ? "checkmark.circle.fill" : "lightbulb.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(justSaved ? .green : .yellow)
                .contentTransition(.symbolEffect(.replace))
            TextField("Quick thought… Enter saves · ⌘Enter saves & keeps open · Esc closes", text: $thought)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focus, equals: .thought)
                .onSubmit { save(keepOpen: NSEvent.modifierFlags.contains(.command)) }
                .onKeyPress(.escape) { vm.close(); return .handled }
            Text("⌃⌥J").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.tertiary.opacity(0.6)))
                .help("Press ⌃⌥J anywhere to jot a thought")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(focus == .thought ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(focus == .thought ? Color.yellow.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { focus = .thought }
    }

    private var list: some View {
        VStack(spacing: 4) {
            HStack {
                SectionLabel(text: "Notes · \(store.notes.count)")
                IconButton(symbol: "square.and.pencil", size: 10, help: "New note") { save(); store.add(); load(); focus = .editor }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.notes) { n in NoteRow(note: n, selected: n.id == store.selected?.id) {
                        save(); store.selectedID = n.id; load()
                    } onDelete: {
                        store.delete(n); load()
                    } }
                }
            }
        }
    }

    private func save(keepOpen: Bool) {
        let t = thought
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.addThought(t)
        thought = ""
        withAnimation { justSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { justSaved = false } }
        if !keepOpen && vm.holdOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vm.close() }
        }
    }

    private func load() { text = store.selected?.text ?? "" }
    private func save() { if let id = store.selected?.id { store.update(id, text: text) } }
}

private struct NoteRow: View {
    var note: Note
    var selected: Bool
    var onSelect: () -> Void
    var onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(note.updated, style: .relative).font(.system(size: 8.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            if hover {
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 9.5)).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.2) : (hover ? Color.white.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
