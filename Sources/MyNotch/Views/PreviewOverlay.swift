import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Large in-notch preview (the notch grows taller while it's showing).
struct PreviewItem: Identifiable, Equatable {
    enum Kind: Equatable { case image(URL), file(URL), text(String) }
    var id = UUID()
    var title: String
    var kind: Kind

    var url: URL? {
        switch kind {
        case .image(let u), .file(let u): u
        case .text: nil
        }
    }
}

@Observable
final class PreviewCenter {
    static let shared = PreviewCenter()
    var items: [PreviewItem] = []
    var index = 0
    var active: Bool { !items.isEmpty }
    /// Extra height the open notch gains while previewing.
    static let extraHeight: CGFloat = 210

    var current: PreviewItem? { items.indices.contains(index) ? items[index] : nil }

    func show(_ items: [PreviewItem], at index: Int = 0) {
        guard !items.isEmpty else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            self.items = items
            self.index = min(max(0, index), items.count - 1)
        }
    }

    func close() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { items = [] }
    }

    func step(_ d: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.18)) { index = (index + d + items.count) % items.count }
    }
}

struct PreviewOverlay: View {
    private var p: PreviewCenter { .shared }
    @FocusState private var focused: Bool

    var body: some View {
        if let item = p.current {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if p.items.count > 1 {
                        Text("\(p.index + 1) / \(p.items.count)").font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if let url = item.url {
                        PillButton(title: "Open", symbol: "arrow.up.forward.square") { NSWorkspace.shared.open(url) }
                        PillButton(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    PillButton(title: "Copy", symbol: "doc.on.doc") { copy(item) }
                    IconButton(symbol: "xmark", size: 11, help: "Close (Esc)") { p.close() }
                }
                ZStack {
                    PreviewContent(item: item).id(item.id).transition(.opacity)
                    if p.items.count > 1 {
                        HStack {
                            arrow("chevron.left") { p.step(-1) }
                            Spacer()
                            arrow("chevron.right") { p.step(1) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .padding(.top, 6)
            .background(Color.black)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { p.step(-1); return .handled }
            .onKeyPress(.rightArrow) { p.step(1); return .handled }
            .onKeyPress(.escape) { p.close(); return .handled }
            .onKeyPress(.space) { p.close(); return .handled }
            .onAppear { focused = true }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15)))
        }
        .buttonStyle(PressStyle())
    }

    private func copy(_ item: PreviewItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .image(let u):
            if let img = NSImage(contentsOf: u) { pb.writeObjects([img]) } else { pb.writeObjects([u as NSURL]) }
        case .file(let u): pb.writeObjects([u as NSURL])
        }
    }
}

private struct PreviewContent: View {
    var item: PreviewItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            switch item.kind {
            case .text(let s):
                ScrollView {
                    Text(s).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            default:
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 10)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { load() }
    }

    private func load() {
        guard let url = item.url else { return }
        if case .image = item.kind, let img = NSImage(contentsOf: url) { image = img; return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1100, height: 700), scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let img = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async { image = img }
        }
    }
}
