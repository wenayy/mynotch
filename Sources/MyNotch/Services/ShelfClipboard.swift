import AppKit
import SwiftUI
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Shelf

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

@Observable
final class ShelfStore {
    static let shared = ShelfStore()
    var items: [ShelfItem] = []
    @ObservationIgnored private var thumbs: [String: NSImage] = [:]
    @ObservationIgnored let folder = Paths.dir("Shelf")

    init() {
        items = (Store.load([ShelfItem].self, from: "shelf.json") ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func save() { Store.save(items, to: "shelf.json") }

    func add(urls: [URL]) {
        var added = 0
        for var url in urls where url.isFileURL {
            if AppSettings.shared.shelfCopyFiles {
                let dest = uniqueURL(for: url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { url = dest }
            }
            guard !items.contains(where: { $0.path == url.path }) else { continue }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(ShelfItem(path: url.path)) }
            added += 1
        }
        if added > 0 {
            save()
            PeekCenter.shared.post(Peek(symbol: "tray.and.arrow.down.fill", tint: .accentColor,
                                        title: added == 1 ? "Added to Shelf" : "\(added) items added to Shelf",
                                        subtitle: urls.first?.lastPathComponent, tool: .shelf, duration: 2.2))
        }
    }

    func add(text: String) {
        let url = uniqueURL(for: "Snippet \(Self.stamp()).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        add(urls: [url])
    }

    func add(imageData: Data, ext: String = "png") {
        let url = uniqueURL(for: "Image \(Self.stamp()).\(ext)")
        try? imageData.write(to: url)
        add(urls: [url])
    }

    func remove(_ item: ShelfItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { $0.id == item.id } }
        if item.path.hasPrefix(folder.path) { try? FileManager.default.removeItem(atPath: item.path) }
        save()
    }

    func clear() { items.forEach(remove) }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func thumbnail(for item: ShelfItem, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let t = thumbs[item.path] { completion(t); return }
        completion(NSWorkspace.shared.icon(forFile: item.path))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                self?.thumbs[item.path] = rep.nsImage
                completion(rep.nsImage)
            }
        }
    }

    /// Accepts anything dragged in: files, images, text or links.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { self.add(urls: [url]) } }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    DispatchQueue.main.async { self.add(imageData: png) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { DispatchQueue.main.async { self.add(text: s) } }
                }
            }
        }
        return handled
    }

    private func uniqueURL(for name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }
}

