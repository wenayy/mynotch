import SwiftUI
import AppKit

// MARK: - Home

struct HomeView: View {
    let vm: NotchViewModel
    private var calendar: CalendarService { .shared }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                clock.frame(width: 170)
                MiniPlayer().frame(maxWidth: .infinity)
                AIMiniCard().frame(width: 196)
            }
            .frame(maxHeight: .infinity)
            DockRow(vm: vm).frame(height: 46)
        }
    }

    private var clock: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.everyMinute) { ctx in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.rounded(32, .semibold)).monospacedDigit()
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Text(ctx.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let e = calendar.next {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(e.color).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(e.isNow ? "Now · until \(Fmt.time(e.end))" : "\(relative(e.start)) · \(Fmt.time(e.start))")
                                .font(.system(size: 9.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let url = e.meetingURL {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                                    .frame(width: 20, height: 20).background(Circle().fill(Color.green))
                            }.buttonStyle(.plain).help("Join")
                        }
                    }
                } else if let pct = SystemStats.shared.batteryPercent {
                    Label("\(pct)%" + (SystemStats.shared.charging ? " · charging" : ""),
                          systemImage: SystemStats.shared.charging ? "battery.100.bolt" : batterySymbol(pct))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .onAppear { calendar.reload() }
    }

    private func relative(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        return s < 60 ? "Starting" : "In \(Fmt.duration(s, short: s > 3600))"
    }

    private func batterySymbol(_ p: Int) -> String {
        p > 87 ? "battery.100" : p > 62 ? "battery.75" : p > 37 ? "battery.50" : p > 12 ? "battery.25" : "battery.0"
    }
}

struct AIMiniCard: View {
    private var ai: AIUsageCenter { .shared }
    var body: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AI limits").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if let a = ai.agentActivity {
                        HStack(spacing: 3) {
                            Circle().fill(a.isWaiting ? Color.yellow : Color.claude).frame(width: 5, height: 5)
                            Text(a.isWaiting ? "needs you" : "working").font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(a.isWaiting ? .yellow : .claude)
                        }
                    }
                }
                HStack(spacing: 10) {
                    mini(label: "Claude", percent: ai.claude.limits?.session?.percent, color: .claude,
                         sub: ai.claude.limits?.session.map { Fmt.reset($0.resetsAt) } ?? "5h")
                    mini(label: "Codex", percent: ai.codex.limits?.primary?.percent, color: .codex,
                         sub: ai.codex.limits?.primary?.label ?? "—")
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func mini(label: String, percent: Double?, color: Color, sub: String) -> some View {
        VStack(spacing: 4) {
            UsageRing(percent: percent, color: color, size: 50, lineWidth: 5)
            Text(label).font(.system(size: 10, weight: .semibold))
            Text(sub).font(.system(size: 8.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

extension AIUsageCenter.Activity {
    var isWaiting: Bool { if case .claudeWaiting = self { return true }; return false }
}

struct DockRow: View {
    let vm: NotchViewModel
    private var settings: AppSettings { .shared }
    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settings.pins.filter(\.exists)) { pin in
                        PinIcon(pin: pin, size: 34, showName: false) { vm.close() }
                    }
                }
                .padding(.horizontal, 4)
            }
            IconButton(symbol: "square.grid.2x2", size: 12, help: "All apps & pins") { vm.select(.apps) }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

// MARK: - Media

struct MiniPlayer: View {
    private var np: NowPlayingService { .shared }
    var body: some View {
        Card(padding: 10) {
            if np.hasMedia {
                HStack(spacing: 10) {
                    Artwork(size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(np.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(np.artist.isEmpty ? (np.appName ?? "") : np.artist)
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        ProgressLine(compact: true)
                        Controls(size: 13)
                    }
                }
            } else {
                EmptyState(symbol: "music.note", title: "Nothing playing",
                           subtitle: np.available ? "Play something in any app." : "Media bridge unavailable")
            }
        }
    }
}

struct Artwork: View {
    var size: CGFloat
    private var np: NowPlayingService { .shared }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let art = np.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.5), Theme.accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.system(size: size * 0.35, weight: .semibold)).foregroundStyle(.white.opacity(0.8)))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            .shadow(color: np.artworkColor.opacity(np.isPlaying ? 0.45 : 0), radius: 12)
            .scaleEffect(np.isPlaying ? 1 : 0.94)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: np.isPlaying)

            if let icon = np.appIcon {
                Image(nsImage: icon).resizable().frame(width: size * 0.3, height: size * 0.3)
                    .offset(x: 5, y: 5)
            }
        }
        .onTapGesture { np.openPlayer() }
        .help("Open \(np.appName ?? "player")")
    }
}

