import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shelf

struct ShelfView: View {
    private var shelf: ShelfStore { .shared }
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Shelf", trailing: shelf.items.isEmpty ? nil : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                if !shelf.items.isEmpty {
                    PillButton(title: "AirDrop all", symbol: "airplayaudio") { shelf.airDrop(shelf.items.map(\.url)) }
                    PillButton(title: "Clear", symbol: "trash") { shelf.clear() }
                }
            }
            if shelf.items.isEmpty {
                dropHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $targeted) { shelf.accept($0) }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Theme.accent : .clear, lineWidth: 1.5))
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.tertiary)
                .symbolEffect(.bounce, value: targeted)
            Text("Drag files here — or onto the notch from anywhere").font(.system(size: 12.5, weight: .semibold))
            Text("Park files, images and text while you move between apps, then drag them out wherever you need them.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
    }
}

private struct ShelfTile: View {
    var item: ShelfItem
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) }
                    else { FileIcon(path: item.path, size: 56) }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if hover {
                    Button { ShelfStore.shared.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, Color(white: 0.25))
                    }
                    .buttonStyle(.plain).offset(x: 6, y: -6)
                }
            }
            Text(item.name).font(.system(size: 9.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 84).foregroundStyle(hover ? .white : Theme.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.white.opacity(0.07) : .clear))
        .onHover { hover = $0 }
        .onAppear { ShelfStore.shared.thumbnail(for: item, size: 144) { thumb = $0 } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onTapGesture {
            let items = ShelfStore.shared.items
            PreviewCenter.shared.show(items.map { PreviewItem(title: $0.name, kind: .file($0.url)) },
                                      at: items.firstIndex(of: item) ?? 0)
        }
        .onDrag {
            if AppSettings.shared.shelfRemoveAfterDrag {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ShelfStore.shared.remove(item) }
            }
            return fileDragProvider(item.url)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item.url as NSURL]) }
            Button("AirDrop") { ShelfStore.shared.airDrop([item.url]) }
            if ConverterStore.isSupported(item.url) {
                Button("Convert…") {
                    ConverterStore.shared.add([item.url])
                    NotchManager.shared?.activeVM?.select(.convert)
                }
            }
            Divider()
            Button("Remove from Shelf", role: .destructive) { ShelfStore.shared.remove(item) }
        }
        .help(item.path)
    }
}

// MARK: - Clipboard

