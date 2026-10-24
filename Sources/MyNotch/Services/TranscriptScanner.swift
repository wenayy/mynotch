import Foundation

// Fast, incremental readers for the JSONL transcripts Claude Code and Codex write to disk.
// Files can total hundreds of MB, so instead of JSON-decoding every line we memory-map
// each file, only look at lines that can carry usage, and pull out the few fields we need
// with byte searches. Each file remembers how far it has been read, so later refreshes
// only parse newly appended lines.

// MARK: - Byte helpers

struct ByteLine {
    let base: UnsafePointer<UInt8>
    let count: Int

    func find(_ needle: [UInt8], from start: Int = 0) -> Int? {
        guard start < count else { return nil }
        return needle.withUnsafeBufferPointer { n -> Int? in
            guard let r = memmem(base + start, count - start, n.baseAddress!, n.count) else { return nil }
            return base.distance(to: r.assumingMemoryBound(to: UInt8.self))
        }
    }

    func contains(_ needle: [UInt8]) -> Bool { find(needle) != nil }

    func findLast(_ needle: [UInt8]) -> Int? {
        var last: Int?
        var from = 0
        while let i = find(needle, from: from) {
            last = i
            from = i + 1
        }
        return last
    }

    func occurrences(_ needle: [UInt8]) -> Int {
        var n = 0, from = 0
        while let i = find(needle, from: from) { n += 1; from = i + needle.count }
        return n
    }

    /// Reads the JSON string that starts right after `needle` (which must end with an opening quote).
    func string(at index: Int?, needleLength: Int) -> String? {
        guard let index else { return nil }
        let start = index + needleLength
        var i = start
        while i < count {
            let c = base[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == UInt8(ascii: "\"") { break }
            i += 1
        }
        guard i <= count, i > start else { return i == start ? "" : nil }
        let raw = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
        return raw.contains("\\") ? raw.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\\", with: "\\") : raw
    }

    func firstString(_ key: [UInt8]) -> String? { string(at: find(key), needleLength: key.count) }
    func lastString(_ key: [UInt8]) -> String? { string(at: findLast(key), needleLength: key.count) }

    /// Reads an integer right after `key` (e.g. `"output_tokens":`), searching from `start`.
    func int(after key: [UInt8], from start: Int, within limit: Int = 2000) -> Int {
        guard let i = find(key, from: start), i - start < limit else { return 0 }
        var j = i + key.count
        while j < count, base[j] == UInt8(ascii: " ") { j += 1 }
        var v = 0
        while j < count, base[j] >= 48, base[j] <= 57 {
            v = v &* 10 &+ Int(base[j] - 48)
            j += 1
        }
        return v
    }

    /// Parses `"YYYY-MM-DDTHH:MM:SS(.fff)Z"` at the given position into a UNIX time.
    func isoTime(at index: Int?, needleLength: Int) -> Double? {
        guard let index else { return nil }
        let s = index + needleLength
        guard s + 19 <= count else { return nil }
        func num(_ o: Int, _ len: Int) -> Int32 {
            var v: Int32 = 0
            for k in 0..<len {
                let c = base[s + o + k]
                guard c >= 48 && c <= 57 else { return -1 }
                v = v * 10 + Int32(c - 48)
            }
            return v
        }
        var t = tm()
        t.tm_year = num(0, 4) - 1900
        t.tm_mon = num(5, 2) - 1
        t.tm_mday = num(8, 2)
        t.tm_hour = num(11, 2)
        t.tm_min = num(14, 2)
        t.tm_sec = num(17, 2)
        guard t.tm_year > 70, t.tm_mon >= 0, t.tm_mday > 0 else { return nil }
        var frac = 0.0
        var i = s + 19
        if i < count, base[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < count, base[i] >= 48, base[i] <= 57 { frac += Double(base[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < count, base[i] == UInt8(ascii: "+") || base[i] == UInt8(ascii: "-"), i + 5 < count {
            let sign = base[i] == UInt8(ascii: "+") ? 1 : -1
            let hh = Int(base[i + 1] - 48) * 10 + Int(base[i + 2] - 48)
            let mm = Int(base[i + 4] - 48) * 10 + Int(base[i + 5] - 48)
            offset = sign * (hh * 3600 + mm * 60)
        }
        return Double(timegm(&t)) + frac - Double(offset)
    }
}

/// Memory-maps a file and calls `body` for each complete line starting at `offset`.
/// Returns the offset just past the last complete line.
func forEachLine(in url: URL, from offset: Int, _ body: (ByteLine) -> Void) -> Int {
    guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return offset }
    guard data.count > offset else { return min(offset, data.count) }
    return data.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return offset }
        var pos = offset
        let end = data.count
        while pos < end {
            guard let nl = memchr(base + pos, 0x0A, end - pos) else { break }
            let lineEnd = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
            if lineEnd > pos { body(ByteLine(base: base + pos, count: lineEnd - pos)) }
            pos = lineEnd + 1
        }
        return pos
    }
}

/// Days since 1970 in the local time zone (cheap to compute for many entries).
enum LocalDay {
    static var tzOffset: Double { Double(TimeZone.current.secondsFromGMT()) }
    static func index(_ t: Double, offset: Double = tzOffset) -> Int { Int(((t + offset) / 86400).rounded(.down)) }
    static var today: Int { index(Date().timeIntervalSince1970) }
    static func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86400 - tzOffset + 43200) }
}

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