struct Controls: View {
    var size: CGFloat
    private var np: NowPlayingService { .shared }
    var body: some View {
        HStack(spacing: size * 1.1) {
            control("backward.fill", size * 0.9) { np.previous() }
            control(np.isPlaying ? "pause.fill" : "play.fill", size * 1.25) { np.togglePlayPause() }
                .contentTransition(.symbolEffect(.replace))
            control("forward.fill", size * 0.9) { np.next() }
        }
    }

    private func control(_ symbol: String, _ s: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: s, weight: .bold)).frame(width: s + 12, height: s + 10).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ProgressLine: View {
    var compact = false
    private var np: NowPlayingService { .shared }
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = dragging ?? np.position(at: ctx.date)
            let frac = np.duration > 0 ? pos / np.duration : 0
            VStack(spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(np.artworkColor).frame(width: max(4, g.size.width * frac))
                    }
                    .frame(height: dragging != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard np.duration > 0 else { return }
                            dragging = min(max(0, Double(v.location.x / g.size.width)), 1) * np.duration
                        }
                        .onEnded { _ in
                            if let d = dragging { np.seek(to: d) }
                            dragging = nil
                        })
                }
                .frame(height: 10)
                if !compact || np.duration > 0 {
                    HStack {
                        Text(Fmt.mediaTime(pos))
                        Spacer()
                        Text("-" + Fmt.mediaTime(max(0, np.duration - pos)))
                    }
                    .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

struct MediaView: View {
    private var np: NowPlayingService { .shared }
    /// Other apps with a media session (the active one is shown big).
    private var others: [MediaPlayer] { np.players.filter { $0.id != np.bundleID } }

    var body: some View {
        if np.hasMedia {
            VStack(spacing: 10) {
                HStack(spacing: 18) {
                    Artwork(size: others.isEmpty ? 150 : 108)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let icon = np.appIcon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                            Text(np.appName ?? "Now Playing").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                            Spacer()
                            AudioBars(color: np.artworkColor, playing: np.isPlaying, bars: 5)
                        }
                        Spacer(minLength: 0)
                        Text(np.title).font(.system(size: others.isEmpty ? 19 : 16, weight: .bold)).lineLimit(others.isEmpty ? 2 : 1)
                        Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        ProgressLine(compact: !others.isEmpty)
                        HStack {
                            Spacer()
                            Controls(size: others.isEmpty ? 20 : 16)
                            Spacer()
                        }
                    }
                }
                if !others.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(others) { OtherPlayerChip(player: $0) }
                        }
                    }
                    .frame(height: 44)
                }
            }
            .background(
                np.artworkColor.opacity(0.14).blur(radius: 50).offset(x: -150)
            )
        } else {
            EmptyState(symbol: "music.note.list", title: "Nothing is playing",
                       subtitle: "Start music or a video in any app — Spotify, Apple Music, YouTube in your browser — and it shows up here.",
                       actionTitle: "Open Music") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            }
        }
    }
}

/// Compact controls for another app that's also playing (or paused) — e.g. Chrome while Safari is active.
private struct OtherPlayerChip: View {
    var player: MediaPlayer
    @State private var hover = false
    private var np: NowPlayingService { .shared }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let art = player.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.white.opacity(0.08) }
                }
                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if let icon = AppInfo.icon(forBundleID: player.id) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14).offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(player.title ?? player.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if np.needsSetup.contains(player.id) {
                    Button { np.showSetup(for: player) } label: {
                        Label("Enable control", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(player.title == nil ? (player.playing ? "Playing" : "Paused") : "\(player.name) · \(player.playing ? "playing" : "paused")")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 170, alignment: .leading)
            Button { np.previous(player) } label: { Image(systemName: "backward.fill").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(PressStyle())
            Button { np.toggle(player) } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                    .frame(width: 22).contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle())
            Button { np.next(player) } label: { Image(systemName: "forward.fill").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.06)))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Show \(player.name)") {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.id).first { app.activate() }
            }
            Button("Pause everything else") { np.pauseOthers(than: player) }
        }
    }
}