enum Paster {
    /// Closes the notch, returns focus to the app you were in and presses ⌘V there.
    static func paste(_ items: [ClipItem]) {
        let target = NSWorkspace.shared.frontmostApplication
        let count = ClipboardService.shared.writeToPasteboard(items, forTerminal: ClipboardService.isTerminal(target))
        guard count > 0 else { return }
        NotchManager.shared?.closeAll()
        target?.activate()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            PeekCenter.shared.post(Peek(symbol: "doc.on.clipboard.fill", tint: .accentColor,
                                        title: "Copied \(count) item\(count == 1 ? "" : "s") — press ⌘V",
                                        subtitle: "Allow MyNotch in Accessibility to paste automatically", duration: 4, short: "Copied"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v: CGKeyCode = 9 // kVK_ANSI_V
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

struct ClipboardView: View {
    enum Filter: String, CaseIterable { case all = "All", images = "Images", text = "Text", links = "Links", files = "Files" }
    private var clip: ClipboardService { .shared }
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var grid = UserDefaults.standard.object(forKey: "clipGrid") as? Bool ?? true
    @State private var selection: [UUID] = []          // ordered: paste order = pick order
    @FocusState private var focused: Bool

    private var filtered: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = clip.items
        switch filter {
        case .all: break
        case .images: list = list.filter { $0.kind == .image }
        case .text: list = list.filter { $0.kind == .text || $0.kind == .color }
        case .links: list = list.filter { $0.kind == .link }
        case .files: list = list.filter { $0.kind == .file }
        }
        if !q.isEmpty {
            list = list.filter { $0.preview.lowercased().contains(q) || ($0.sourceName?.lowercased().contains(q) ?? false) }
        }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    private var selectedItems: [ClipItem] { selection.compactMap { id in clip.items.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 7) {
            toolbar
            if filtered.isEmpty {
                EmptyState(symbol: "doc.on.clipboard", title: query.isEmpty ? "Nothing here yet" : "No matches",
                           subtitle: query.isEmpty ? "Copy text, links, images or files and they'll collect here. Passwords from password managers are skipped." : nil)
            } else if grid {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 122, maximum: 170), spacing: 8)], spacing: 8) {
                        ForEach(filtered) { item in
                            ClipTile(item: item, selectionIndex: selection.firstIndex(of: item.id),
                                     selecting: !selection.isEmpty,
                                     onTap: { tap(item) }, onToggle: { toggle(item) }, onPreview: { preview(item) })
                        }
                    }
                    .padding(.bottom, selection.isEmpty ? 0 : 40)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { item in
                            ClipRow(item: item, selected: selection.contains(item.id), selecting: !selection.isEmpty,
                                    onTap: { tap(item) }, onToggle: { toggle(item) }, onPreview: { preview(item) })
                        }
                    }
                    .padding(.bottom, selection.isEmpty ? 0 : 40)
                }
            }
        }
        .overlay(alignment: .bottom) { if !selection.isEmpty { actionBar.transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection.isEmpty)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
            .frame(maxWidth: 200)
            ForEach(Filter.allCases, id: \.self) { f in
                Button { withAnimation(.easeInOut(duration: 0.15)) { filter = f } } label: {
                    Text(f.rawValue).font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(filter == f ? .black : .white)
                        .background(Capsule().fill(filter == f ? Theme.accent : Color.white.opacity(0.08)))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            IconButton(symbol: grid ? "list.bullet" : "square.grid.2x2", size: 10, help: grid ? "List view" : "Grid view") {
                withAnimation(.easeInOut(duration: 0.2)) { grid.toggle() }
                UserDefaults.standard.set(grid, forKey: "clipGrid")
            }
            if !AppSettings.shared.clipboardEnabled {
                IconButton(symbol: "play.fill", size: 10, active: true, help: "Resume history") { AppSettings.shared.clipboardEnabled = true }
            } else {
                IconButton(symbol: "pause.fill", size: 10, help: "Pause history") { AppSettings.shared.clipboardEnabled = false }
            }
            IconButton(symbol: "trash", size: 10, help: "Clear unpinned") { clip.clearUnpinned(); selection = [] }
        }
    }

    private var actionBar: some View {
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let n = selection.count
        return HStack(spacing: 8) {
            Text("\(n) selected").font(.system(size: 11.5, weight: .bold))
            Button("Select all") { selection = filtered.map(\.id) }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 4)
            PillButton(title: "Preview", symbol: "eye") { PreviewCenter.shared.show(selectedItems.map(previewItem)) }
            PillButton(title: "Copy", symbol: "doc.on.doc") {
                let c = clip.writeToPasteboard(selectedItems)
                PeekCenter.shared.post(Peek(symbol: "doc.on.clipboard.fill", tint: .accentColor, title: "Copied \(c) item\(c == 1 ? "" : "s")", duration: 1.6, short: "Copied"))
            }
            PillButton(title: "Paste \(n) into \(target)", symbol: "arrow.down.doc.fill", prominent: true) {
                let items = selectedItems
                selection = []
                Paster.paste(items)
            }
            IconButton(symbol: "xmark", size: 10, help: "Clear selection") { selection = [] }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(white: 0.12)).shadow(color: .black.opacity(0.6), radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }

    private var dragURLs: [URL] {
        selectedItems.flatMap { item -> [URL] in
            if item.kind == .image { return clip.exportedImageURL(for: item).map { [$0] } ?? [] }
            if item.kind == .file { return (item.files ?? []).map { URL(fileURLWithPath: $0) } }
            return []
        }
    }

    private func tap(_ item: ClipItem) {
        if !selection.isEmpty || NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            toggle(item)
        } else {
            clip.copy(item)
        }
    }

    private func toggle(_ item: ClipItem) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if let i = selection.firstIndex(of: item.id) { selection.remove(at: i) } else { selection.append(item.id) }
        }
    }

    private func preview(_ item: ClipItem) {
        // Flip through everything visible of the same family (all images, or all items).
        let list = item.kind == .image ? filtered.filter { $0.kind == .image } : filtered
        PreviewCenter.shared.show(list.map(previewItem), at: list.firstIndex(of: item) ?? 0)
    }

    private func previewItem(_ item: ClipItem) -> PreviewItem {
        switch item.kind {
        case .image:
            if let u = clip.imageURL(for: item) { return PreviewItem(title: "Image from \(item.sourceName ?? "clipboard")", kind: .image(u)) }
        case .file:
            if let f = item.files?.first { return PreviewItem(title: (f as NSString).lastPathComponent, kind: .file(URL(fileURLWithPath: f))) }
        default: break
        }
        return PreviewItem(title: item.sourceName.map { "Text from \($0)" } ?? "Text", kind: .text(item.text ?? item.preview))
    }
}

