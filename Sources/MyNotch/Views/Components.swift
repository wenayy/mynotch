import SwiftUI
import AppKit

enum Theme {
    static var accent: Color {
        let s = AppSettings.shared
        if s.accent == .artwork {
            let np = NowPlayingService.shared
            return np.artwork != nil ? np.artworkColor : .claude
        }
        return s.accent.base
    }
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
}

// MARK: - Notch shape

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = max(0, min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

struct Ring: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 6
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, min(1, progress)))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress)
    }
}

/// Percentage ring that turns amber/red as it fills.
struct UsageRing: View {
    var percent: Double?
    var color: Color
    var size: CGFloat = 58
    var lineWidth: CGFloat = 6
    var caption: String? = nil

    private var tint: Color {
        guard let p = percent else { return color }
        if p >= 90 { return Color(hex: 0xFF5A5F) }
        if p >= 75 { return Color(hex: 0xFFB547) }
        return color
    }

    var body: some View {
        ZStack {
            Ring(progress: (percent ?? 0) / 100, color: tint, lineWidth: lineWidth)
            VStack(spacing: -1) {
                (Text(percent.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                    + Text(percent == nil ? "" : "%").font(.system(size: size * 0.15, weight: .semibold, design: .rounded)))
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption).font(.system(size: max(8, size * 0.13), weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct LinearMeter: View {
    var value: Double
    var color: Color
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: value)
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 13
    var active = false
    var tint: Color? = nil
    var help: String = ""
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? (tint ?? Theme.accent) : (hover ? .white : Theme.secondary))
                .frame(width: size + 15, height: size + 13)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? (tint ?? Theme.accent).opacity(0.18) : (hover ? Color.white.opacity(0.1) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct PillButton: View {
    var title: String
    var symbol: String? = nil
    var prominent = false
    var tint: Color? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? .black : .white)
            .background(Capsule().fill(prominent ? (tint ?? Theme.accent) : Color.white.opacity(hover ? 0.16 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SectionLabel: View {
    var text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.tertiary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.tertiary) }
        }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            if let actionTitle, let action { PillButton(title: actionTitle, prominent: true, action: action).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Little animated equalizer used for "playing" states.
/// Uses render-server driven repeatForever animations (no per-frame body updates).
struct AudioBars: View {
    var color: Color
    var playing: Bool
    var bars = 4
    @State private var up = false
    private let durations: [Double] = [0.42, 0.31, 0.53, 0.37, 0.47, 0.29]
    private let highs: [CGFloat] = [1.0, 0.7, 0.9, 0.6, 0.85, 0.75]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.6, height: playing ? (up ? 14 * highs[i % highs.count] : 4) : 3.5)
                    .animation(playing ? .easeInOut(duration: durations[i % durations.count]).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.2), value: up)
            }
        }
        .frame(height: 14)
        .onAppear { up = playing }
        .onChange(of: playing) { _, v in up = v }
    }
}

/// Claude's spark, slowly turning while work is happening.
struct SparkIcon: View {
    var color: Color = .claude
    var animating: Bool          // kept for call sites; the spark never spins (motion was distracting)
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(color.opacity(animating ? 1 : 0.85))
    }
}

struct HoverRow<Content: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action?() }
    }
}

/// App / file icon from a path, cached by AppKit.
struct FileIcon: View {
    var path: String
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - File dragging

/// Drag provider that terminals, Claude Code, Codex, chat apps and Finder all accept:
/// a real file URL (terminals paste the path → CLIs show [Image #N]) plus the file's contents.
///
/// Only the URL object is registered. Registering file contents too makes AppKit hand out a lazy
/// file *promise*, which browsers (ChatGPT, Claude.ai) can't read — their drop zone shows, then nothing attaches.
func fileDragProvider(_ url: URL) -> NSItemProvider {
    let p = NSItemProvider(object: url as NSURL)
    p.suggestedName = url.lastPathComponent
    return p
}

/// Drag several files at once (AppKit dragging session — SwiftUI's onDrag only carries one item).
struct MultiFileDragHandle: NSViewRepresentable {
    var urls: () -> [URL]
    var label: String

    func makeNSView(context: Context) -> DragView { DragView(urls: urls, label: label) }
    func updateNSView(_ v: DragView, context: Context) { v.urls = urls; v.label = label; v.needsDisplay = true }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL]
        var label: String
        init(urls: @escaping () -> [URL], label: String) { self.urls = urls; self.label = label; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize {
            let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
            return NSSize(width: w + 34, height: 26)
        }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            let icon = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            icon?.isTemplate = true
            if let icon {
                let tinted = icon.copy() as! NSImage
                tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
                tinted.draw(at: NSPoint(x: 10, y: (bounds.height - tinted.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
            (label as NSString).draw(at: NSPoint(x: 26, y: (bounds.height - 14) / 2),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        }
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {
            let list = urls()
            guard !list.isEmpty else { return }
            let items: [NSDraggingItem] = list.enumerated().map { i, u in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                let img = NSWorkspace.shared.icon(forFile: u.path)
                let s: CGFloat = 40
                item.setDraggingFrame(NSRect(x: CGFloat(i) * 6, y: CGFloat(i) * -6, width: s, height: s), contents: img)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