// MARK: - Clipboard

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, link, image, file, color }
    var id = UUID()
    var kind: Kind
    var text: String?
    var imageFile: String?
    var files: [String]?
    var sourceBundle: String?
    var sourceName: String?
    var date = Date()
    var pinned = false
    var hash: Int

    var preview: String {
        switch kind {
        case .text, .link, .color: return text ?? ""
        case .image: return "Image"
        case .file: return (files ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }
}

@Observable
final class ClipboardService {
    static let shared = ClipboardService()
    var items: [ClipItem] = []
    var lastCopiedID: UUID?

    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ownChangeCount = -1
    @ObservationIgnored private let folder = Paths.dir("Clipboard")
    @ObservationIgnored private let saver = Debouncer(1.0)

    private static let concealed: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                                 "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    init() {
        items = Store.load([ClipItem].self, from: "clipboard.json") ?? []
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        purgeOld()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.purgeOld() }
        cleanOrphanImages()
    }

    /// Deletes unpinned items (and their image files) older than the retention setting (default 3 days).
    func purgeOld() {
        let days = AppSettings.shared.clipboardRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let old = items.filter { !$0.pinned && $0.date < cutoff }
        guard !old.isEmpty else { return }
        for i in old { if let f = i.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) } }
        let ids = Set(old.map(\.id))
        items.removeAll { ids.contains($0.id) }
        save()
        // Exported copies used for drag/paste are disposable too.
        let clips = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MyNotch/clips")
        for u in (try? FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    /// Removes image files no longer referenced by any item.
    private func cleanOrphanImages() {
        let used = Set(items.compactMap(\.imageFile))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func save() { saver.call { [items] in Store.save(items, to: "clipboard.json") } }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if pb.changeCount == ownChangeCount { return }   // our own Copy / Paste
        let s = AppSettings.shared
        guard s.clipboardEnabled else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: Self.concealed) { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, s.clipboardIgnoredApps.contains(id) { return }

        var item: ClipItem?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            item = ClipItem(kind: .file, files: paths, hash: StableHash.of(paths.joined(separator: "\n")))
        } else if let img = NSImage(pasteboard: pb), types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue),
                  pb.string(forType: .string) == nil {
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let name = UUID().uuidString + ".png"
                try? png.write(to: folder.appendingPathComponent(name))
                item = ClipItem(kind: .image, imageFile: name, hash: StableHash.of(png.prefix(4096)) ^ png.count)
            }
        } else if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLink = trimmed.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
            let isColor = trimmed.range(of: #"^#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$"#, options: .regularExpression) != nil
            item = ClipItem(kind: isLink ? .link : (isColor ? .color : .text), text: str, hash: StableHash.of(str))
        }
        guard var new = item else { return }
        new.sourceBundle = front?.bundleIdentifier
        new.sourceName = front?.localizedName
        if let existing = items.firstIndex(where: { $0.hash == new.hash && $0.kind == new.kind }) {
            new.pinned = items[existing].pinned
            items.remove(at: existing)
        }
        items.insert(new, at: 0)
        trim()
        save()
    }

    private func trim() {
        let limit = max(20, AppSettings.shared.clipboardLimit)
        var unpinned = 0
        items = items.filter { i in
            if i.pinned { return true }
            unpinned += 1
            if unpinned > limit {
                if let f = i.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
                return false
            }
            return true
        }
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let f = item.imageFile else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(f))
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link, .color: pb.setString(item.text ?? "", forType: .string)
        case .image: if let img = image(for: item) { pb.writeObjects([img]) }
        case .file: pb.writeObjects((item.files ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        ownChangeCount = pb.changeCount
        // Move to top.
        if let i = items.firstIndex(of: item) {
            var moved = items.remove(at: i)
            moved.date = Date()
            items.insert(moved, at: 0)
        }
        withAnimation { lastCopiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.lastCopiedID == item.id { withAnimation { self?.lastCopiedID = nil } }
        }
        save()
    }

    /// File URL for an item's stored image (for previews / multi-paste).
    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { folder.appendingPathComponent($0) }
    }

    /// Apps that host Claude Code / Codex / shells: pasting image *paths* there makes the CLI
    /// attach them as [Image #N], exactly like dragging a file into the terminal.
    static let terminalBundles: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.google.antigravity",
        "dev.zed.Zed", "com.exafunction.windsurf",
    ]

    static func isTerminal(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return terminalBundles.contains(id) || id.lowercased().contains("terminal")
    }

    /// Copies an item's image to a space-free path (~/Library/Caches/MyNotch/clips) so terminals and
    /// CLIs get a clean path when it's dragged or pasted.
    func exportedImageURL(for item: ClipItem, index: Int? = nil) -> URL? {
        guard let src = imageURL(for: item) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MyNotch/clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("image-\(item.id.uuidString.prefix(8).lowercased()).png")
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: src, to: dest) }
        return FileManager.default.fileExists(atPath: dest.path) ? dest : src
    }

    /// Puts several items on the pasteboard at once.
    /// - terminals/IDEs: image & file *paths* as text (Claude Code / Codex turn them into [Image #N])
    /// - other apps: files as file URLs (chat apps & browsers attach them all); a lone image as image data.
    @discardableResult
    func writeToPasteboard(_ list: [ClipItem], forTerminal: Bool = false) -> Int {
        guard !list.isEmpty else { return 0 }
        let pb = NSPasteboard.general
        let visual = list.filter { $0.kind == .image || $0.kind == .file }
        pb.clearContents()
        if visual.isEmpty {
            pb.setString(list.compactMap(\.text).joined(separator: "\n\n"), forType: .string)
            ownChangeCount = pb.changeCount
            return list.count
        }
        var urls: [URL] = []
        for item in visual {
            if item.kind == .image, let u = exportedImageURL(for: item) { urls.append(u) }
            else if let files = item.files { urls.append(contentsOf: files.map { URL(fileURLWithPath: $0) }) }
        }
        if forTerminal {
            let escaped = urls.map { $0.path.replacingOccurrences(of: " ", with: "\\ ") }
            let texts = list.filter { $0.kind != .image && $0.kind != .file }.compactMap(\.text)
            pb.setString((escaped + texts).joined(separator: " ") + " ", forType: .string)
            ownChangeCount = pb.changeCount
            return urls.count + texts.count
        }
        if visual.count == 1, list.count == 1, let only = visual.first, only.kind == .image, let img = image(for: only) {
            pb.writeObjects([img])
            ownChangeCount = pb.changeCount
            return 1
        }
        pb.writeObjects(urls as [NSURL])
        ownChangeCount = pb.changeCount
        return urls.count
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        if let f = item.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
        withAnimation { items.removeAll { $0.id == item.id } }
        save()
    }

    func clearUnpinned() {
        for i in items where !i.pinned { if let f = i.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) } }
        withAnimation { items.removeAll { !$0.pinned } }
        save()
    }
}
