import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NotchRootView: View {
    let vm: NotchViewModel
    var body: some View {
        VStack(spacing: 0) {
            NotchBody(vm: vm)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

private struct NotchBody: View {
    let vm: NotchViewModel
    private var settings: AppSettings { .shared }

    var body: some View {
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        ZStack(alignment: .top) {
            NotchBackground(theme: settings.theme, open: vm.isOpen)
            content
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay {
            if settings.theme == .neon || settings.theme == .glass {
                shape.stroke(settings.theme == .neon ? Theme.accent.opacity(vm.isOpen ? 0.8 : 0.45) : Color.white.opacity(0.12),
                             lineWidth: settings.theme == .neon ? 1.2 : 0.6)
                    .shadow(color: settings.theme == .neon ? Theme.accent.opacity(0.7) : .clear, radius: 6)
            }
        }
        .shadow(color: .black.opacity(vm.isOpen || vm.peek != nil ? 0.55 : 0), radius: 16, y: 6)
        .overlay(alignment: .bottom) {
            if vm.hovering && !vm.isOpen && settings.showHoverGlow {
                Capsule().fill(Theme.accent.opacity(0.85)).frame(width: 36, height: 2.5)
                    .blur(radius: 0.5).offset(y: -2).transition(.opacity)
            }
        }
        .contentShape(shape)
        .opacity(vm.hidden ? 0 : 1)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: vm.activity)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: vm.peek?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: vm.hovering)
    }

    @ViewBuilder private var content: some View {
        if vm.isOpen {
            OpenNotchView(vm: vm)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).animation(.spring(response: 0.4, dampingFraction: 0.82).delay(0.04)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
        } else if let peek = vm.peek {
            PeekView(peek: peek, notchHeight: vm.notchSize.height, expanded: vm.hovering)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -8)).animation(.easeOut(duration: 0.25).delay(0.14)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
        } else {
            ClosedNotchView(vm: vm).transition(.opacity)
        }
    }
}

struct NotchBackground: View {
    var theme: NotchTheme
    var open: Bool
    var body: some View {
        ZStack {
            Color.black
            switch theme {
            case .midnight, .neon:
                EmptyView()
            case .glass:
                LinearGradient(colors: [Color.white.opacity(open ? 0.07 : 0.03), .clear], startPoint: .top, endPoint: .bottom)
            case .aurora:
                if open {
                    TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        ZStack {
                            Circle().fill(Theme.accent.opacity(0.22)).frame(width: 260).blur(radius: 70)
                                .offset(x: CGFloat(sin(t * 0.25)) * 220, y: 60 + CGFloat(cos(t * 0.2)) * 30)
                            Circle().fill(Color(hex: 0x6E5BFF).opacity(0.18)).frame(width: 240).blur(radius: 80)
                                .offset(x: CGFloat(cos(t * 0.21)) * -200, y: 110 + CGFloat(sin(t * 0.3)) * 25)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Closed notch: live activities

struct ClosedNotchView: View {
    let vm: NotchViewModel
    var body: some View {
        let a = vm.activity
        let h = vm.notchSize.height
        Group {
            if a == .ticker {
                TickerView(text: AppSettings.shared.tickerText).frame(height: h)
            } else {
                HStack(spacing: 0) {
                    LeftWing(activity: a).frame(width: a.wing, height: h).padding(.leading, 3)
                    Spacer(minLength: 0)
                    RightWing(activity: a).frame(width: a.wing, height: h).padding(.trailing, 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: h)
    }
}

private struct LeftWing: View {
    var activity: LiveActivity
    var body: some View {
        switch activity {
        case .media:
            let np = NowPlayingService.shared
            Group {
                if let art = np.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else if let icon = np.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "music.note").foregroundStyle(np.artworkColor)
                }
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .onTapGesture { NowPlayingService.shared.togglePlayPause() }
        case .agent:
            switch AIUsageCenter.shared.agentActivity {
            case .claudeWaiting:
                Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)
            case .codexBusy:
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.codex)
                    .symbolEffect(.pulse, options: .repeating)
            default:
                SparkIcon(animating: true, size: 13)
            }
        case .timer:
            let engine = TimerEngine.shared
            let isPomo = engine.primary?.id == engine.pomodoro?.id
            Image(systemName: isPomo ? (engine.pomodoroPhase == .focus ? "brain.head.profile" : "cup.and.saucer.fill") : "timer")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
        case .charging:
            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: SystemStats.shared.chargingBanner)
        case .hud:
            let e = HUDService.shared.current
            Image(systemName: hudSymbol(e))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .usage:
            Ring(progress: (AIUsageCenter.shared.claude.limits?.session?.percent ?? 0) / 100, color: .claude, lineWidth: 2.5)
                .frame(width: 13, height: 13)
        case .none, .ticker:
            EmptyView()
        }
    }

    private func hudSymbol(_ e: HUDService.Event?) -> String {
        guard let e else { return "speaker.wave.2.fill" }
        if e.kind == .brightness { return e.level < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        if e.muted || e.level <= 0.001 { return "speaker.slash.fill" }
        return e.level < 0.33 ? "speaker.wave.1.fill" : (e.level < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
}

private struct RightWing: View {
    var activity: LiveActivity
    var body: some View {
        switch activity {
        case .media:
            AudioBars(color: NowPlayingService.shared.artworkColor, playing: NowPlayingService.shared.isPlaying, bars: 3)
                .scaleEffect(0.8)
        case .agent:
            let center = AIUsageCenter.shared
            switch center.agentActivity {
            case .claudeWaiting(let n):
                Text(n > 1 ? "\(n)" : "you").font(.rounded(11, .bold)).foregroundStyle(.yellow)
            case .codexBusy:
                if let p = center.codex.limits?.primary?.percent {
                    Text(Fmt.percent(p)).font(.rounded(11, .bold)).foregroundStyle(Color.codex)
                } else {
                    AudioBars(color: .codex, playing: true, bars: 3)
                }
            case .claudeBusy(let n):
                if let p = center.claude.limits?.session?.percent {
                    Text(Fmt.percent(p)).font(.rounded(11, .bold)).foregroundStyle(Color.claude).contentTransition(.numericText())
                } else {
                    Text(n > 1 ? "×\(n)" : "…").font(.rounded(11, .bold)).foregroundStyle(Color.claude)
                }
            case .none:
                EmptyView()
            }
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Fmt.clock(TimerEngine.shared.primary?.remaining ?? 0))
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.orange)
            }
        case .charging:
            Text("\(SystemStats.shared.batteryPercent ?? 0)%").font(.rounded(11, .bold)).foregroundStyle(.green)
        case .hud:
            let e = HUDService.shared.current
            LinearMeter(value: e?.muted == true ? 0 : (e?.level ?? 0), color: .white, height: 3.5).frame(width: 44)
        case .usage:
            Text(Fmt.percent(AIUsageCenter.shared.claude.limits?.session?.percent ?? 0))
                .font(.rounded(11, .bold)).foregroundStyle(Color.claude)
        case .none, .ticker:
            EmptyView()
        }
    }
}

/// Dot-matrix style scrolling message across the notch wings.
struct TickerView: View {
    var text: String
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { ctx in
            GeometryReader { g in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let content = "  ✦  " + text.uppercased()
                let w = CGFloat(content.count) * 7.4
                let span = g.size.width + w
                let x = g.size.width - CGFloat((t * 42).truncatingRemainder(dividingBy: Double(span)))
                Text(content)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                    .fixedSize()
                    .offset(x: x, y: (g.size.height - 14) / 2)
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                     .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Peek banner

struct PeekView: View {
    var peek: Peek
    var notchHeight: CGFloat
    var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Compact island row: icon | (camera notch) | label
            HStack(spacing: 0) {
                icon.frame(width: 20, height: 20).padding(.leading, 13)
                Spacer(minLength: 0)
                Text(peek.label)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(peek.style == .standard ? .white : peek.tint)
                    .lineLimit(1)
                    .padding(.trailing, 14)
                    .contentTransition(.opacity)
            }
            .frame(height: notchHeight)
            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if let s = peek.subtitle {
                        Text(s).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expanded)
    }

    @ViewBuilder private var icon: some View {
        if let img = peek.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: peek.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(peek.tint)
                .symbolEffect(.bounce, value: peek.id)
        }
    }
}

// MARK: - Open notch

struct OpenNotchView: View {
    let vm: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(vm: vm).frame(height: vm.headerHeight)
            ZStack(alignment: .topLeading) {
                ToolContainer(tool: vm.currentTool, vm: vm)
                    .id(vm.currentTool)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .overlay {
            if vm.fileDragging { DropZones(vm: vm).transition(.opacity) }
        }
        .overlay {
            if PreviewCenter.shared.active {
                VStack(spacing: 0) {
                    Color.clear.frame(height: vm.headerHeight).allowsHitTesting(false)
                    PreviewOverlay()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .onChange(of: PreviewCenter.shared.active) { _, on in if on { vm.takeKeyboard() } }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: PreviewCenter.shared.active)
        .overlay(alignment: .bottom) {
            if let peek = PeekCenter.shared.current {
                HStack(spacing: 8) {
                    Image(systemName: peek.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(peek.tint)
                    Text(peek.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if let s = peek.subtitle { Text(s).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.13)).shadow(color: .black.opacity(0.4), radius: 8))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .padding(.bottom, 8)
                .onTapGesture { if let t = peek.tool { vm.select(t) }; PeekCenter.shared.dismiss() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: PeekCenter.shared.current?.id)
        .animation(.easeInOut(duration: 0.18), value: vm.fileDragging)
    }
}

private struct HeaderBar: View {
    let vm: NotchViewModel
    private var settings: AppSettings { .shared }

    var body: some View {
        let tools = settings.visibleTools
        let side = (vm.openSize.width - vm.notchSize.width) / 2 - 22
        let slot: CGFloat = 29
        let leftCap = max(1, Int(side / slot))
        let rightCap = max(0, Int((side - 64) / slot))
        let left = Array(tools.prefix(leftCap))
        let rest = Array(tools.dropFirst(leftCap))
        let right = Array(rest.prefix(rest.count > rightCap ? max(0, rightCap - 1) : rightCap))
        let overflow = Array(rest.dropFirst(right.count))

        HStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(left) { tab($0) }
            }
            .frame(width: side, alignment: .leading)
            .padding(.leading, 16)

            Spacer(minLength: 0)
            if !vm.geometry.hasNotch {
                Text(vm.currentTool.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 1) {
                ForEach(right) { tab($0) }
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { t in Button { vm.select(t) } label: { Label(t.title, systemImage: t.symbol) } }
                    } label: {
                        Image(systemName: overflow.contains(vm.currentTool) ? vm.currentTool.symbol : "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(overflow.contains(vm.currentTool) ? Theme.accent : Theme.secondary)
                            .frame(width: 27, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                }
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 5)
                IconButton(symbol: vm.pinned ? "pin.fill" : "pin", size: 11, active: vm.pinned,
                           help: vm.pinned ? "Unpin — closes normally again" : "Pin — keep the notch open") {
                    vm.pinned.toggle()
                }
                IconButton(symbol: "gearshape.fill", size: 11, help: "Settings") {
                    vm.close()
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
            }
            .frame(width: side, alignment: .trailing)
            .padding(.trailing, 16)
        }
    }

    private func tab(_ t: ToolKind) -> some View { TabButton(tool: t, vm: vm) }
}

private struct ToolContainer: View {
    let tool: ToolKind
    let vm: NotchViewModel
    var body: some View {
        switch tool {
        case .home: HomeView(vm: vm)
        case .ai: AIUsageView()
        case .apps: AppsView(vm: vm)
        case .media: MediaView()
        case .shelf: ShelfView()
        case .convert: ConvertView()
        case .clipboard: ClipboardView()
        case .calendar: CalendarView()
        case .timers: TimersView()
        case .stats: StatsView()
        case .notes: NotesView(vm: vm)
        case .weather: WeatherView()
        case .links: LinksView(vm: vm)
        case .units: UnitsView()
        case .sounds: SoundsView()
        case .camera: CameraView()
        }
    }
}

// MARK: - Drop zones (shown while dragging files over the open notch)

private struct DropZones: View {
    let vm: NotchViewModel
    @State private var width: CGFloat = 1
    @State private var hoverZone: Int?

    private var active: Int? { hoverZone ?? vm.dragZone }

    var body: some View {
        HStack(spacing: 12) {
            zone(index: 0, title: "Shelf", subtitle: "Keep it here for later", symbol: "tray.and.arrow.down.fill")
            zone(index: 1, title: "Convert", subtitle: "JPG · PNG · PDF and more", symbol: "arrow.triangle.2.circlepath.doc.on.clipboard")
            zone(index: 2, title: "AirDrop", subtitle: "Send to a nearby device", symbol: "airplayaudio")
        }
        .padding(.horizontal, 20)
        .padding(.top, vm.headerHeight + 6)
        .padding(.bottom, 14)
        .background(GeometryReader { g in Color.black.opacity(0.88).onAppear { width = g.size.width } })
        // One drop target for the whole area: the drop goes to whichever third the pointer is over.
        .onDrop(of: [.fileURL, .url, .image, .plainText, .text], delegate: ZoneDrop(width: { width }, zone: $hoverZone) { index, providers in
            deliver(index, providers)
        })
    }

    private func deliver(_ index: Int, _ providers: [NSItemProvider]) -> Bool {
        switch index {
        case 0:
            vm.select(.shelf)
            return ShelfStore.shared.accept(providers)
        case 1:
            vm.select(.convert)
            return ConverterStore.shared.accept(providers)
        default:
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !urls.isEmpty { ShelfStore.shared.airDrop(urls) } }
            return true
        }
    }

    private func zone(index: Int, title: String, subtitle: String, symbol: String) -> some View {
        let on = active == index
        return VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : .white.opacity(0.8))
                .symbolEffect(.bounce, value: on)
            Text(title).font(.system(size: 13, weight: .bold))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(on ? Theme.accent : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .scaleEffect(on ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }
}

private struct ZoneDrop: DropDelegate {
    var width: () -> CGFloat
    @Binding var zone: Int?
    var perform: (Int, [NSItemProvider]) -> Bool

    private func index(_ info: DropInfo) -> Int { min(2, max(0, Int(info.location.x / max(1, width() / 3)))) }

    func dropEntered(info: DropInfo) { zone = index(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let i = index(info)
        if zone != i { withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { zone = i } }
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }
    func performDrop(info: DropInfo) -> Bool {
        let i = index(info)
        zone = nil
        return perform(i, info.itemProviders(for: [.fileURL, .url, .image, .plainText, .text]))
    }
}

/// Header tab: click or hover to switch (hover is configurable); drag sideways to reorder.
private struct TabButton: View {
    let tool: ToolKind
    let vm: NotchViewModel
    @State private var hoverWork: DispatchWorkItem?
    @State private var dragX: CGFloat = 0
    @State private var dragging = false
    static var anyDragging = false
    static let slot: CGFloat = 29

    var body: some View {
        IconButton(symbol: tool.symbol, size: 12, active: vm.currentTool == tool, help: "\(tool.title) — drag to reorder") { vm.select(tool) }
            .offset(x: dragX)
            .scaleEffect(dragging ? 1.18 : 1)
            .shadow(color: .black.opacity(dragging ? 0.6 : 0), radius: 6)
            .zIndex(dragging ? 10 : 0)
            .onHover { inside in
                hoverWork?.cancel()
                guard inside, !Self.anyDragging, AppSettings.shared.hoverSwitchTabs, vm.currentTool != tool else { return }
                let w = DispatchWorkItem { vm.select(tool) }
                hoverWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: w)
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging { dragging = true; Self.anyDragging = true; Haptics.tap() }
                        dragX = v.translation.width
                    }
                    .onEnded { v in
                        let steps = Int((v.translation.width / Self.slot).rounded())
                        Self.anyDragging = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragging = false
                            dragX = 0
                            if steps != 0 { Self.move(tool, by: steps) }
                        }
                    }
            )
    }

    /// Moves `tool` by `steps` positions among the visible tabs, keeping hidden tools in place.
    static func move(_ tool: ToolKind, by steps: Int) {
        let s = AppSettings.shared
        var visible = s.visibleTools
        guard let i = visible.firstIndex(of: tool) else { return }
        let j = min(max(0, i + steps), visible.count - 1)
        guard i != j else { return }
        visible.remove(at: i)
        visible.insert(tool, at: j)
        let full = s.toolOrder + ToolKind.allCases.filter { !s.toolOrder.contains($0) }
        let hidden = full.filter { !visible.contains($0) }
        s.toolOrder = visible + hidden
        Haptics.tap()
    }
}
