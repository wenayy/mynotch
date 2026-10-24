import AppKit
import SwiftUI
import Observation

// MARK: - Tools

enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case home, ai, apps, stats, shelf, convert, clipboard, notes, timers, media, weather, links, calendar, units, sounds, camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .ai: "AI Usage"
        case .apps: "Apps"
        case .media: "Now Playing"
        case .shelf: "Shelf"
        case .convert: "Convert"
        case .clipboard: "Clipboard"
        case .calendar: "Calendar"
        case .timers: "Timers"
        case .stats: "System"
        case .notes: "Notes"
        case .weather: "Weather"
        case .links: "Search & Links"
        case .units: "Converter"
        case .sounds: "Ambient Sounds"
        case .camera: "Mirror"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .ai: "sparkle"
        case .apps: "square.grid.2x2.fill"
        case .media: "music.note"
        case .shelf: "tray.full.fill"
        case .convert: "arrow.triangle.2.circlepath.doc.on.clipboard"
        case .clipboard: "doc.on.clipboard.fill"
        case .calendar: "calendar"
        case .timers: "timer"
        case .stats: "cpu"
        case .notes: "note.text"
        case .weather: "cloud.sun.fill"
        case .links: "magnifyingglass"
        case .units: "arrow.left.arrow.right"
        case .sounds: "waveform"
        case .camera: "camera.fill"
        }
    }

    var blurb: String {
        switch self {
        case .home: "Clock, next event, music, AI limits and your dock at a glance."
        case .ai: "Claude Code & Codex session limits, tokens, live sessions and history."
        case .apps: "Pinned apps, folders and links. Drop files on an app to open them with it."
        case .media: "Controls for whatever is playing — Spotify, Music, YouTube, anything."
        case .shelf: "Drag files onto the notch to park them, then drag them anywhere. AirDrop too."
        case .convert: "Images ⇄ JPG/PNG/HEIC/TIFF, images → PDF, PDF → images, merge PDFs, resize & compress."
        case .clipboard: "Searchable history of text, links, images and files you copy."
        case .calendar: "Today's agenda and the week ahead, with one-click meeting joins."
        case .timers: "Pomodoro, multiple countdowns and a lap stopwatch."
        case .stats: "CPU, memory, disk, network, battery health and screen time."
        case .notes: "A scratchpad plus quick notes that are always one hover away."
        case .weather: "Current conditions, next 12 hours and the week (Open-Meteo, no account)."
        case .links: "Search Google, Claude, Perplexity, GitHub… and keep bookmarks."
        case .units: "Convert length, weight, temperature, data, currency and more."
        case .sounds: "Generated rain, waves, fire, wind and noise you can layer."
        case .camera: "A quick camera mirror. Only on while you're looking at it."
        }
    }

    static let defaultEnabled: [ToolKind] = [.home, .ai, .apps, .stats, .shelf, .convert, .clipboard, .notes, .timers, .media, .weather, .links]
}

// MARK: - Pins (app launcher)

struct Pin: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case app, file, folder, url }
    var id = UUID()
    var kind: Kind
    var target: String      // file path or URL string
    var title: String

    var url: URL? {
        kind == .url ? URL(string: target) : URL(fileURLWithPath: target)
    }

    var bundleID: String? {
        guard kind == .app else { return nil }
        return Bundle(path: target)?.bundleIdentifier
    }

    var exists: Bool {
        kind == .url || FileManager.default.fileExists(atPath: target)
    }

    static func from(url: URL) -> Pin {
        if url.isFileURL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let isApp = url.pathExtension == "app"
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return Pin(kind: isApp ? .app : (isDir.boolValue ? .folder : .file), target: url.path, title: name)
        }
        return Pin(kind: .url, target: url.absoluteString, title: url.host ?? url.absoluteString)
    }

    static var defaults: [Pin] {
        let candidates = [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/finder.app",
            "/Applications/OpenThock.app",
            "/Applications/iTerm.app",
            "/Applications/Visual Studio Code.app",
            "/Applications/Google Chrome.app",
            "/Applications/Antigravity.app",
            "/Applications/Safari.app",
        ]
        var pins = candidates.filter { FileManager.default.fileExists(atPath: $0) }
            .map { Pin.from(url: URL(fileURLWithPath: $0)) }
        let downloads = Paths.home.appendingPathComponent("Downloads")
        if FileManager.default.fileExists(atPath: downloads.path) { pins.append(Pin.from(url: downloads)) }
        return pins
    }
}