private struct FileCursor {
    var offset = 0
    var size = 0
    var mtime = Date.distantPast
}

private func listJSONL(roots: [URL], modifiedAfter cutoff: Date) -> [(URL, Int, Date)] {
    var out: [(URL, Int, Date)] = []
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    for root in roots where FileManager.default.fileExists(atPath: root.path) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            out.append((url, v.fileSize ?? 0, m))
        }
    }
    return out.sorted { $0.2 < $1.2 }
}

// MARK: - Claude Code

final class ClaudeTranscriptIndex {
    struct Entry {
        var time: Double
        var day: Int32
        var model: Int16
        var project: Int32
        var session: Int32
        var tokens: TokenBreakdown
        var tools: Int16
    }

    private(set) var models: [String] = []
    private(set) var projects: [String] = []
    private var modelIndex: [String: Int16] = [:]
    private var projectIndex: [String: Int32] = [:]
    private var sessionIndex: [String: Int32] = [:]

    private var cursors: [String: FileCursor] = [:]
    private var entriesByFile: [String: [Entry]] = [:]
    private var seen = Set<Int>()

    static var roots: [URL] {
        var r = [Paths.home.appendingPathComponent(".claude/projects"),
                 Paths.home.appendingPathComponent(".config/claude/projects")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return r
    }

    private static let kAssistant = bytes("\"type\":\"assistant\"")
    private static let kUsage = bytes("\"usage\":{")
    private static let kInput = bytes("\"input_tokens\":")
    private static let kOutput = bytes("\"output_tokens\":")
    private static let kCacheW = bytes("\"cache_creation_input_tokens\":")
    private static let kCacheR = bytes("\"cache_read_input_tokens\":")
    private static let kModel = bytes("\"model\":\"")
    private static let kMsgID = bytes("\"id\":\"msg_")
    private static let kReqID = bytes("\"requestId\":\"")
    private static let kTime = bytes("\"timestamp\":\"")
    private static let kCwd = bytes("\"cwd\":\"")
    private static let kSession = bytes("\"sessionId\":\"")
    private static let kToolUse = bytes("\"type\":\"tool_use\"")

    /// Scans new data; returns all entries within the window.
    func refresh(days: Int) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-Double(days + 1) * 86400)
        let files = listJSONL(roots: Self.roots, modifiedAfter: cutoff)
        // A shrunk file means it was rewritten — start over to keep de-duplication honest.
        if files.contains(where: { (cursors[$0.0.path]?.size ?? 0) > $0.1 }) { reset() }
        let tz = LocalDay.tzOffset

