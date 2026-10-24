import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: NotchManager!
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let s = AppSettings.shared
        s.migrateNewTools()
        s.migrateLayoutV3()
        installMainMenu()
        manager = NotchManager()

        // Services
        AIUsageCenter.shared.start()
        NowPlayingService.shared.start()
        ClipboardService.shared.start()
        CalendarService.shared.start()
        SystemStats.shared.start()
        ScreenTime.shared.start()
        TimerEngine.shared.start()
        HUDService.shared.apply(s.hudMode)

        manager.start()
        HotKeyCenter.shared.apply(s.hotKey)
        HotKeyCenter.shared.onTrigger = { [weak self] in self?.manager.toggle() }
        HotKeyCenter.shared.applyQuickJot(s.quickJotHotKey)
        HotKeyCenter.shared.onQuickJot = { [weak self] in self?.manager.quickJot() }

        statusItem = StatusItemController()
        statusItem?.setVisible(s.showMenuBarIcon)
        NotificationCenter.default.addObserver(forName: .menuBarIconChanged, object: nil, queue: .main) { [weak self] _ in
            self?.statusItem?.setVisible(AppSettings.shared.showMenuBarIcon)
        }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PeekCenter.shared.post(Peek(symbol: "sparkles", tint: .claude, title: "MyNotch is ready",
                                            subtitle: "Hover the notch · ⌃⌥N toggles · scroll down to open", tool: .home, duration: 6))
            }
        }
    }

    /// Agent apps have no visible menu bar, but ⌘C/⌘V/⌘X/⌘A/⌘Z are routed through the main
    /// menu's key equivalents — without an Edit menu they silently do nothing in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit MyNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingService.shared.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { URLRouter.handle($0, settings: { [weak self] in self?.showSettings() }) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        manager.open(tool: nil)
        return false
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "MyNotch Settings"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsRootView())
        w.minSize = NSSize(width: 680, height: 460)
        w.center()
        w.setFrameAutosaveName("MyNotchSettings")
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }
}

// MARK: - URL scheme  (mynotch://…)

