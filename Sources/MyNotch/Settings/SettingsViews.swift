import SwiftUI
import AppKit

struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", tools = "Tools", live = "Live Activities",
             ai = "AI Usage", apps = "Apps & Pins", clipboard = "Clipboard & Shelf", timers = "Timers & Weather",
             integrations = "Automation", about = "About"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .appearance: "paintpalette.fill"
            case .tools: "square.grid.3x2.fill"
            case .live: "capsule.fill"
            case .ai: "sparkle"
            case .apps: "app.badge.fill"
            case .clipboard: "doc.on.clipboard.fill"
            case .timers: "timer"
            case .integrations: "link"
            case .about: "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .general: .gray
            case .appearance: .pink
            case .tools: .blue
            case .live: .purple
            case .ai: .claude
            case .apps: .indigo
            case .clipboard: .teal
            case .timers: .orange
            case .integrations: .green
            case .about: .secondary
            }
        }
    }

    @State private var section: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label {
                    Text(s.rawValue)
                } icon: {
                    Image(systemName: s.symbol).foregroundStyle(.white).font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(s.color.gradient))
                }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200)
        } detail: {
            Group {
                switch section {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .tools: ToolsSettings()
                case .live: LiveSettings()
                case .ai: AISettings()
                case .apps: AppsSettings()
                case .clipboard: ClipboardSettings()
                case .timers: TimersWeatherSettings()
                case .integrations: AutomationSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.rawValue)
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var s = AppSettings.shared
    @State private var launch = LaunchAtLogin.enabled
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launch).onChange(of: launch) { _, v in LaunchAtLogin.set(v) }
                Toggle("Show menu bar icon", isOn: $s.showMenuBarIcon)
                LabeledContent("Open / close notch") {
                    ShortcutRecorder(combo: s.toggleCombo, placeholder: s.hotKey.title) { s.toggleCombo = $0 }
                }
                Toggle("Quick-thought shortcut", isOn: $s.quickJotHotKey)
                if s.quickJotHotKey {
                    LabeledContent("Quick thought") {
                        ShortcutRecorder(combo: s.jotCombo, placeholder: "⌃⌥J") { s.jotCombo = $0 }
                    }
                }
                Text("Click a box and press keys (needs ⌘, ⌃ or ⌥). For a two-step shortcut press a second key right after, e.g. ⌃N then O. Esc cancels, ⌫ resets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Opening") {
                Picker("Open on", selection: $s.openTrigger) { ForEach(OpenTrigger.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                if s.openTrigger == .hover {
                    LabeledContent("Hover delay") {
                        HStack { Slider(value: $s.hoverDelay, in: 0...0.8); Text("\(Int(s.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 56) }
                    }
                }
                LabeledContent("Close delay") {
                    HStack { Slider(value: $s.closeDelay, in: 0.05...1.5); Text("\(Int(s.closeDelay * 1000)) ms").monospacedDigit().frame(width: 56) }
                }
                Toggle("Two-finger swipe down on the notch opens it", isOn: $s.scrollToOpen)
                Toggle("Hovering a tab icon switches to it", isOn: $s.hoverSwitchTabs)
                Toggle("Haptic feedback", isOn: $s.haptics)
                Toggle("Play sounds for alerts", isOn: $s.playSounds)
            }
            Section("Behaviour") {
                Picker("Show notch on", selection: $s.displayChoice) { ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) } }
                Toggle("Hide when an app is full screen", isOn: $s.hideInFullscreen)
                Toggle("Reopen the last tool I used", isOn: $s.rememberLastTool)
                if !s.rememberLastTool {
                    Picker("Always open on", selection: $s.defaultTool) { ForEach(s.visibleTools) { Label($0.title, systemImage: $0.symbol).tag($0) } }
                }
            }
        }
    }
}