        for (url, size, mtime) in files {
            let path = url.path
            var cursor = cursors[path] ?? FileCursor()
            guard size != cursor.size || mtime != cursor.mtime else { continue }
            var list = entriesByFile[path] ?? []
            let fallbackProject = Self.projectName(fromFolder: url.deletingLastPathComponent().lastPathComponent)

            let startOffset = cursor.offset
            let newOffset = forEachLine(in: url, from: startOffset) { line in
                guard line.contains(Self.kAssistant), let u = line.findLast(Self.kUsage) else { return }
                let model = line.firstString(Self.kModel) ?? "unknown"
                if model.hasPrefix("<") { return }              // synthetic messages carry no usage
                let tools = line.occurrences(Self.kToolUse)
                let msg = line.string(at: line.find(Self.kMsgID), needleLength: Self.kMsgID.count - 4) ?? ""
                let req = line.lastString(Self.kReqID) ?? ""
                if !msg.isEmpty || !req.isEmpty {
                    var h = Hasher(); h.combine(msg); h.combine(req)
                    if !seen.insert(h.finalize()).inserted {
                        // Same message streamed as several content blocks: count tool calls only.
                        if tools > 0, var last = list.popLast() {
                            last.tools &+= Int16(tools)
                            list.append(last)
                        }
                        return
                    }
                }
                guard let t = line.isoTime(at: line.findLast(Self.kTime), needleLength: Self.kTime.count) else { return }
                let tokens = TokenBreakdown(input: line.int(after: Self.kInput, from: u),
                                            output: line.int(after: Self.kOutput, from: u),
                                            cacheWrite: line.int(after: Self.kCacheW, from: u),
                                            cacheRead: line.int(after: Self.kCacheR, from: u))
                let cwd = line.lastString(Self.kCwd)
                let project = cwd.map { ($0 as NSString).lastPathComponent } ?? fallbackProject
                let session = line.lastString(Self.kSession) ?? path
                list.append(Entry(time: t, day: Int32(LocalDay.index(t, offset: tz)),
                                  model: intern(model: model), project: intern(project: project),
                                  session: intern(session: session), tokens: tokens, tools: Int16(clamping: tools)))
            }
            cursor.offset = newOffset
            cursor.size = size
            cursor.mtime = mtime
            cursors[path] = cursor
            entriesByFile[path] = list
        }

        let minTime = cutoff.timeIntervalSince1970
        return entriesByFile.values.flatMap { $0 }.filter { $0.time >= minTime }
    }

    func reset() {
        cursors.removeAll(); entriesByFile.removeAll(); seen.removeAll()
    }

    private func intern(model: String) -> Int16 {
        if let i = modelIndex[model] { return i }
        let i = Int16(models.count); models.append(model); modelIndex[model] = i; return i
    }
    private func intern(project: String) -> Int32 {
        if let i = projectIndex[project] { return i }
        let i = Int32(projects.count); projects.append(project); projectIndex[project] = i; return i
    }
    private func intern(session: String) -> Int32 {
        if let i = sessionIndex[session] { return i }
        let i = Int32(sessionIndex.count); sessionIndex[session] = i; return i
    }

    /// "-Users-me-Desktop-my-app" → "my-app" (best effort; real cwd wins when present).
    static func projectName(fromFolder folder: String) -> String {
        let parts = folder.split(separator: "-")
        return parts.last.map(String.init) ?? folder
    }
}

// MARK: - Codex

final class CodexTranscriptIndex {
    struct Entry {
        var time: Double
        var day: Int32
        var tokens: Int
        var output: Int
        var project: Int32
    }

    struct LatestLimits {
        var json: [String: Any]
        var time: Double
    }

    private struct State {
        var cursor = FileCursor()
        var lastTotal = 0
        var lastOutput = 0
        var project: Int32 = -1
        var entries: [Entry] = []
        var lastActivity: Double = 0
    }

    private var files: [String: State] = [:]
    private(set) var projects: [String] = []
    private var projectIndex: [String: Int32] = [:]
    private(set) var latestLimits: LatestLimits?

    static var roots: [URL] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Paths.home.appendingPathComponent(".codex")
        return [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
    }