enum URLRouter {
    /// mynotch://open?tool=ai           – open the notch on a tool
    /// mynotch://toggle                  – toggle the notch
    /// mynotch://task?state=done&title=Build&seconds=134   – task alerts from scripts / CI / hooks
    /// mynotch://peek?title=Hi&subtitle=There&symbol=star.fill
    /// mynotch://settings
    static func handle(_ url: URL, settings: () -> Void) {
        guard url.scheme == "mynotch" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        switch url.host ?? "" {
        case "open":
            NotchManager.shared?.open(tool: q("tool").flatMap(ToolKind.init(rawValue:)), pinned: q("pin") == "1")
        case "toggle":
            NotchManager.shared?.toggle(tool: q("tool").flatMap(ToolKind.init(rawValue:)))
        case "close":
            NotchManager.shared?.closeAll()
        case "settings":
            settings()
        case "task":
            let state = q("state") ?? "done"
            let title = q("title") ?? "Task"
            let secs = q("seconds").flatMap(Double.init)
            let (symbol, tint, word): (String, Color, String) = {
                switch state {
                case "failed", "error": return ("xmark.octagon.fill", .red, "failed")
                case "waiting": return ("hand.raised.fill", .yellow, "needs you")
                case "started", "running": return ("hourglass", .blue, "started")
                default: return ("checkmark.circle.fill", .green, "done")
                }
            }()
            PeekCenter.shared.post(Peek(symbol: symbol, tint: tint, title: "\(title) \(word)",
                                        subtitle: q("subtitle") ?? secs.map { "Took \(Fmt.duration($0))" } ?? q("source"),
                                        duration: 5, style: state == "failed" ? .error : .success,
                                        sound: NSSound.Name(state == "failed" ? "Basso" : "Glass"), short: "\(title) \(word)"))
        case "convert":
            // mynotch://convert?file=/a.png&file=/b.heic&to=pdf&run=1
            let files = items.filter { $0.name == "file" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
            let store = ConverterStore.shared
            if let to = q("to").flatMap(ConvertFormat.init(rawValue:)) { store.format = to }
            if let combine = q("combine") { store.combinePDF = combine == "1" }
            if !files.isEmpty { store.inputs = []; store.result = nil }
            store.add(files)
            NotchManager.shared?.open(tool: .convert)
            if q("run") == "1" { store.convert() }
        case "peek":
            PeekCenter.shared.post(Peek(symbol: q("symbol") ?? "bell.fill", tint: Theme.accent, title: q("title") ?? "Hello",
                                        subtitle: q("subtitle"), duration: Double(q("duration") ?? "") ?? 4))
        case "ticker":
            AppSettings.shared.tickerText = q("text") ?? ""
            AppSettings.shared.tickerEnabled = !(q("text") ?? "").isEmpty
        default:
            NotchManager.shared?.toggle()
        }
    }
}

// MARK: - Menu bar item

final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            i.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "MyNotch")
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        } else if !visible, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ai = AIUsageCenter.shared
        func info(_ title: String) { let m = NSMenuItem(title: title, action: nil, keyEquivalent: ""); m.isEnabled = false; menu.addItem(m) }
        if let s = ai.claude.limits?.session {
            info("Claude  ·  session \(Fmt.percent(s.percent)) (resets \(Fmt.reset(s.resetsAt)))")
            if let w = ai.claude.limits?.weekly { info("               weekly \(Fmt.percent(w.percent)) (resets \(Fmt.reset(w.resetsAt)))") }
        } else if let e = ai.claude.limitsError { info("Claude  ·  \(e)") }
        if let p = ai.codex.limits?.primary { info("Codex   ·  \(p.label.lowercased()) \(Fmt.percent(p.percent)) (resets \(Fmt.reset(p.resetsAt)))") }
        let busy = ai.claude.sessions.filter { $0.status != .idle }
        for s in busy.prefix(4) { info("  \(s.status == .waiting ? "✋" : "✳︎") \(s.name) — \(s.status == .waiting ? "needs you" : "working")") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Notch", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MyNotch", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openNotch() { NotchManager.shared?.open(tool: nil) }
    @objc private func refresh() { AIUsageCenter.shared.refresh() }
    @objc private func settings() { NotificationCenter.default.post(name: .openSettings, object: nil) }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Global hotkeys (Carbon — no Accessibility permission needed)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var onTrigger: (() -> Void)?        // toggle notch
    var onQuickJot: (() -> Void)?       // quick thought
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var combos: [UInt32: KeyCombo] = [:]     // action id (1 toggle, 2 jot) → combo
    private var armed: UInt32?                         // waiting for the second key of this action
    private var disarm: DispatchWorkItem?

    // Hotkey ids: 1/2 = first step of toggle/jot, 101/102 (+ 201/202 with modifiers still held) = second step.
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.pressed(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func pressed(_ id: UInt32) {
        let action = id % 100
        if id >= 100 {                      // second step completed
            guard armed == action else { return }
            endChord()
            fire(action)
            return
        }
        if let second = combos[action]?.secondKey, let c = combos[action] {
            // First step: listen for the second key for 1.2 s (registered only now, so it never steals typing).
            endChord()
            armed = action
            register(id: 100 + action, key: Int(second), mods: 0)
            if c.mods != 0 { register(id: 200 + action, key: Int(second), mods: Int(c.mods)) }
            let w = DispatchWorkItem { [weak self] in self?.endChord() }
            disarm = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        } else {
            fire(action)
        }
    }

    private func endChord() {
        disarm?.cancel()
        if let a = armed { register(id: 100 + a, key: -1, mods: 0); register(id: 200 + a, key: -1, mods: 0) }
        armed = nil
    }

    private func fire(_ action: UInt32) {
        if action == 2 { onQuickJot?() } else { onTrigger?() }
    }

    private func register(id: UInt32, key: Int, mods: Int) {
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        guard key >= 0 else { return }
        installHandler()
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x4D4E4348), id: id), GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
    }

    private func set(action: UInt32, combo: KeyCombo?) {
        combos[action] = combo
        register(id: action, key: combo.map { Int($0.keyCode) } ?? -1, mods: Int(combo?.mods ?? 0))
    }

    func apply(_ preset: HotKeyPreset) {
        if let c = AppSettings.shared.toggleCombo { set(action: 1, combo: c); return }
        let def: KeyCombo? = {
            switch preset {
            case .ctrlOptN: return KeyCombo(keyCode: UInt32(kVK_ANSI_N), mods: UInt32(controlKey | optionKey), display: "")
            case .cmdOptN: return KeyCombo(keyCode: UInt32(kVK_ANSI_N), mods: UInt32(cmdKey | optionKey), display: "")
            case .ctrlOptSpace: return KeyCombo(keyCode: UInt32(kVK_Space), mods: UInt32(controlKey | optionKey), display: "")
            case .cmdShiftSpace: return KeyCombo(keyCode: UInt32(kVK_Space), mods: UInt32(cmdKey | shiftKey), display: "")
            case .ctrlCmdN: return KeyCombo(keyCode: UInt32(kVK_ANSI_N), mods: UInt32(controlKey | cmdKey), display: "")
            case .off: return nil
            }
        }()
        set(action: 1, combo: def)
    }

    func applyQuickJot(_ on: Bool) {
        guard on else { set(action: 2, combo: nil); return }
        set(action: 2, combo: AppSettings.shared.jotCombo
            ?? KeyCombo(keyCode: UInt32(kVK_ANSI_J), mods: UInt32(controlKey | optionKey), display: "⌃⌥J"))
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("MyNotch: launch at login failed: \(error)") }
    }
}
