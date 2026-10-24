import AppKit

/// Controls one specific app's playback.
///
/// macOS's MediaRemote only obeys commands for the app it currently considers "now playing";
/// commands aimed at any other app are silently ignored. So for the *other* players we talk to
/// the app itself: native AppleScript for Spotify / Music, and a tiny bit of JavaScript in the
/// page for browsers (needs the browser's "Allow JavaScript from Apple Events" switch once).
enum PerAppMedia {
    enum Action { case play, pause, next, previous }
    enum Outcome { case ok, needsBrowserSetting(String), unsupported }

    private static let nativeApps: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": "Music",
    ]

    private enum Browser { case safari, chromium }
    private static let browsers: [String: Browser] = [
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium, "com.google.Chrome.canary": .chromium, "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium, "com.microsoft.edgemac": .chromium, "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    static func canControl(_ bundleID: String) -> Bool { nativeApps[bundleID] != nil || browsers[bundleID] != nil }

    /// Runs off the main thread; calls back on main.
    /// `title` (the track MediaRemote last reported for this app) is used to find the right browser tab
    /// by its tab title — running JavaScript in every tab is far too slow in Chrome (background tabs hang).
    static func perform(_ action: Action, on bundleID: String, title: String? = nil, completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run(action, bundleID, title)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func run(_ action: Action, _ bundleID: String, _ title: String?) -> Outcome {
        guard let name = AppInfo.name(forBundleID: bundleID) ?? nativeApps[bundleID] else { return .unsupported }
        let appRef = "application id \"\(bundleID)\""
        if nativeApps[bundleID] != nil {
            let verb: String = switch action {
            case .play: "play"
            case .pause: "pause"
            case .next: "next track"
            case .previous: "previous track"
            }
            return osa("tell \(appRef) to \(verb)").ok ? .ok : .unsupported
        }
        guard let kind = browsers[bundleID] else { return .unsupported }
        let js: String
        switch action {
        case .pause:
            // Pause everything audible and remember it, so "play" can resume exactly that.
            js = "(function(){var n=0;document.querySelectorAll('video,audio').forEach(function(m){if(!m.paused){m.dataset.mnPaused=Date.now();m.pause();n++}});return n})()"
        case .play:
            js = "(function(){var all=[].slice.call(document.querySelectorAll('video,audio'));var m=all.filter(function(x){return x.dataset.mnPaused}).sort(function(a,b){return b.dataset.mnPaused-a.dataset.mnPaused})[0]||all.filter(function(x){return x.currentTime>0&&x.paused})[0];if(!m)return 0;delete m.dataset.mnPaused;m.play();return 1})()"
        case .next, .previous:
            // Media Session handlers (YouTube, Spotify Web…) via synthetic keys aren't scriptable; seek ±10 s instead.
            js = "(function(){var m=[].slice.call(document.querySelectorAll('video,audio')).filter(function(x){return x.currentTime>0})[0];if(!m)return 0;m.currentTime+=\(action == .next ? 10 : -10);return 1})()"
        }
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // Match the tab by title (fast, no page access). Fallback: each window's front tab.
        let needle = String((title ?? "").prefix(40))
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let titleProp = kind == .safari ? "name" : "title"
        let activeTab = kind == .safari ? "current tab" : "active tab"
        let runIn: (String) -> String = { tab in
            kind == .safari ? "do JavaScript \"\(escaped)\" in \(tab)" : "execute \(tab) javascript \"\(escaped)\""
        }
        let script = """
        tell \(appRef)
          set hit to missing value
          if "\(needle)" is not "" then
            repeat with w in windows
              repeat with t in tabs of w
                if (\(titleProp) of t) contains "\(needle)" then
                  set hit to t
                  exit repeat
                end if
              end repeat
              if hit is not missing value then exit repeat
            end repeat
          end if
          if hit is not missing value then
            \(runIn("hit"))
            return 1
          end if
          repeat with w in windows
            set r to \(runIn("(\(activeTab) of w)"))
            if r is not missing value and r as number > 0 then return 1
          end repeat
        end tell
        return 0
        """
        let r = osa(script)
        if r.ok { return .ok }
        let e = r.error.lowercased()
        if e.contains("javascript") || e.contains("apple events") { return .needsBrowserSetting(name) }
        return .unsupported
    }

    private static func osa(_ source: String) -> (ok: Bool, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "\(error)") }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return (false, "timeout") }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0, msg)
    }

    /// Harmless check: can we run JavaScript in this browser? (.unsupported for non-browsers.)
    static func probe(_ bundleID: String, completion: @escaping (Outcome) -> Void) {
        guard let kind = browsers[bundleID] else { completion(.unsupported); return }
        DispatchQueue.global(qos: .utility).async {
            let app = "application id \"\(bundleID)\""
            let src = kind == .safari
                ? "tell \(app) to do JavaScript \"1\" in current tab of front window"
                : "tell \(app) to execute active tab of front window javascript \"1\""
            let r = osa(src)
            let name = AppInfo.name(forBundleID: bundleID) ?? bundleID
            let e = r.error.lowercased()
            let outcome: Outcome = r.ok ? .ok : ((e.contains("javascript") || e.contains("apple events")) ? .needsBrowserSetting(name) : .unsupported)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Where the one-time browser switch lives.
    static func settingHint(for app: String) -> String {
        app.contains("Safari")
            ? "Safari › Settings › Advanced › show Develop menu, then Develop › Allow JavaScript from Apple Events"
            : "\(app) › View › Developer › Allow JavaScript from Apple Events"
    }
}