    private static let kTokenCount = bytes("\"type\":\"token_count\"")
    private static let kTotalUsage = bytes("\"total_token_usage\":{")
    private static let kTotal = bytes("\"total_tokens\":")
    private static let kOutput = bytes("\"output_tokens\":")
    private static let kTime = bytes("\"timestamp\":\"")
    private static let kMeta = bytes("\"type\":\"session_meta\"")
    private static let kTurnContext = bytes("\"type\":\"turn_context\"")
    private static let kCwd = bytes("\"cwd\":\"")
    private static let kRateLimits = bytes("\"rate_limits\":{")

    struct Result {
        var entries: [Entry]
        var active: [(project: String, lastActivity: Date, path: String)]
    }

    func refresh(days: Int) -> Result {
        let cutoff = Date().addingTimeInterval(-Double(days + 1) * 86400)
        let list = listJSONL(roots: Self.roots, modifiedAfter: cutoff)
        let tz = LocalDay.tzOffset
        for (url, size, mtime) in list {
            let path = url.path
            var st = files[path] ?? State()
            if st.cursor.size > size { st = State() }
            guard size != st.cursor.size || mtime != st.cursor.mtime else { continue }
            let startOffset = st.cursor.offset
            let newOffset = forEachLine(in: url, from: startOffset) { line in
                if st.project < 0, line.contains(Self.kMeta) || line.contains(Self.kTurnContext),
                   let cwd = line.firstString(Self.kCwd) {
                    st.project = intern((cwd as NSString).lastPathComponent)
                }
                guard line.contains(Self.kTokenCount),
                      let t = line.isoTime(at: line.find(Self.kTime), needleLength: Self.kTime.count) else { return }
                st.lastActivity = max(st.lastActivity, t)
                if let u = line.find(Self.kTotalUsage) {
                    let total = line.int(after: Self.kTotal, from: u)
                    let out = line.int(after: Self.kOutput, from: u)
                    // Totals are cumulative per thread; a drop means a fresh context.
                    let delta = total >= st.lastTotal ? total - st.lastTotal : total
                    let outDelta = out >= st.lastOutput ? out - st.lastOutput : out
                    st.lastTotal = total
                    st.lastOutput = out
                    if delta > 0 {
                        st.entries.append(Entry(time: t, day: Int32(LocalDay.index(t, offset: tz)),
                                                tokens: delta, output: outDelta, project: st.project))
                    }
                }
                if line.find(Self.kRateLimits) != nil, t >= (latestLimits?.time ?? 0),
                   let obj = try? JSONSerialization.jsonObject(with: Data(bytes: line.base, count: line.count)) as? [String: Any],
                   let payload = obj["payload"] as? [String: Any],
                   let limits = payload["rate_limits"] as? [String: Any],
                   (limits["primary"] as? [String: Any]) != nil || (limits["secondary"] as? [String: Any]) != nil {
                    latestLimits = LatestLimits(json: limits, time: t)
                }
            }
            st.cursor.offset = newOffset
            st.cursor.size = size
            st.cursor.mtime = mtime
            files[path] = st
        }
        let minTime = cutoff.timeIntervalSince1970
        let entries = files.values.flatMap { $0.entries }.filter { $0.time >= minTime }
        let now = Date().timeIntervalSince1970
        let active = files.compactMap { path, st -> (String, Date, String)? in
            guard now - st.lastActivity < 45 else { return nil }
            let name = st.project >= 0 ? projects[Int(st.project)] : "Codex"
            return (name, Date(timeIntervalSince1970: st.lastActivity), path)
        }
        return Result(entries: entries, active: active.map { (project: $0.0, lastActivity: $0.1, path: $0.2) })
    }

    func projectName(_ i: Int32) -> String { i >= 0 && Int(i) < projects.count ? projects[Int(i)] : "Other" }

    private func intern(_ p: String) -> Int32 {
        if let i = projectIndex[p] { return i }
        let i = Int32(projects.count); projects.append(p); projectIndex[p] = i; return i
    }
}
