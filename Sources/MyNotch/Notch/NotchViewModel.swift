import AppKit
import SwiftUI
import Observation

/// What the closed notch shows in its "wings".
enum LiveActivity: Equatable {
    case none, media, agent, timer, charging, hud, ticker, usage

    var wing: CGFloat {
        switch self {
        case .none: 0
        case .media: 36
        case .agent: 54
        case .timer: 58
        case .charging: 52
        case .hud: 84
        case .ticker: 130
        case .usage: 46
        }
    }
}

@Observable
final class NotchViewModel {
    enum State { case closed, open }

    var geometry: NotchGeometry
    var state: State = .closed
    var hovering = false
    var pinned = false
    var dropTargeted = false
    var fileDragging = false
    var hidden = false
    /// Keeps the notch open while typing (quick jot) even if the pointer wanders off.
    var holdOpen = false
    var currentTool: ToolKind

    @ObservationIgnored weak var panel: NotchPanel?
    @ObservationIgnored private var openWork: DispatchWorkItem?
    @ObservationIgnored private var closeWork: DispatchWorkItem?
    @ObservationIgnored weak var mouse: MouseMonitor?
    @ObservationIgnored private var openedByDrag = false
    @ObservationIgnored private var dragStartedInside = false

    private var settings: AppSettings { .shared }

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let s = AppSettings.shared
        currentTool = s.rememberLastTool ? s.lastTool : s.defaultTool
        if !s.visibleTools.contains(currentTool) { currentTool = s.visibleTools.first ?? .home }
    }

    var isOpen: Bool { state == .open }
    var isDragging: Bool { mouse?.contentDragActive ?? false }

    // MARK: Sizes

    var notchSize: CGSize { geometry.notchSize }
    var headerHeight: CGFloat { max(geometry.notchSize.height, 30) }

    var openSize: CGSize {
        CGSize(width: settings.panelSize.width,
               height: headerHeight + settings.panelSize.contentHeight + (PreviewCenter.shared.active ? PreviewCenter.extraHeight : 0))
    }

    var activity: LiveActivity {
        if HUDService.shared.current != nil { return .hud }
        if settings.liveCharging, SystemStats.shared.chargingBanner { return .charging }
        if settings.liveTimer, TimerEngine.shared.primary != nil { return .timer }
        if settings.liveAI, let a = AIUsageCenter.shared.agentActivity, a.isWaiting || settings.liveAIWorking { return .agent }
        if settings.liveMedia, NowPlayingService.shared.isPlaying { return .media }
        if settings.tickerEnabled, !settings.tickerText.isEmpty { return .ticker }
        if settings.alwaysShowUsage, AIUsageCenter.shared.claude.limits?.session != nil { return .usage }
        return .none
    }

    var closedSize: CGSize {
        let a = activity
        var w = notchSize.width + a.wing * 2
        var h = notchSize.height
        if hovering && a == .none {
            w += 14
            h += 3
        } else if hovering {
            w += 8
        }
        return CGSize(width: w, height: h)
    }

    var peek: Peek? {
        guard !isOpen, !hidden else { return nil }
        return PeekCenter.shared.current
    }

    /// Dynamic-Island style: the notch just grows sideways (icon left, short label right).
    /// Hovering it expands downward with the full title and detail.
    var peekSize: CGSize {
        guard let peek = PeekCenter.shared.current else { return closedSize }
        if hovering {
            return CGSize(width: min(max(notchSize.width + 200, 420), openSize.width - 140), height: notchSize.height + 40)
        }
        let label = (peek.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
        let wing = max(46, label + 22)
        return CGSize(width: notchSize.width + wing * 2, height: notchSize.height)
    }

    var shapeSize: CGSize {
        if isOpen { return openSize }
        if peek != nil { return peekSize }
        return closedSize
    }

    var topRadius: CGFloat { isOpen ? 12 : 6 }
    var bottomRadius: CGFloat { isOpen ? 26 : (peek != nil ? (hovering ? 18 : 12) : (activity == .none ? 10 : 12)) }

    // MARK: Screen-space hit testing

    private func rect(for size: CGSize) -> CGRect {
        CGRect(x: geometry.screenFrame.midX - size.width / 2,
               y: geometry.screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    var closedHotRect: CGRect {
        let r = rect(for: peek != nil ? peekSize : closedSize)
        // Generous above (pointer can't go higher anyway) and a little below/aside.
        return CGRect(x: r.minX - 6, y: r.minY - 6, width: r.width + 12, height: r.height + 12)
    }

    var openRect: CGRect { rect(for: openSize).insetBy(dx: -2, dy: -2) }

    var dragCaptureRect: CGRect {
        let r = rect(for: closedSize)
        return CGRect(x: r.minX - 90, y: r.minY - 70, width: r.width + 180, height: r.height + 80)
    }

    // MARK: Mouse

    func handle(_ kind: MouseKind, at p: CGPoint) {
        guard !hidden, geometry.screenFrame.insetBy(dx: -1, dy: -1).contains(p) || isOpen || hovering else {
            return
        }
        let inClosed = closedHotRect.contains(p)
        let inOpen = isOpen && openRect.contains(p)

        switch kind {
        case .moved:
            updateHover(inClosed: inClosed, inOpen: inOpen)
        case .dragged:
            if isDragging && !dragStartedInside {
                if !fileDragging && (isOpen || dragCaptureRect.contains(p)) { fileDragging = true }
                if !isOpen && dragCaptureRect.contains(p) {
                    openedByDrag = true
                    open(animated: true)
                } else if isOpen && !inOpen && openedByDrag {
                    scheduleClose(after: 0.2)
                } else if inOpen {
                    cancelClose()
                }
            }
        case .down:
            dragStartedInside = isOpen ? inOpen : inClosed
            if isOpen && !inOpen && !pinned {
                close()
            } else if !isOpen && inClosed {
                // Clicking always opens (in hover mode it just skips the delay).
                if let peek, let tool = peek.tool {
                    PeekCenter.shared.dismiss()
                    open(tool: tool)
                } else {
                    open()
                }
            }
        case .up:
            if fileDragging {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.fileDragging = false }
            }
            if openedByDrag {
                openedByDrag = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.isOpen, !self.pinned else { return }
                    if !self.openRect.contains(NSEvent.mouseLocation) { self.close() }
                }
            }
        case let .scroll(dy, inverted):
            guard settings.scrollToOpen, abs(dy) > 3 else { break }
            let fingersDown = inverted ? dy > 0 : dy < 0
            if !isOpen && inClosed && fingersDown {
                open()
            } else if isOpen && !fingersDown {
                // Swipe up on the header row closes.
                let header = CGRect(x: openRect.minX, y: openRect.maxY - headerHeight - 4,
                                    width: openRect.width, height: headerHeight + 4)
                if header.contains(p) { close() }
            }
        }
        updateMouseCapture(p)
    }

    private func updateHover(inClosed: Bool, inOpen: Bool) {
        if isOpen {
            if inOpen { cancelClose() }
            else if !pinned && !holdOpen && !isDragging { scheduleClose(after: settings.closeDelay) }
            return
        }
        if inClosed != hovering {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = inClosed }
        }
        if inClosed && settings.openTrigger == .hover && peek == nil {   // hovering an alert expands it instead
            scheduleOpen()
        } else if !inClosed {
            cancelOpen()
        }
    }

    func updateMouseCapture(_ p: CGPoint = NSEvent.mouseLocation) {
        guard let panel else { return }
        let capture = !hidden && (closedHotRect.contains(p) || (isOpen && openRect.contains(p)) || (isOpen && isDragging))
        if panel.ignoresMouseEvents == capture { panel.ignoresMouseEvents = !capture }
    }

    // MARK: Open / close

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            if self.closedHotRect.contains(NSEvent.mouseLocation) { self.open() }
        }
        openWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, settings.hoverDelay), execute: w)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            let p = NSEvent.mouseLocation
            if !self.openRect.contains(p) && !self.pinned && !self.holdOpen { self.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    func open(tool: ToolKind? = nil, animated: Bool = true) {
        cancelOpen()
        cancelClose()
        if let tool, settings.visibleTools.contains(tool) || tool == .shelf { select(tool) }
        guard !isOpen else { return }
        Haptics.tap()
        panel?.allowsKey = true
        withAnimation(animated ? .spring(response: 0.42, dampingFraction: 0.8) : nil) {
            state = .open
            hovering = false
        }
        updateMouseCapture()
    }

    func close() {
        cancelOpen()
        cancelClose()
        guard isOpen else { return }
        let wasKey = panel?.isKeyWindow ?? false
        holdOpen = false
        pinned = false
        if PreviewCenter.shared.active { PreviewCenter.shared.close() }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.95)) {
            state = .closed
            hovering = false
            dropTargeted = false
        }
        panel?.allowsKey = false
        if wasKey, let panel {
            // Hand keyboard focus back to whatever the user was working in.
            panel.resignKey()
            NSWorkspace.shared.frontmostApplication?.activate()
        }
        if !settings.rememberLastTool { currentTool = settings.defaultTool }
        updateMouseCapture()
    }

    func toggle() { isOpen ? close() : open() }

    /// Gives the (non-activating) panel keyboard focus without activating MyNotch,
    /// so typing goes to the notch while the app you were in stays frontmost.
    func takeKeyboard() {
        guard let panel else { return }
        panel.allowsKey = true
        panel.makeKey()
    }

    func select(_ tool: ToolKind) {
        guard tool != currentTool else { return }
        if PreviewCenter.shared.active { PreviewCenter.shared.close() }
        withAnimation(.easeInOut(duration: 0.18)) { currentTool = tool }
        settings.lastTool = tool
    }
}