private struct AppearanceSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Theme") {
                Picker("Style", selection: $s.theme) { ForEach(NotchTheme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                LabeledContent("Accent") {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases) { a in
                            Button { s.accent = a } label: {
                                ZStack {
                                    if a == .artwork {
                                        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                                    } else { Circle().fill(a.base) }
                                    if s.accent == a { Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3) }
                                }
                                .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain).help(a.title)
                        }
                    }
                }
                Toggle("Glow under the notch on hover", isOn: $s.showHoverGlow)
            }
            Section("Size") {
                Picker("Open size", selection: $s.panelSize) { ForEach(PanelSize.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                LabeledContent("Simulated notch width") {
                    HStack { Slider(value: $s.simulatedNotchWidth, in: 140...260, step: 2); Text("\(Int(s.simulatedNotchWidth)) pt").frame(width: 50) }
                }
                Text("Used on displays without a camera notch.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToolsSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                List {
                    ForEach(order, id: \.self) { tool in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(systemName: tool.symbol).frame(width: 20).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.title)
                                Text(tool.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { s.enabledTools.contains(tool) }, set: { on in
                                if on { s.enabledTools.insert(tool) } else if s.enabledTools.count > 1 { s.enabledTools.remove(tool) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    .onMove { from, to in
                        var o = order
                        o.move(fromOffsets: from, toOffset: to)
                        s.toolOrder = o
                    }
                }
                .frame(minHeight: 420)
            } header: {
                Text("Drag to reorder. Disabled tools disappear from the notch's tab bar.")
            }
        }
    }
    private var order: [ToolKind] { s.toolOrder + ToolKind.allCases.filter { !s.toolOrder.contains($0) } }
}

private struct LiveSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Closed notch shows…") {
                Toggle("Music that's playing (artwork + equalizer)", isOn: $s.liveMedia)
                Toggle("Claude / Codex needs you", isOn: $s.liveAI)
                Toggle("Also show while agents are working", isOn: $s.liveAIWorking)
                Toggle("Running timers & Pomodoro", isOn: $s.liveTimer)
                Toggle("Charging animation when you plug in", isOn: $s.liveCharging)
                Toggle("Warn when CPU or memory stays high", isOn: $s.resourceAlerts)
                Toggle("Claude session % when nothing else is happening", isOn: $s.alwaysShowUsage)
            }
            Section("Banners") {
                Toggle("Show a banner when the song changes", isOn: $s.peekSongChanges)
                Toggle("One player at a time (starting one pauses the others)", isOn: $s.exclusivePlayback)
            }
            Section("Volume & brightness") {
                Picker("Notch HUD", selection: $s.hudMode) { ForEach(HUDMode.allCases) { Text($0.title).tag($0) } }
                if s.hudMode == .replace {
                    Text("Grant Accessibility to MyNotch in System Settings › Privacy & Security. The media keys are handled by MyNotch and the system bezel is hidden. ⌥⇧ + key for fine steps.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section("Ticker") {
                Toggle("Scroll a message across the notch", isOn: $s.tickerEnabled)
                TextField("Message", text: $s.tickerText, prompt: Text("Ship it 🚀"))
                Text("Scripts can set it too: open -g \"mynotch://ticker?text=Deploying…\"").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct AISettings: View {
    @Bindable var s = AppSettings.shared
    private var ai: AIUsageCenter { .shared }
    var body: some View {
        Form {
            Section("Claude Code") {
                Toggle("Track Claude Code", isOn: $s.claudeEnabled)
                Toggle("Live plan limits (session / weekly %)", isOn: $s.claudeLimitsEnabled)
                LabeledContent("Status") {
                    if let l = ai.claude.limits?.session {
                        Text("Session \(Fmt.percent(l.percent)) · updated \(Fmt.ago(ai.claude.limits?.fetchedAt))").foregroundStyle(.secondary)
                    } else {
                        Text(ai.claude.limitsError ?? "Waiting…").foregroundStyle(.secondary)
                    }
                }
                Text("Limits come from the same endpoint Claude Code's /usage uses, authenticated with the token Claude Code already keeps in your login Keychain (read via /usr/bin/security). Tokens are never refreshed or stored by MyNotch. Token history is read from ~/.claude/projects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex") {
                Toggle("Track Codex", isOn: $s.codexEnabled)
                LabeledContent("Status") {
                    if let p = ai.codex.limits?.primary {
                        Text("\(p.label) \(Fmt.percent(p.percent)) · \(ai.codex.limits?.source ?? "")").foregroundStyle(.secondary)
                    } else {
                        Text(ai.codex.limitsError ?? "Waiting…").foregroundStyle(.secondary)
                    }
                }
                Text("Limits are read through the official `codex app-server` (account/rateLimits/read), which keeps its own login fresh. Falls back to the last rate-limit event in ~/.codex/sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refresh & alerts") {
                LabeledContent("Check limits every") {
                    HStack { Slider(value: $s.usageRefreshMinutes, in: 1...15, step: 1); Text("\(Int(s.usageRefreshMinutes)) min").frame(width: 50) }
                }
                LabeledContent("Warn me at") {
                    HStack { Slider(value: $s.usageAlertThreshold, in: 0...100, step: 5); Text(s.usageAlertThreshold == 0 ? "off" : "\(Int(s.usageAlertThreshold))%").frame(width: 50) }
                }
                Toggle("Banner when an agent finishes", isOn: $s.notifyAgentFinished)
                Toggle("Banner when Claude needs my input", isOn: $s.notifyAgentWaiting)
                Picker("History", selection: $s.historyDays) {
                    Text("4 weeks").tag(28); Text("12 weeks").tag(84); Text("6 months").tag(182)
                }
                Button("Refresh now") { ai.refresh() }
            }
        }
    }
}

private struct AppsSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                List {
                    ForEach(s.pins) { pin in
                        HStack(spacing: 10) {
                            if pin.kind == .url { Image(systemName: "globe").frame(width: 22) } else { FileIcon(path: pin.target, size: 22) }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(pin.title)
                                Text(pin.target).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if !pin.exists { Text("Missing").font(.caption).foregroundStyle(.orange) }
                            Button(role: .destructive) { s.pins.removeAll { $0.id == pin.id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                    .onMove { s.pins.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 300)
                HStack {
                    Button("Add…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = true
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        if panel.runModal() == .OK { s.pins.append(contentsOf: panel.urls.map(Pin.from(url:))) }
                    }
                    Button("Restore defaults") { s.pins = Pin.defaults }
                }
            } header: {
                Text("Pinned apps, folders, files and websites. Drag to reorder.")
            }
            Section { Toggle("Show running apps in the Apps tool", isOn: $s.showRunningApps) }
        }
    }
}

private struct ClipboardSettings: View {
    @Bindable var s = AppSettings.shared
    @State private var ignored = AppSettings.shared.clipboardIgnoredApps.joined(separator: ", ")
    var body: some View {
        Form {
            Section("Clipboard history") {
                Toggle("Record clipboard history", isOn: $s.clipboardEnabled)
                Stepper("Keep \(s.clipboardLimit) items", value: $s.clipboardLimit, in: 20...1000, step: 20)
                Picker("Auto-delete items older than", selection: $s.clipboardRetentionDays) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7); Text("30 days").tag(30); Text("Never").tag(0)
                }
                Text("Pinned items are never deleted.").font(.caption).foregroundStyle(.secondary)
                TextField("Never record from (bundle IDs)", text: $ignored)
                    .onSubmit { s.clipboardIgnoredApps = ignored.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                Text("Items marked as concealed by password managers are always skipped.").font(.caption).foregroundStyle(.secondary)
                Button("Clear history", role: .destructive) { ClipboardService.shared.clearUnpinned() }
            }
            Section("Shelf") {
                Toggle("Copy files into the shelf (instead of referencing them)", isOn: $s.shelfCopyFiles)
                Toggle("Remove items from the shelf after dragging them out", isOn: $s.shelfRemoveAfterDrag)
                Button("Reveal shelf folder") { NSWorkspace.shared.open(ShelfStore.shared.folder) }
            }
        }
    }
}

private struct TimersWeatherSettings: View {
    @Bindable var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Pomodoro") {
                Stepper("Focus: \(Int(s.pomodoroFocus)) min", value: $s.pomodoroFocus, in: 5...90, step: 5)
                Stepper("Short break: \(Int(s.pomodoroBreak)) min", value: $s.pomodoroBreak, in: 1...30)
                Stepper("Long break: \(Int(s.pomodoroLongBreak)) min", value: $s.pomodoroLongBreak, in: 5...60, step: 5)
            }
            Section("Hydration") {
                Toggle("Remind me to drink water", isOn: $s.hydrationReminder)
                if s.hydrationReminder { Stepper("Every \(Int(s.hydrationMinutes)) min", value: $s.hydrationMinutes, in: 10...180, step: 5) }
            }
            Section("Weather") {
                Toggle("Use my location", isOn: $s.weatherUseLocation)
                TextField("City", text: $s.weatherCity, prompt: Text("e.g. Mumbai"))
                Picker("Units", selection: $s.temperatureUnit) { ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) } }.pickerStyle(.segmented)
                Button("Refresh weather") { WeatherService.shared.refresh() }
                Text("Weather by Open-Meteo — free, no account, nothing but coordinates is sent.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AutomationSettings: View {
    private let examples: [(String, String)] = [
        ("Open a tool", "open -g \"mynotch://open?tool=ai\""),
        ("Toggle the notch", "open -g \"mynotch://toggle\""),
        ("Task finished (scripts, builds, CI)", "open -g \"mynotch://task?state=done&title=Build&seconds=134\""),
        ("Task failed", "open -g \"mynotch://task?state=failed&title=Tests\""),
        ("Custom banner", "open -g \"mynotch://peek?title=Deployed&subtitle=v2.1%20is%20live&symbol=rocket.fill\""),
        ("Ticker message", "open -g \"mynotch://ticker?text=On%20a%20call\""),
        ("Wrap any command", "make build && open -g \"mynotch://task?state=done&title=make\" || open -g \"mynotch://task?state=failed&title=make\""),
    ]
    var body: some View {
        Form {
            Section {
                ForEach(examples, id: \.0) { title, cmd in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        HStack {
                            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                            Spacer()
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Anything that can open a URL can talk to the notch.")
            } footer: {
                Text("Claude Code sessions are detected automatically from ~/.claude/sessions — no hooks needed for “finished” and “needs you” banners.")
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MyNotch").font(.title2.bold())
                        Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                        Text("Your notch, rebuilt: AI limits, apps, media, shelf, clipboard and more.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Data") {
                Button("Reveal data folder") { NSWorkspace.shared.open(Paths.appSupport) }
                Button("Reset all settings…", role: .destructive) {
                    let a = NSAlert()
                    a.messageText = "Reset all MyNotch settings?"
                    a.informativeText = "Your notes, shelf and clipboard are kept. MyNotch will quit; open it again to start fresh."
                    a.addButton(withTitle: "Reset & Quit"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { AppSettings.shared.resetAll(); NSApp.terminate(nil) }
                }
            }
            Section { Button("Quit MyNotch") { NSApp.terminate(nil) } }
        }
    }
}

/// Click, then press a key combination to record a global shortcut.
/// Press one more key within a second (e.g. ⌃N then O) to make it a two-step shortcut.
struct ShortcutRecorder: View {
    var combo: KeyCombo?
    var placeholder: String
    var onChange: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var pending: KeyCombo?
    @State private var monitor: Any?
    @State private var finish: DispatchWorkItem?

    var body: some View {
        Button(action: start) {
            Text(recording ? (pending.map { "\($0.display), then…" } ?? "Press keys…") : (combo?.display ?? placeholder))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 130)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        guard !recording else { stop(); return }
        recording = true
        pending = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                                       // Esc
            if pending == nil, e.keyCode == 51 || e.keyCode == 117 { onChange(nil); stop(); return nil }   // ⌫ resets
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if var first = pending {
                // Second step: any key (modifiers optional).
                first.secondKey = UInt32(e.keyCode)
                first.display += ", " + Self.keyName(e)
                onChange(first)
                stop()
                return nil
            }
            guard f.contains(.command) || f.contains(.option) || f.contains(.control) else { NSSound.beep(); return nil }
            var mods: UInt32 = 0, text = ""
            if f.contains(.control) { mods |= 4096; text += "⌃" }
            if f.contains(.option) { mods |= 2048; text += "⌥" }
            if f.contains(.shift) { mods |= 512; text += "⇧" }
            if f.contains(.command) { mods |= 256; text += "⌘" }
            text += Self.keyName(e)
            let c = KeyCombo(keyCode: UInt32(e.keyCode), mods: mods, display: text)
            pending = c
            // No second key within 1 s → single shortcut.
            let w = DispatchWorkItem { if pending != nil { onChange(c); stop() } }
            finish = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
            return nil
        }
    }

    private func stop() {
        finish?.cancel()
        recording = false
        pending = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    static func keyName(_ e: NSEvent) -> String {
        switch e.keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let c = e.charactersIgnoringModifiers, !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.value >= 32 }) { return c.uppercased() }
            return "Key\(e.keyCode)"
        }
    }
}
