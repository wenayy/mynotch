import AppKit
import ApplicationServices

/// Menu bar extras (the status icons on the right of the menu bar) of every running app.
/// On notched Macs many of them end up hidden behind the notch; the Apps tool lists them all
/// so their menus are still reachable. Uses Accessibility (same permission as auto-paste).
struct MenuBarExtra: Identifiable {
    let id: String
    let pid: pid_t
    let appName: String
    let label: String
    let icon: NSImage?
    let element: AXUIElement
    let hidden: Bool
}

enum MenuBarExtras {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Apple's own items (clock, Control Center, Wi-Fi…) are always visible; skip them.
    private static let skip: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight",
                                            "com.apple.TextInputMenuAgent", "com.apple.Siri"]

    /// Reads all extras. Call off the main thread (AX calls can block briefly on busy apps).
    static func load(notchRects: [CGRect]) -> [MenuBarExtra] {
        guard trusted else { return [] }
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        var out: [MenuBarExtra] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != getpid(), let bid = app.bundleIdentifier, !skip.contains(bid) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
                  let items = kids as? [AXUIElement] else { continue }
            for (i, item) in items.enumerated() {
                let label = string(item, kAXDescriptionAttribute) ?? string(item, kAXTitleAttribute)
                    ?? string(item, kAXHelpAttribute) ?? app.localizedName ?? bid
                // AX frames are in top-left-origin screen space; convert for the notch check.
                var hidden = false
                if let f = frame(item) {
                    let flipped = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                    hidden = notchRects.contains { $0.intersects(flipped) }
                        || !screens.contains { $0.frame.intersects(flipped) }
                }
                out.append(MenuBarExtra(id: "\(bid)#\(i)", pid: app.processIdentifier, appName: app.localizedName ?? bid,
                                        label: label, icon: app.icon, element: item, hidden: hidden))
            }
        }
        // Hidden ones first — those are the ones you can't reach otherwise.
        return out.sorted { $0.hidden != $1.hidden ? $0.hidden : $0.appName < $1.appName }
    }

    /// Opens the item's menu.
    static func open(_ extra: MenuBarExtra) {
        if AXUIElementPerformAction(extra.element, kAXPressAction as CFString) != .success {
            AXUIElementPerformAction(extra.element, "AXShowMenu" as CFString)
        }
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String,
              !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
