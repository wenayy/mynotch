import AppKit
import SwiftUI
import Observation

// MARK: - Geometry

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool
    var displayID: CGDirectDisplayID

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(screenFrame: frame, notchSize: CGSize(width: max(width, 120), height: top),
                                 hasNotch: true, displayID: id)
        }
        // No hardware notch: draw a simulated one the height of the menu bar.
        var menuBar = frame.maxY - screen.visibleFrame.maxY
        if menuBar < 20 || menuBar > 44 { menuBar = 25 }
        let width = CGFloat(AppSettings.shared.simulatedNotchWidth)
        return NotchGeometry(screenFrame: frame, notchSize: CGSize(width: width, height: menuBar),
                             hasNotch: false, displayID: id)
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    var allowsKey = false

    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Peeks (transient banners that drop out of the notch)

struct Peek: Identifiable, Equatable {
    enum Style { case standard, success, warning, error }
    let id = UUID()
    var symbol: String
    var image: NSImage? = nil
    var tint: Color = .white
    var title: String
    var subtitle: String? = nil
    var tool: ToolKind? = nil
    var duration: TimeInterval = 3.6
    var style: Style = .standard
    var sound: NSSound.Name? = nil

    static func == (a: Peek, b: Peek) -> Bool { a.id == b.id }
}

@Observable
final class PeekCenter {
    static let shared = PeekCenter()
    private(set) var current: Peek?
    @ObservationIgnored private var queue: [Peek] = []
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    func post(_ peek: Peek) {
        DispatchQueue.main.async {
            if let s = peek.sound, AppSettings.shared.playSounds { NSSound(named: s)?.play() }
            if self.current == nil { self.show(peek) } else {
                if self.queue.count < 4 { self.queue.append(peek) }
            }
        }
    }

    func dismiss() {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { current = nil }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.show(next) }
        }
    }

    private func show(_ peek: Peek) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) { current = peek }
        let w = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + peek.duration, execute: w)
    }
}

// MARK: - Mouse monitor

enum MouseKind { case moved, dragged, down, up, scroll(dy: CGFloat, inverted: Bool) }

final class MouseMonitor {
    var handler: ((MouseKind, CGPoint) -> Void)?
    private var monitors: [Any] = []
    private(set) var contentDragActive = false
    private var dragChangeCount = 0

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.process(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.process(e); return e }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func process(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        switch e.type {
        case .mouseMoved: handler?(.moved, p)
        case .leftMouseDown, .rightMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            handler?(.down, p)
        case .leftMouseDragged:
            if !contentDragActive, NSPasteboard(name: .drag).changeCount != dragChangeCount {
                contentDragActive = true
            }
            handler?(.dragged, p)
        case .leftMouseUp:
            handler?(.up, p)
            if contentDragActive {
                // Let the drop land before we consider the drag over.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.contentDragActive = false }
            }
        case .scrollWheel:
            handler?(.scroll(dy: e.scrollingDeltaY, inverted: e.isDirectionInvertedFromDevice), p)
        default: break
        }
    }
}

// MARK: - Fullscreen detection

final class FullscreenWatcher {
    static let shared = FullscreenWatcher()
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    private(set) var fullscreenDisplays: Set<CGDirectDisplayID> = []
    private var timer: Timer?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.check() }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    func check() {
        var result = Set<CGDirectDisplayID>()
        if AppSettings.shared.hideInFullscreen,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            for screen in NSScreen.screens {
                // Convert to CoreGraphics' top-left origin space.
                let f = screen.frame
                let cg = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                let covered = list.contains { info in
                    guard (info[kCGWindowLayer as String] as? Int) == 0,
                          (info[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                          let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                    return abs(r.minX - cg.minX) < 1 && abs(r.minY - cg.minY) < 1 &&
                           abs(r.width - cg.width) < 1 && abs(r.height - cg.height) < 1
                }
                if covered, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    result.insert(id.uint32Value)
                }
            }
        }
        if result != fullscreenDisplays {
            fullscreenDisplays = result
            onChange?(result)
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
