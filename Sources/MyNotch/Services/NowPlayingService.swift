import AppKit
import SwiftUI
import Observation

/// One app with a media session (Safari tab, Chrome video, Spotify…).
struct MediaPlayer: Identifiable, Equatable {
    var id: String            // app bundle id
    var name: String
    var playing: Bool
    var title: String?
    var artist: String?
    var artwork: NSImage?
    static func == (a: MediaPlayer, b: MediaPlayer) -> Bool {
        a.id == b.id && a.playing == b.playing && a.title == b.title && a.artist == b.artist && a.artwork === b.artwork
    }
}

/// Now Playing for every app (Spotify, Music, browsers, …) via the MediaRemote bridge
/// hosted inside /usr/bin/perl — see Bridge/MediaBridge.m for why.
@Observable
final class NowPlayingService {
    static let shared = NowPlayingService()

    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var timestamp: Date = Date()
    var rate: Double = 0
    var isPlaying = false
    var artwork: NSImage?
    var artworkColor: Color = .white
    var bundleID: String?
    var appName: String?
    var appIcon: NSImage?
    var available = true
    /// Every app that currently has a media session — lets you control Safari and Chrome separately.
    var players: [MediaPlayer] = []
    /// Last track seen per app (MediaRemote only reports details for the frontmost player).
    @ObservationIgnored private var lastPlayingIDs = Set<String>()
    /// Browsers whose "Allow JavaScript from Apple Events" switch is off (chips show a fix-it button).
    var needsSetup = Set<String>()
    @ObservationIgnored private var probed = Set<String>()
    /// Apps we just sent a command to; their reported state lags, so keep the optimistic value briefly.
    @ObservationIgnored private var recentCommand: [String: Date] = [:]
    @ObservationIgnored private var snapshots: [String: (title: String, artist: String, art: NSImage?)] = [:]

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var lastTitleKey = ""
    @ObservationIgnored private let parseQueue = DispatchQueue(label: "mynotch.media.parse", qos: .userInitiated)

    var hasMedia: Bool { !title.isEmpty }

    /// Elapsed time extrapolated from the last report.
    func position(at now: Date = Date()) -> Double {
        guard duration > 0 else { return elapsed }
        let p = isPlaying ? elapsed + now.timeIntervalSince(timestamp) * max(rate, 1) : elapsed
        return min(max(0, p), duration)
    }

    static var bridgePath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("libMediaBridge.dylib").path,
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("bridge/libMediaBridge.dylib").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static let script = """
    use strict; use DynaLoader;
    my $path = shift @ARGV or die "missing bridge";
    my $lib = DynaLoader::dl_load_file($path, 0) or die "load failed";
    my $sym = DynaLoader::dl_find_symbol($lib, "mn_stream") or die "symbol missing";
    DynaLoader::dl_install_xsub("main::mn_stream", $sym);
    mn_stream();
    """