// MARK: - Shortcuts

/// A recorded global shortcut (Carbon key code + Carbon modifier mask).
/// Optional second key makes it a two-step shortcut, e.g. ⌃N then O.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32
    var display: String
    var secondKey: UInt32? = nil
}

// MARK: - Option enums

enum OpenTrigger: String, CaseIterable, Codable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var title: String { self == .hover ? "Hover" : "Click" }
}

enum DisplayChoice: String, CaseIterable, Codable, Identifiable {
    case notched, main, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notched: "Built-in display (with notch)"
        case .main: "Main display"
        case .all: "All displays"
        }
    }
}

enum PanelSize: String, CaseIterable, Codable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var width: CGFloat { switch self { case .compact: 620; case .regular: 700; case .large: 800 } }
    var contentHeight: CGFloat { switch self { case .compact: 206; case .regular: 232; case .large: 276 } }
}

enum NotchTheme: String, CaseIterable, Codable, Identifiable {
    case midnight, glass, neon, aurora
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case coral, blue, violet, mint, pink, amber, mono, artwork
    var id: String { rawValue }
    var title: String { self == .artwork ? "From album art" : rawValue.capitalized }
    var base: Color {
        switch self {
        case .coral: .claude
        case .blue: Color(hex: 0x4F8BFF)
        case .violet: Color(hex: 0x9D7BFF)
        case .mint: Color(hex: 0x3DD6B0)
        case .pink: Color(hex: 0xFF6FB1)
        case .amber: Color(hex: 0xFFB547)
        case .mono: Color(white: 0.92)
        case .artwork: .claude
        }
    }
}

enum HUDMode: String, CaseIterable, Codable, Identifiable {
    case off, observe, replace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .observe: "Show alongside system HUD"
        case .replace: "Replace system HUD (needs Accessibility)"
        }
    }
}

enum HotKeyPreset: String, CaseIterable, Codable, Identifiable {
    case off, ctrlOptN, cmdOptN, ctrlOptSpace, cmdShiftSpace, ctrlCmdN
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "None"
        case .ctrlOptN: "⌃⌥N"
        case .cmdOptN: "⌥⌘N"
        case .ctrlOptSpace: "⌃⌥Space"
        case .cmdShiftSpace: "⇧⌘Space"
        case .ctrlCmdN: "⌃⌘N"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
}

// MARK: - Settings store

