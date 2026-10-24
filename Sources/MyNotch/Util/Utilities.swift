import AppKit
import SwiftUI

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MyNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func dir(_ name: String) -> URL {
        let d = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - JSON persistence

enum Store {
    private static let queue = DispatchQueue(label: "mynotch.store", qos: .utility)

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = Paths.appSupport.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(value) else { return }
        let url = Paths.appSupport.appendingPathComponent(name)
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}

/// Coalesces rapid calls (e.g. saving while typing).
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(_ delay: TimeInterval) { self.delay = delay }
    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

// MARK: - Process helper

enum Shell {
    /// Runs a binary synchronously with a timeout. Call off the main thread.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10, env: [String: String]? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var collected = Data()
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); collected.append(d); lock.unlock()
        }
        do { try p.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); collected.append(rest); lock.unlock()
        return (p.terminationStatus, String(decoding: collected, as: UTF8.self))
    }

    /// PATH that includes the usual places CLIs get installed to (GUI apps get a bare PATH).
    static var richPath: String {
        let h = Paths.home.path
        var parts = ["\(h)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(h)/.bun/bin", "\(h)/.npm-global/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let nvm = "\(h)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted().reversed() { parts.insert("\(nvm)/\(v)/bin", at: 1) }
        }
        return parts.joined(separator: ":")
    }

    static func which(_ name: String) -> String? {
        for dir in richPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - Formatting

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
        case 10_000_000...: return String(format: "%.0fM", d / 1_000_000)
        case 1_000_000...: return String(format: "%.1fM", d / 1_000_000)
        case 10_000...: return String(format: "%.0fK", d / 1_000)
        case 1_000...: return String(format: "%.1fK", d / 1_000)
        default: return "\(n)"
        }
    }

    static func duration(_ seconds: TimeInterval, short: Bool = false) -> String {
        let s = max(0, Int(seconds.rounded()))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return short ? "\(d)d" : "\(d)d \(h)h" }
        if h > 0 { return short ? "\(h)h" : "\(h)h \(m)m" }
        if m > 0 { return short ? "\(m)m" : (m < 10 && sec > 0 ? "\(m)m \(sec)s" : "\(m)m") }
        return "\(sec)s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func mediaTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Date().timeIntervalSince(date)
        if s < 10 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        return "\(duration(s, short: true)) ago"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE j:mm"); return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    /// "in 3h 12m" for soon, "Fri 3:29 PM" within a week, "Nov 23" beyond.
    static func reset(_ date: Date?) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSinceNow
        if s <= 0 { return "now" }
        if s < 24 * 3600 { return "in \(duration(s))" }
        if s < 7 * 24 * 3600 { return dayTimeFormatter.string(from: date) }
        return dateFormatter.string(from: date)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return bytesPerSec < 50 ? "idle" : "< 1 KB/s" }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return String(format: "%.1f MB/s", bytesPerSec / 1024 / 1024)
    }

    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }
}

// MARK: - Dates

enum DateParse {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Accepts ISO-8601 with 0–9 fractional digits and any offset.
    static func iso8601(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) ?? iso.date(from: s) { return d }
        // Trim fractional seconds beyond milliseconds (e.g. Python's microseconds).
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let frac = s[s.index(after: dot)..<end]
            let ms = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s = String(s[..<dot]) + "." + ms + String(s[end...])
            return isoFrac.date(from: s)
        }
        return nil
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    static func date(fromDayKey key: Int) -> Date {
        var c = DateComponents()
        c.year = key / 10000; c.month = (key / 100) % 100; c.day = key % 100
        return Calendar.current.date(from: c) ?? Date()
    }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x3DD6B0)
}

extension NSImage {
    /// Average colour, used to tint the visualizer / glow from album art.
    var averageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        // Lift very dark covers so the tint stays visible on black.
        if let hsb = c.usingColorSpace(.deviceRGB) {
            let b = max(hsb.brightnessComponent, 0.65)
            let s = min(hsb.saturationComponent * 1.2, 1)
            c = NSColor(hue: hsb.hueComponent, saturation: s, brightness: b, alpha: 1)
        }
        return c
    }
}

// MARK: - App helpers

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func icon(forBundleID id: String?) -> NSImage? {
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func name(forBundleID id: String?) -> String? {
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Activates the nearest GUI ancestor of a process (e.g. the terminal hosting a CLI).
    @discardableResult
    static func activateHostApp(ofPID pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<24 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                app.activate()
                return true
            }
            let parent = parentPID(of: current)
            if parent <= 1 || parent == current { break }
            current = parent
        }
        return false
    }

    static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Stable hashing (Swift's hashValue is randomly seeded per launch)

enum StableHash {
    static func of<S: Sequence>(_ bytes: S) -> Int where S.Element == UInt8 {
        var h: UInt64 = 1469598103934665603          // FNV-1a
        for b in bytes { h ^= UInt64(b); h = h &* 1099511628211 }
        return Int(truncatingIfNeeded: h)
    }
    static func of(_ s: String) -> Int { of(s.utf8) }
}