/// Big visual card for the grid view.
private struct ClipTile: View {
    var item: ClipItem
    var selectionIndex: Int?
    var selecting: Bool
    var onTap: () -> Void
    var onToggle: () -> Void
    var onPreview: () -> Void
    @State private var hover = false
    @State private var image: NSImage?
    private var clip: ClipboardService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                content
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selectionIndex != nil ? Theme.accent : (clip.lastCopiedID == item.id ? Color.green : Color.white.opacity(hover ? 0.18 : 0.06)),
                                      lineWidth: selectionIndex != nil ? 2 : 1))
                if hover || selecting || selectionIndex != nil {
                    Button(action: onToggle) {
                        ZStack {
                            Circle().fill(selectionIndex != nil ? Theme.accent : Color.black.opacity(0.55)).frame(width: 20, height: 20)
                            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.4).frame(width: 20, height: 20)
                            if let i = selectionIndex {
                                Text("\(i + 1)").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                            }
                        }
                    }
                    .buttonStyle(.plain).padding(6).help("Select (⌘-click works too)")
                }
                if hover {
                    HStack(spacing: 4) {
                        Spacer()
                        miniButton(item.pinned ? "pin.fill" : "pin") { clip.togglePin(item) }
                        miniButton("eye.fill", action: onPreview)
                    }
                    .padding(6)
                }
                if clip.lastCopiedID == item.id {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.green))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
            HStack(spacing: 4) {
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.accent) }
                Text(item.sourceName ?? kindName).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .onAppear { if item.kind == .image { DispatchQueue.global(qos: .userInitiated).async {
            let img = clip.image(for: item)
            DispatchQueue.main.async { image = img }
        } } }
        .onDrag {
            switch item.kind {
            case .image: return clip.exportedImageURL(for: item).map(fileDragProvider) ?? NSItemProvider()
            case .file: return fileDragProvider(URL(fileURLWithPath: item.files?.first ?? ""))
            default: return NSItemProvider(object: (item.text ?? "") as NSString)
            }
        }
        .contextMenu {
            Button("Copy") { clip.copy(item) }
            Button("Paste into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "app")") { Paster.paste([item]) }
            Button("Preview") { onPreview() }
            if item.kind == .image || item.kind == .file {
                Button("Convert…") {
                    if let u = item.kind == .image ? clip.imageURL(for: item) : item.files.flatMap({ $0.first }).map({ URL(fileURLWithPath: $0) }) {
                        ConverterStore.shared.add([u]); NotchManager.shared?.activeVM?.select(.convert)
                    }
                }
            }
            Button(item.pinned ? "Unpin" : "Pin") { clip.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { clip.delete(item) }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var kindName: String {
        switch item.kind { case .image: "Image"; case .file: "File"; case .link: "Link"; case .color: "Color"; case .text: "Text" }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
            } else { Color.white.opacity(0.04) }
        case .file:
            VStack(spacing: 4) {
                FileIcon(path: item.files?.first ?? "/", size: 40)
                Text(item.preview).font(.system(size: 9.5)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 6)
            }
        case .color:
            (Color(hexString: item.text ?? "") ?? .gray).overlay(Text(item.text ?? "").font(.system(size: 11, weight: .bold, design: .monospaced)).shadow(radius: 2))
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                Text(URL(string: item.text ?? "")?.host ?? "").font(.system(size: 11, weight: .bold)).lineLimit(1)
                Text(item.text ?? "").font(.system(size: 9.5)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .text:
            Text((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10.5)).lineLimit(6).foregroundStyle(.white.opacity(0.88))
                .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func miniButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(Color.black.opacity(0.6)))
        }.buttonStyle(.plain)
    }
}

