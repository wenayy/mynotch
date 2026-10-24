import AppKit
import SwiftUI

/// One borderless panel per display, hosting the SwiftUI notch.
final class NotchWindowController {
    let vm: NotchViewModel
    let panel: NotchPanel
    private var hosting: NSHostingView<NotchRootView>

    init(screen: NSScreen, mouse: MouseMonitor) {
        let geo = NotchGeometry.of(screen)
        vm = NotchViewModel(geometry: geo)
        vm.mouse = mouse
        panel = NotchPanel(frame: NotchWindowController.frame(for: geo))
        hosting = NSHostingView(rootView: NotchRootView(vm: vm))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        vm.panel = panel
        panel.orderFrontRegardless()
    }

    static func frame(for geo: NotchGeometry) -> NSRect {
        let size = AppSettings.shared.panelSize
        let w = size.width + 80
        let h = max(geo.notchSize.height, 30) + size.contentHeight + PreviewCenter.extraHeight + 50
        return NSRect(x: geo.screenFrame.midX - w / 2, y: geo.screenFrame.maxY - h, width: w, height: h)
    }

    func update(screen: NSScreen) {
        let geo = NotchGeometry.of(screen)
        vm.geometry = geo
        panel.setFrame(NotchWindowController.frame(for: geo), display: true)
    }

    func teardown() {
        panel.orderOut(nil)
        panel.close()
    }
}

final class NotchManager {
    static private(set) var shared: NotchManager!

    private(set) var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    let mouse = MouseMonitor()
    private var keyMonitor: Any?

    init() { NotchManager.shared = self }

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NotificationCenter.default.addObserver(forName: .notchLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        mouse.handler = { [weak self] kind, point in
            self?.controllers.values.forEach { $0.vm.handle(kind, at: point) }
        }
        mouse.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) == true ? nil : e
        }
        FullscreenWatcher.shared.onChange = { [weak self] ids in
            self?.controllers.forEach { id, c in
                let hide = ids.contains(id)
                if c.vm.hidden != hide {
                    if hide { c.vm.close() }
                    withAnimation(.easeInOut(duration: 0.2)) { c.vm.hidden = hide }
                    c.vm.updateMouseCapture()
                }
            }
        }
        FullscreenWatcher.shared.start()
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch AppSettings.shared.displayChoice {
        case .all:
            return screens
        case .main:
            return [NSScreen.main ?? screens.first].compactMap { $0 }
        case .notched:
            let notched = screens.filter { $0.safeAreaInsets.top > 0 }
            return notched.isEmpty ? [NSScreen.main ?? screens.first].compactMap { $0 } : notched
        }
    }

    func rebuild() {
        var next: [CGDirectDisplayID: NotchWindowController] = [:]
        for screen in targetScreens() {
            let id = NotchGeometry.of(screen).displayID
            if let existing = controllers[id] {
                existing.update(screen: screen)
                next[id] = existing
            } else {
                next[id] = NotchWindowController(screen: screen, mouse: mouse)
            }
        }
        for (id, c) in controllers where next[id] == nil { c.teardown() }
        controllers = next
    }

    /// The notch nearest to the pointer (for hotkeys, URL commands, menu items).
    var activeVM: NotchViewModel? {
        let p = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.vm.geometry.screenFrame.contains(p) }) { return c.vm }
        return controllers.values.first(where: { $0.vm.geometry.hasNotch })?.vm ?? controllers.values.first?.vm
    }

    func toggle(tool: ToolKind? = nil) {
        guard let vm = activeVM else { return }
        if vm.isOpen, tool == nil || tool == vm.currentTool { vm.close() } else { vm.open(tool: tool) }
        if vm.isOpen {
            vm.pinned = false
            vm.holdOpen = true       // keyboard session: don't auto-close when the pointer is elsewhere
            vm.takeKeyboard()
        }
    }

    func open(tool: ToolKind?, pinned: Bool = false) {
        guard let vm = activeVM else { return }
        vm.open(tool: tool)
        if pinned { vm.pinned = true }
    }

    func closeAll() { controllers.values.forEach { $0.vm.close() } }

    /// Closes the notch, lets its animation finish, then shows a system dialog.
    /// (A modal dialog freezes the run loop; closing first avoids a stuck black notch over the dialog.)
    /// When the dialog ends, the notch reopens on `reopen` so the user lands back where they were.
    func presentDialog(reopen tool: ToolKind?, _ dialog: @escaping () -> Void) {
        closeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.activate(ignoringOtherApps: true)
            dialog()
            if let tool { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.open(tool: tool) } }
        }
    }

    /// Keyboard navigation while the notch has focus:
    /// ←/→ switch tools · ↓ or Return go into the tool · Esc leaves a text field, then closes.
    /// On Notes, just start typing — the text lands in the quick-thought box.
    private func handleKey(_ e: NSEvent) -> Bool {
        guard let vm = controllers.values.first(where: { $0.vm.isOpen && $0.panel.isKeyWindow })?.vm,
              let panel = vm.panel else { return false }
        let editing = panel.firstResponder is NSTextView
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if e.keyCode == 53 {                                   // Esc
            if PreviewCenter.shared.active { return false }    // preview handles its own Esc
            if editing { panel.makeFirstResponder(nil) } else { vm.close() }
            return true
        }
        guard !editing, mods.isEmpty, !PreviewCenter.shared.active else { return false }
        let tools = AppSettings.shared.visibleTools
        let i = tools.firstIndex(of: vm.currentTool) ?? 0
        switch e.keyCode {
        case 123: vm.select(tools[(i - 1 + tools.count) % tools.count]); return true   // ←
        case 124: vm.select(tools[(i + 1) % tools.count]); return true                 // →
        case 125, 36, 76:                                                              // ↓ / Return / Enter
            if vm.currentTool == .notes { NotesStore.shared.focusToken += 1; return true }
            return false
        default:
            if vm.currentTool == .notes, let c = e.characters, !c.isEmpty,
               c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) {
                NotesStore.shared.pendingTyping += c
                return true
            }
            return false
        }
    }

    /// ⌃⌥J — open Notes with the cursor in the quick-thought box, ready to type.
    func quickJot() {
        guard let vm = activeVM else { return }
        if vm.isOpen && vm.currentTool == .notes && vm.holdOpen { vm.close(); return }
        vm.open(tool: .notes)
        vm.holdOpen = true
        vm.takeKeyboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { NotesStore.shared.focusToken += 1 }
    }
}
