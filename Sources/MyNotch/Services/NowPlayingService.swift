import AppKit
import SwiftUI
import Observation

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
            self.resolveApp(pid: pid, bundle: bundle)

            let key = "\(title)|\(artist)"
            if playing, !title.isEmpty, key != self.lastTitleKey {
                if !self.lastTitleKey.isEmpty, AppSettings.shared.peekSongChanges, !(NotchManager.shared?.activeVM?.isOpen ?? false) {
                    PeekCenter.shared.post(Peek(symbol: "music.note", image: self.artwork, tint: self.artworkColor,
                                                title: title, subtitle: artist.isEmpty ? self.appName : artist,
                                                tool: .media, duration: 3))
                }
                self.lastTitleKey = key
            }
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
        isPlaying.toggle()
        if !isPlaying { elapsed = position(); timestamp = Date() } else { timestamp = Date() }
        send("toggle")
    }
    func next() { send("next") }
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