@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let d = UserDefaults.standard

    private static func get<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
    private static func getEnum<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        (UserDefaults.standard.string(forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
    }
    private static func getJSON<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return v
    }
    private func setJSON<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    // Behaviour
    var openTrigger: OpenTrigger = AppSettings.getEnum("openTrigger", .hover) { didSet { d.set(openTrigger.rawValue, forKey: "openTrigger") } }
    var hoverDelay: Double = AppSettings.get("hoverDelay", 0.12) { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    var closeDelay: Double = AppSettings.get("closeDelay", 0.35) { didSet { d.set(closeDelay, forKey: "closeDelay") } }
    var haptics: Bool = AppSettings.get("haptics", true) { didSet { d.set(haptics, forKey: "haptics") } }
    var scrollToOpen: Bool = AppSettings.get("scrollToOpen", true) { didSet { d.set(scrollToOpen, forKey: "scrollToOpen") } }
    var hideInFullscreen: Bool = AppSettings.get("hideInFullscreen", true) { didSet { d.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    var displayChoice: DisplayChoice = AppSettings.getEnum("displayChoice", .notched) { didSet { d.set(displayChoice.rawValue, forKey: "displayChoice"); NotificationCenter.default.post(name: .notchLayoutChanged, object: nil) } }
    var showMenuBarIcon: Bool = AppSettings.get("showMenuBarIcon", true) { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); NotificationCenter.default.post(name: .menuBarIconChanged, object: nil) } }
    var hotKey: HotKeyPreset = AppSettings.getEnum("hotKey", .ctrlOptN) { didSet { d.set(hotKey.rawValue, forKey: "hotKey"); HotKeyCenter.shared.apply(hotKey) } }
    var toggleCombo: KeyCombo? = AppSettings.getJSON("toggleCombo", Optional<KeyCombo>.none) {
        didSet { if let c = toggleCombo { setJSON(c, "toggleCombo") } else { d.removeObject(forKey: "toggleCombo") }; HotKeyCenter.shared.apply(hotKey) }
    }
    var jotCombo: KeyCombo? = AppSettings.getJSON("jotCombo", Optional<KeyCombo>.none) {
        didSet { if let c = jotCombo { setJSON(c, "jotCombo") } else { d.removeObject(forKey: "jotCombo") }; HotKeyCenter.shared.applyQuickJot(quickJotHotKey) }
    }
    var hoverSwitchTabs: Bool = AppSettings.get("hoverSwitchTabs", true) { didSet { d.set(hoverSwitchTabs, forKey: "hoverSwitchTabs") } }
    var quickJotHotKey: Bool = AppSettings.get("quickJotHotKey", true) { didSet { d.set(quickJotHotKey, forKey: "quickJotHotKey"); HotKeyCenter.shared.applyQuickJot(quickJotHotKey) } }
    var rememberLastTool: Bool = AppSettings.get("rememberLastTool", true) { didSet { d.set(rememberLastTool, forKey: "rememberLastTool") } }
    var defaultTool: ToolKind = AppSettings.getEnum("defaultTool", .home) { didSet { d.set(defaultTool.rawValue, forKey: "defaultTool") } }
    var lastTool: ToolKind = AppSettings.getEnum("lastTool", .home) { didSet { d.set(lastTool.rawValue, forKey: "lastTool") } }
    var playSounds: Bool = AppSettings.get("playSounds", true) { didSet { d.set(playSounds, forKey: "playSounds") } }

    // Appearance
    var theme: NotchTheme = AppSettings.getEnum("theme", .midnight) { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var accent: AccentChoice = AppSettings.getEnum("accent", .coral) { didSet { d.set(accent.rawValue, forKey: "accent") } }
    var panelSize: PanelSize = AppSettings.getEnum("panelSize", .regular) { didSet { d.set(panelSize.rawValue, forKey: "panelSize"); NotificationCenter.default.post(name: .notchLayoutChanged, object: nil) } }
    var showHoverGlow: Bool = AppSettings.get("showHoverGlow", true) { didSet { d.set(showHoverGlow, forKey: "showHoverGlow") } }
    var simulatedNotchWidth: Double = AppSettings.get("simulatedNotchWidth", 190) { didSet { d.set(simulatedNotchWidth, forKey: "simulatedNotchWidth"); NotificationCenter.default.post(name: .notchLayoutChanged, object: nil) } }

    // Tools
    var toolOrder: [ToolKind] = AppSettings.getJSON("toolOrder", ToolKind.allCases) { didSet { setJSON(toolOrder, "toolOrder") } }
    var enabledTools: Set<ToolKind> = Set(AppSettings.getJSON("enabledTools", ToolKind.defaultEnabled)) { didSet { setJSON(Array(enabledTools), "enabledTools") } }

    /// Turns on tools added in later versions once, so they appear for existing users.
    func migrateNewTools() {
        let key = "migratedTools.v2"
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        enabledTools.insert(.convert)
        if !toolOrder.contains(.convert) {
            var o = toolOrder
            o.insert(.convert, at: (o.firstIndex(of: .shelf).map { $0 + 1 }) ?? o.count)
            toolOrder = o
        }
    }

    /// v3: Notes takes Calendar's slot, System takes Now Playing's slot (Calendar hidden).
    func migrateLayoutV3() {
        let key = "migratedTools.v3"
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        toolOrder = ToolKind.allCases
        enabledTools.remove(.calendar)
        enabledTools.insert(.notes)
        enabledTools.insert(.stats)
    }

    var visibleTools: [ToolKind] {
        // Keep any tool that was added in a later version at the end of the order.
        let order = toolOrder + ToolKind.allCases.filter { !toolOrder.contains($0) }
        let list = order.filter { enabledTools.contains($0) }
        return list.isEmpty ? [.home] : list
    }

    // Live activities (closed notch)
    var liveMedia: Bool = AppSettings.get("liveMedia", true) { didSet { d.set(liveMedia, forKey: "liveMedia") } }
    /// Show "working" in the closed notch too. Off by default: only "needs you" shows, plus finish banners.
    var liveAIWorking: Bool = AppSettings.get("liveAIWorking", false) { didSet { d.set(liveAIWorking, forKey: "liveAIWorking") } }
    var liveAI: Bool = AppSettings.get("liveAI", true) { didSet { d.set(liveAI, forKey: "liveAI") } }
    var liveTimer: Bool = AppSettings.get("liveTimer", true) { didSet { d.set(liveTimer, forKey: "liveTimer") } }
    var liveCharging: Bool = AppSettings.get("liveCharging", true) { didSet { d.set(liveCharging, forKey: "liveCharging") } }
    var alwaysShowUsage: Bool = AppSettings.get("alwaysShowUsage", false) { didSet { d.set(alwaysShowUsage, forKey: "alwaysShowUsage") } }
    var exclusivePlayback: Bool = AppSettings.get("exclusivePlayback", true) { didSet { d.set(exclusivePlayback, forKey: "exclusivePlayback") } }
    var peekSongChanges: Bool = AppSettings.get("peekSongChanges", true) { didSet { d.set(peekSongChanges, forKey: "peekSongChanges") } }
    var hudMode: HUDMode = AppSettings.getEnum("hudMode", .off) { didSet { d.set(hudMode.rawValue, forKey: "hudMode"); HUDService.shared.apply(hudMode) } }

    // AI usage
    var claudeEnabled: Bool = AppSettings.get("claudeEnabled", true) { didSet { d.set(claudeEnabled, forKey: "claudeEnabled") } }
    var codexEnabled: Bool = AppSettings.get("codexEnabled", true) { didSet { d.set(codexEnabled, forKey: "codexEnabled") } }
    var claudeLimitsEnabled: Bool = AppSettings.get("claudeLimitsEnabled", true) { didSet { d.set(claudeLimitsEnabled, forKey: "claudeLimitsEnabled") } }
    var usageRefreshMinutes: Double = AppSettings.get("usageRefreshMinutes", 3) { didSet { d.set(usageRefreshMinutes, forKey: "usageRefreshMinutes") } }
    var notifyAgentFinished: Bool = AppSettings.get("notifyAgentFinished", true) { didSet { d.set(notifyAgentFinished, forKey: "notifyAgentFinished") } }
    var notifyAgentWaiting: Bool = AppSettings.get("notifyAgentWaiting", true) { didSet { d.set(notifyAgentWaiting, forKey: "notifyAgentWaiting") } }
    var usageAlertThreshold: Double = AppSettings.get("usageAlertThreshold", 80) { didSet { d.set(usageAlertThreshold, forKey: "usageAlertThreshold") } }
    var historyDays: Int = AppSettings.get("historyDays", 84) { didSet { d.set(historyDays, forKey: "historyDays") } }

    // Apps
    var pins: [Pin] = AppSettings.getJSON("pins", Pin.defaults) { didSet { setJSON(pins, "pins") } }
    var showRunningApps: Bool = AppSettings.get("showRunningApps", true) { didSet { d.set(showRunningApps, forKey: "showRunningApps") } }

    // Clipboard & shelf
    var clipboardEnabled: Bool = AppSettings.get("clipboardEnabled", true) { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    var clipboardRetentionDays: Int = AppSettings.get("clipboardRetentionDays", 3) { didSet { d.set(clipboardRetentionDays, forKey: "clipboardRetentionDays"); ClipboardService.shared.purgeOld() } }
    var resourceAlerts: Bool = AppSettings.get("resourceAlerts", true) { didSet { d.set(resourceAlerts, forKey: "resourceAlerts") } }
    var clipboardLimit: Int = AppSettings.get("clipboardLimit", 200) { didSet { d.set(clipboardLimit, forKey: "clipboardLimit") } }
    var clipboardIgnoredApps: [String] = AppSettings.get("clipboardIgnoredApps", ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess"]) { didSet { d.set(clipboardIgnoredApps, forKey: "clipboardIgnoredApps") } }
    var shelfCopyFiles: Bool = AppSettings.get("shelfCopyFiles", false) { didSet { d.set(shelfCopyFiles, forKey: "shelfCopyFiles") } }
    var shelfRemoveAfterDrag: Bool = AppSettings.get("shelfRemoveAfterDrag", false) { didSet { d.set(shelfRemoveAfterDrag, forKey: "shelfRemoveAfterDrag") } }

    // Timers
    var pomodoroFocus: Double = AppSettings.get("pomodoroFocus", 25) { didSet { d.set(pomodoroFocus, forKey: "pomodoroFocus") } }
    var pomodoroBreak: Double = AppSettings.get("pomodoroBreak", 5) { didSet { d.set(pomodoroBreak, forKey: "pomodoroBreak") } }
    var pomodoroLongBreak: Double = AppSettings.get("pomodoroLongBreak", 15) { didSet { d.set(pomodoroLongBreak, forKey: "pomodoroLongBreak") } }
    var hydrationReminder: Bool = AppSettings.get("hydrationReminder", false) { didSet { d.set(hydrationReminder, forKey: "hydrationReminder"); TimerEngine.shared.rescheduleHydration() } }
    var hydrationMinutes: Double = AppSettings.get("hydrationMinutes", 45) { didSet { d.set(hydrationMinutes, forKey: "hydrationMinutes"); TimerEngine.shared.rescheduleHydration() } }

    // Weather
    var weatherUseLocation: Bool = AppSettings.get("weatherUseLocation", true) { didSet { d.set(weatherUseLocation, forKey: "weatherUseLocation") } }
    var weatherCity: String = AppSettings.get("weatherCity", "") { didSet { d.set(weatherCity, forKey: "weatherCity") } }
    var temperatureUnit: TemperatureUnit = AppSettings.getEnum("temperatureUnit", Locale.current.measurementSystem == .us ? .fahrenheit : .celsius) { didSet { d.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }

    // Ticker
    var tickerText: String = AppSettings.get("tickerText", "") { didSet { d.set(tickerText, forKey: "tickerText") } }
    var tickerEnabled: Bool = AppSettings.get("tickerEnabled", false) { didSet { d.set(tickerEnabled, forKey: "tickerEnabled") } }

    // Links
    var bookmarks: [Pin] = AppSettings.getJSON("bookmarks", [
        Pin(kind: .url, target: "https://claude.ai", title: "Claude"),
        Pin(kind: .url, target: "https://chatgpt.com/codex", title: "Codex"),
        Pin(kind: .url, target: "https://github.com", title: "GitHub"),
    ]) { didSet { setJSON(bookmarks, "bookmarks") } }

    func resetAll() {
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
    }
}

extension Notification.Name {
    static let notchLayoutChanged = Notification.Name("mynotch.layoutChanged")
    static let menuBarIconChanged = Notification.Name("mynotch.menuBarIconChanged")
    static let openSettings = Notification.Name("mynotch.openSettings")
}