    func start() {
        guard process == nil else { return }
        guard let bridge = Self.bridgePath else { available = false; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.script, bridge]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.parseQueue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.input = nil
                self.restarts += 1
                guard self.restarts < 20 else { self.available = false; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + min(30, Double(self.restarts) * 2)) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            available = false
        }
    }

    func stop() {
        process?.terminationHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["type"] as? String == "state" { handle(obj) }
            if obj["type"] as? String == "clients", let list = obj["list"] as? [[String: Any]] { handleClients(list) }
            if obj["type"] as? String == "hello" { DispatchQueue.main.async { self.restarts = 0; self.available = true } }
        }
    }

    private func handle(_ o: [String: Any]) {
        var art: NSImage?? = nil  // nil = unchanged, .some(nil) = cleared
        if let b64 = o["artwork"] as? String {
            art = .some(b64.isEmpty ? nil : Data(base64Encoded: b64).flatMap(NSImage.init(data:)))
        }
        let color = art.flatMap { $0?.averageColor }
        let pid = (o["pid"] as? NSNumber)?.int32Value ?? 0
        let bundle = (o["parentBundle"] as? String) ?? (o["bundle"] as? String)

        DispatchQueue.main.async {
            let title = o["title"] as? String ?? ""
            let artist = o["artist"] as? String ?? ""
            let playing = (o["playing"] as? NSNumber)?.boolValue ?? false
            self.title = title
            self.artist = artist
            self.album = o["album"] as? String ?? ""
            self.duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
            self.elapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
            self.timestamp = (o["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
            self.rate = (o["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
            withAnimation(.easeInOut(duration: 0.25)) { self.isPlaying = playing && !title.isEmpty }
            if let art {
                withAnimation(.easeInOut(duration: 0.3)) { self.artwork = art }
                if let color { self.artworkColor = Color(nsColor: color) } else if art == nil { self.artworkColor = .white }
            }
            let previousApp = self.bundleID
            self.resolveApp(pid: pid, bundle: bundle)
            if previousApp != nil, previousApp != self.bundleID, art == nil {
                // Bridge only sends artwork when it changes; force a full resend for the new app.
                self.artwork = nil
                self.send("refresh")
            }
            self.rememberActive()

            let key = "\(title)|\(artist)"
            if playing, !title.isEmpty, key != self.lastTitleKey {
                if !self.lastTitleKey.isEmpty, AppSettings.shared.peekSongChanges, !(NotchManager.shared?.activeVM?.isOpen ?? false) {
                    PeekCenter.shared.post(Peek(symbol: "music.note", image: self.artwork, tint: self.artworkColor,
                                                title: title, subtitle: artist.isEmpty ? self.appName : artist,
                                                tool: .media, duration: 3, short: title))
                }
                self.lastTitleKey = key
            }
        }
    }

    private func handleClients(_ list: [[String: Any]]) {
        DispatchQueue.main.async {
            let next: [MediaPlayer] = list.compactMap { e in
                guard let id = e["id"] as? String else { return nil }
                let snap = self.snapshots[id]
                var playing = (e["state"] as? NSNumber)?.intValue == 1
                if let t = self.recentCommand[id], Date().timeIntervalSince(t) < 2.5,
                   let current = self.players.first(where: { $0.id == id }) { playing = current.playing }
                return MediaPlayer(id: id, name: AppInfo.name(forBundleID: id) ?? id,
                                   playing: playing,
                                   title: snap?.title, artist: snap?.artist, artwork: snap?.art)
            }
            if next != self.players { withAnimation(.easeInOut(duration: 0.2)) { self.players = next } }
            // Check each newly seen browser once so the chip can offer "Enable control" up front.
            for p in next where !self.probed.contains(p.id) && PerAppMedia.canControl(p.id) {
                self.probed.insert(p.id)
                PerAppMedia.probe(p.id) { outcome in
                    if case .needsBrowserSetting = outcome { self.needsSetup.insert(p.id) } else { self.needsSetup.remove(p.id) }
                }
            }
            // One player at a time: when an app starts playing (from the notch or in the app itself), pause the rest.
            let playing = Set(next.filter(\.playing).map(\.id))
            let started = playing.subtracting(self.lastPlayingIDs)
            self.lastPlayingIDs = playing
            if AppSettings.shared.exclusivePlayback, let newest = started.first, playing.count > 1 {
                for id in playing where id != newest { self.control(.pause, id) }
                self.lastPlayingIDs = [newest]
            }
        }
    }

    /// Remembers the active player's track so it still shows after another app takes over.
    private func rememberActive() {
        guard let id = bundleID, !title.isEmpty else { return }
        snapshots[id] = (title, artist, artwork)
        if let i = players.firstIndex(where: { $0.id == id }) {
            players[i].title = title; players[i].artist = artist; players[i].artwork = artwork; players[i].playing = isPlaying
        }
    }

    private func resolveApp(pid: pid_t, bundle: String?) {
        if let bundle, bundle == bundleID, appIcon != nil { return }
        var app: NSRunningApplication?
        if let bundle { app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }
        if app == nil, pid > 0 { app = NSRunningApplication(processIdentifier: pid) }
        bundleID = bundle ?? app?.bundleIdentifier
        appName = app?.localizedName ?? AppInfo.name(forBundleID: bundleID)
        appIcon = app?.icon ?? AppInfo.icon(forBundleID: bundleID)
    }

    // MARK: Commands

    private func send(_ cmd: String) {
        guard let input, let d = (cmd + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: d)
    }

    func togglePlayPause() {
        if !isPlaying, AppSettings.shared.exclusivePlayback, let id = bundleID {
            for p in players where p.id != id && p.playing { control(.pause, p.id) }
            lastPlayingIDs = [id]
        }
        isPlaying.toggle()
        if !isPlaying { elapsed = position(); timestamp = Date() } else { timestamp = Date() }
        send("toggle")
    }
    func next() { send("next") }

    // Controls for one specific app (see PerAppMedia for why the active app is handled differently).
    func toggle(_ player: MediaPlayer) {
        guard let i = players.firstIndex(where: { $0.id == player.id }) else { return }
        let start = !players[i].playing
        if start && AppSettings.shared.exclusivePlayback {
            for p in players where p.id != player.id && p.playing { control(.pause, p.id) }
            for j in players.indices where j != i { players[j].playing = false }
            lastPlayingIDs = [player.id]
        }
        players[i].playing = start
        control(start ? .play : .pause, player.id)
    }
    func next(_ player: MediaPlayer) { control(.next, player.id) }
    func previous(_ player: MediaPlayer) { control(.previous, player.id) }

    /// The "now playing" app obeys MediaRemote; every other app is driven through PerAppMedia.
    private func control(_ action: PerAppMedia.Action, _ id: String) {
        recentCommand[id] = Date()
        if id == bundleID {
            switch action {
            case .play: isPlaying = true; timestamp = Date(); send("play")
            case .pause: elapsed = position(); timestamp = Date(); isPlaying = false; send("pause")
            case .next: send("next")
            case .previous: send("prev")
            }
            return
        }
        PerAppMedia.perform(action, on: id, title: players.first { $0.id == id }?.title ?? snapshots[id]?.title) { outcome in
            switch outcome {
            case .ok:
                self.needsSetup.remove(id)
            case .needsBrowserSetting(let app):
                self.needsSetup.insert(id)
                if let i = self.players.firstIndex(where: { $0.id == id }) { self.players[i].playing.toggle() }  // undo optimistic flip
                PeekCenter.shared.post(Peek(symbol: "exclamationmark.circle.fill", tint: .orange,
                                            title: "Allow MyNotch to control \(app)",
                                            subtitle: PerAppMedia.settingHint(for: app), tool: .media, duration: 9, short: "Allow access"))
            case .unsupported:
                PeekCenter.shared.post(Peek(symbol: "speaker.slash.fill", tint: .orange,
                                            title: "Can't control \(AppInfo.name(forBundleID: id) ?? id) from here",
                                            subtitle: "Switch to it and use its own controls", duration: 4, short: "Can\'t control"))
            }
        }
    }
    /// Walks the user through the one-time browser switch.
    func showSetup(for player: MediaPlayer) {
        NotchManager.shared?.presentDialog(reopen: .media) {
            let a = NSAlert()
            a.messageText = "Let MyNotch control \(player.name)"
            a.informativeText = "macOS only lets apps control the player that's currently in charge. To control \(player.name) from the notch while something else plays, turn on one setting:\n\n\(PerAppMedia.settingHint(for: player.name))\n\nYou only need to do this once."
            a.addButton(withTitle: "Open \(player.name)")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.id).first {
                app.activate()
            }
        }
    }

    func pauseOthers(than player: MediaPlayer) {
        for p in players where p.id != player.id && p.playing { control(.pause, p.id) }
    }
    func previous() { send("prev") }
    func seek(to seconds: Double) {
        elapsed = seconds
        timestamp = Date()
        send("seek \(seconds)")
    }

    func openPlayer() {
        guard let bundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
