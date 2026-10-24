import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppsView: View {
    let vm: NotchViewModel
    private var settings: AppSettings { .shared }
    @State private var running: [NSRunningApplication] = []
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Pinned", trailing: "Drop files on an app to open them with it · drop apps here to pin")
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(66), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                    ForEach(settings.pins.filter(\.exists)) { pin in
                        PinIcon(pin: pin, size: 40, showName: true) { vm.close() }
                    }
                    AddPinButton()
                }
            }
            .frame(maxHeight: settings.showRunningApps ? 136 : .infinity)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(dropTargeted ? Theme.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            if !settings.pins.contains(where: { $0.target == url.path }) { settings.pins.append(Pin.from(url: url)) }
                        }
                    }
                }
                return true
            }

            if settings.showRunningApps {
                SectionLabel(text: "Running")
                if running.isEmpty {
                    Text("Every running app is already pinned.").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).frame(height: 38)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(running, id: \.processIdentifier) { app in
                                RunningAppIcon(app: app) { vm.close() }
                            }
                        }
                    }
                    .frame(height: 38)
                }
            }
        }
        .onAppear(perform: refreshRunning)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunning() }
    }

    private var columns: Int { max(4, Int((settings.panelSize.width - 40) / 72)) }

    private func refreshRunning() {
        let pinned = Set(settings.pins.compactMap(\.bundleID))
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !pinned.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

/// An app / folder / file / URL you can click, drop files onto, and manage via right-click.
struct PinIcon: View {
    var pin: Pin
    var size: CGFloat
    var showName: Bool
    var onOpen: () -> Void
    @State private var hover = false
    @State private var targeted = false
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 2) {
            icon
                .frame(width: size, height: size)
                .scaleEffect(hover ? 1.1 : 1)
                .shadow(color: .black.opacity(0.4), radius: hover ? 6 : 0, y: 2)
            Circle().fill(Color.white.opacity(isRunning ? 0.85 : 0)).frame(width: 3.5, height: 3.5)
            if showName {
                Text(pin.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1).foregroundStyle(hover ? .white : Theme.secondary)
            }
        }
        .frame(width: showName ? 66 : size + 6, height: showName ? size + 26 : size + 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(targeted ? Theme.accent.opacity(0.25) : (hover && showName ? Color.white.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
        .onTapGesture { open() }
        .help(pin.title)
        .onAppear(perform: refresh)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard pin.kind == .app || pin.kind == .folder else { return false }
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { openWith(urls) }
            return true
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var icon: some View {
        if pin.kind == .url {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(LinearGradient(colors: [Color(hex: 0x4F8BFF), Color(hex: 0x8F5BFF)], startPoint: .top, endPoint: .bottom))
                Text(String(pin.title.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            }
        } else {
            FileIcon(path: pin.target, size: size)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { open() }
        if pin.kind == .app, let id = pin.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            Button("Hide") { app.hide() }
            Button("Quit") { app.terminate() }
        }
        if pin.kind != .url {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pin.target)]) }
        }
        Divider()
        Button("Move Left") { move(-1) }
        Button("Move Right") { move(1) }
        Button("Unpin", role: .destructive) { AppSettings.shared.pins.removeAll { $0.id == pin.id } }
    }

    private func refresh() {
        if let id = pin.bundleID { isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    }

    private func open() {
        guard let url = pin.url else { return }
        Haptics.tap()
        if pin.kind == .app {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
        onOpen()
    }

    private func openWith(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if pin.kind == .app, let app = pin.url {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else if pin.kind == .folder {
            for u in urls { try? FileManager.default.moveItem(at: u, to: URL(fileURLWithPath: pin.target).appendingPathComponent(u.lastPathComponent)) }
        }
        onOpen()
    }

    private func move(_ delta: Int) {
        var pins = AppSettings.shared.pins
        guard let i = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        let j = min(max(0, i + delta), pins.count - 1)
        pins.swapAt(i, j)
        AppSettings.shared.pins = pins
    }
}

private struct RunningAppIcon: View {
    var app: NSRunningApplication
    var onOpen: () -> Void
    @State private var hover = false
    var body: some View {
        Group {
            if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app") }
        }
        .frame(width: 30, height: 30)
        .scaleEffect(hover ? 1.12 : 1)
        .opacity(app.isHidden ? 0.5 : 1)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
        .onTapGesture { app.unhide(); app.activate(); onOpen() }
        .help(app.localizedName ?? "")
        .contextMenu {
            Button("Activate") { app.activate() }
            Button(app.isHidden ? "Unhide" : "Hide") { app.isHidden ? app.unhide() : app.hide() }
            if let url = app.bundleURL {
                Button("Pin to Notch") { AppSettings.shared.pins.append(Pin.from(url: url)) }
            }
            Divider()
            Button("Quit", role: .destructive) { app.terminate() }
        }
    }
}

private struct AddPinButton: View {
    @State private var hover = false
    var body: some View {
        Button(action: showMenu) {
            VStack(spacing: 2) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hover ? .white : Theme.secondary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(hover ? 0.45 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Color.clear.frame(width: 3.5, height: 3.5)
                Text("Add").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .frame(width: 66, height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        let handler = MenuHandler.shared
        menu.addItem(handler.item("Choose App, File or Folder…") { choose() })
        let running = NSMenuItem(title: "Pin a Running App", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for app in NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular }) {
            let item = handler.item(app.localizedName ?? "App") {
                if let url = app.bundleURL, !AppSettings.shared.pins.contains(where: { $0.target == url.path }) {
                    AppSettings.shared.pins.append(Pin.from(url: url))
                }
            }
            if let icon = app.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); item.image = icon }
            sub.addItem(item)
        }
        running.submenu = sub
        menu.addItem(running)
        menu.addItem(handler.item("Add Website…") { addURL() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func choose() {
        NotchManager.shared?.presentDialog(reopen: .apps) { chooseNow() }
    }

    private func chooseNow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Pin"
        if panel.runModal() == .OK {
            for url in panel.urls where !AppSettings.shared.pins.contains(where: { $0.target == url.path }) {
                AppSettings.shared.pins.append(Pin.from(url: url))
            }
        }
    }

    private func addURL() {
        NotchManager.shared?.presentDialog(reopen: .apps) { addURLNow() }
    }

    private func addURLNow() {
        let alert = NSAlert()
        alert.messageText = "Pin a website"
        alert.informativeText = "Enter a URL (e.g. github.com)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        // Pre-fill with a copied link, if any.
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.range(of: #"^(https?://)?[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Pin")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            var s = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return }
            if !s.contains("://") { s = "https://" + s }
            if let url = URL(string: s) { AppSettings.shared.pins.append(Pin.from(url: url)) }
        }
    }
}

/// Bridges NSMenuItem target/action to closures.
final class MenuHandler: NSObject {
    static let shared = MenuHandler()
    private var actions: [Int: () -> Void] = [:]
    private var next = 0
    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        next += 1
        actions[next] = action
        let i = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        i.target = self
        i.tag = next
        return i
    }
    @objc private func run(_ sender: NSMenuItem) {
        let a = actions[sender.tag]
        DispatchQueue.main.async { a?() }
    }
}