private struct ClipRow: View {
    var item: ClipItem
    var selected: Bool
    var selecting: Bool
    var onTap: () -> Void
    var onToggle: () -> Void
    var onPreview: () -> Void
    @State private var hover = false
    private var clip: ClipboardService { .shared }

    var body: some View {
        HStack(spacing: 10) {
            if selecting || hover || selected {
                Button(action: onToggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                        .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
                }.buttonStyle(.plain)
            }
            leading.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 11.5, design: item.kind == .text && looksLikeCode ? .monospaced : .default))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let n = item.sourceName { Text(n) }
                    Text("·")
                    Text(item.date, style: .relative)
                    if item.kind == .text, let t = item.text { Text("· \(t.count) chars") }
                }
                .font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            if clip.lastCopiedID == item.id {
                Label("Copied", systemImage: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale))
            } else if hover || item.pinned {
                if hover { IconButton(symbol: "eye", size: 9, help: "Preview", action: onPreview) }
                IconButton(symbol: item.pinned ? "pin.fill" : "pin", size: 9, active: item.pinned, help: "Pin") { clip.togglePin(item) }
                if hover { IconButton(symbol: "xmark", size: 9, help: "Delete") { clip.delete(item) } }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.accent.opacity(0.16) : (hover ? Color.white.opacity(0.08) : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .onDrag {
            switch item.kind {
            case .file: return fileDragProvider(URL(fileURLWithPath: item.files?.first ?? ""))
            case .image: return clip.exportedImageURL(for: item).map(fileDragProvider) ?? NSItemProvider()
            default: return NSItemProvider(object: (item.text ?? "") as NSString)
            }
        }
        .contextMenu {
            Button("Copy") { clip.copy(item) }
            Button("Paste into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "app")") { Paster.paste([item]) }
            Button("Preview", action: onPreview)
            if item.kind == .link, let s = item.text, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            if item.kind == .text || item.kind == .link { Button("Add to Shelf") { ShelfStore.shared.add(text: item.text ?? "") } }
            Button(item.pinned ? "Unpin" : "Pin") { clip.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { clip.delete(item) }
        }
    }

    private var looksLikeCode: Bool {
        guard let t = item.text else { return false }
        return t.contains("{") || t.contains(";") || t.hasPrefix("$ ") || t.contains("=>") || t.contains("func ")
    }

    @ViewBuilder private var leading: some View {
        switch item.kind {
        case .image:
            if let img = clip.image(for: item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
            } else { kindIcon("photo") }
        case .file:
            FileIcon(path: item.files?.first ?? "/", size: 28)
        case .color:
            RoundedRectangle(cornerRadius: 7).fill(Color(hexString: item.text ?? "") ?? .gray).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.2)))
        case .link:
            kindIcon("link")
        case .text:
            if let id = item.sourceBundle, let icon = AppInfo.icon(forBundleID: id) {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else { kindIcon("text.alignleft") }
        }
    }

    private func kindIcon(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }
}

extension Color {
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
