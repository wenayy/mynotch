import AppKit
import SwiftUI
import Observation
import IOKit
import IOKit.ps
import Darwin

@Observable
final class SystemStats {
    static let shared = SystemStats()

    var cpu: Double = 0
    var memoryUsed: Double = 0
    var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var netDown: Double = 0
    var netUp: Double = 0
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    var batteryPercent: Int?
    var charging = false
    var pluggedIn = false
    var timeRemaining: Int?          // minutes
    var cycleCount: Int?
    var health: Int?                 // %
    var temperature: Double?
    var chargingBanner = false

    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var fastTimer: Timer?
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private var prevCPU: host_cpu_load_info?
    @ObservationIgnored private var prevNet: (rx: UInt64, tx: UInt64, t: Date)?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var bannerWork: DispatchWorkItem?
    @ObservationIgnored private var lowAlerted: Int?

    // MARK: High CPU / memory alerts

    @ObservationIgnored private var highCPUSince: Date?
    @ObservationIgnored private var lastAlert: [String: Date] = [:]

    private func watchResources() {
        guard AppSettings.shared.resourceAlerts else { return }
        if fastTimer == nil { readCPU(); readMemory() }   // the System tab samples on its own while visible
        let now = Date()
        if cpu > 0.85 { highCPUSince = highCPUSince ?? now } else { highCPUSince = nil }
        if let since = highCPUSince, now.timeIntervalSince(since) >= 30 { alert("cpu", "CPU at \(Int(cpu * 100))%") }
        if memoryFraction > 0.92 { alert("mem", "Memory at \(Int(memoryFraction * 100))%") }
    }

    /// Names the biggest offender (via ps, off the main thread); at most one alert per kind every 15 min.
    private func alert(_ kind: String, _ title: String) {
        if let last = lastAlert[kind], Date().timeIntervalSince(last) < 900 { return }
        lastAlert[kind] = Date()
        DispatchQueue.global(qos: .utility).async {
            let col = kind == "cpu" ? "pcpu" : "rss"
            let out = Shell.run("/bin/ps", ["-Aceo", "\(col)=,comm=", "-r"], timeout: 3).out
            let top = out.split(separator: "\n").first.map { line -> String in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return "" }
                if kind == "cpu" { return "\(parts[1]) using \(parts[0])%" }
                return "\(parts[1]) using \(Fmt.bytes((Int64(parts[0]) ?? 0) * 1024))"
            } ?? ""
            DispatchQueue.main.async {
                PeekCenter.shared.post(Peek(symbol: kind == "cpu" ? "cpu.fill" : "memorychip.fill", tint: .orange,
                                            title: title, subtitle: top.isEmpty ? nil : top, tool: .stats,
                                            duration: 5, style: .warning))
            }
        }
    }

    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    var diskFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }

    func start() {
        readBattery(initial: true)
        readDisk()
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.readBattery(initial: false); self?.readDisk()
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.watchResources() }
        // Power source change notifications (plug / unplug) without polling.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemStats>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.readBattery(initial: false) }
        }, ctx)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
        }
    }

    /// Views showing live stats call this on appear/disappear so we only sample while visible.
    func attach() {
        consumers += 1
        guard fastTimer == nil else { return }
        sample()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.sample() }
    }

    func detach() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { fastTimer?.invalidate(); fastTimer = nil }
    }

    private func sample() {
        readCPU()
        readMemory()
        readNetwork()
        thermal = ProcessInfo.processInfo.thermalState
    }

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        if let p = prevCPU {
            let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
            let sys = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
            let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
            let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
            let total = user + sys + idle + nice
            if total > 0 { cpu = (user + sys + nice) / total }
        }
        prevCPU = info
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        memoryUsed = used
    }

    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
    }

    private func readNetwork() {
        // 64-bit counters via NET_RT_IFLIST2 (getifaddrs' if_data wraps at 4 GB).
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return }
        var rx: UInt64 = 0, tx: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        rx &+= h2.ifm_data.ifi_ibytes
                        tx &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.t)
            if dt > 0 {
                // Counters are 32-bit on some interfaces and rounded to 1 KB for privacy:
                // handle wrap-around and smooth over a few samples.
                func delta(_ a: UInt64, _ b: UInt64) -> Double {
                    b >= a ? Double(b - a) : (a < 1 << 32 ? Double((1 << 32) - a + b) : 0)
                }
                netDown = netDown * 0.5 + delta(prev.rx, rx) / dt * 0.5
                netUp = netUp * 0.5 + delta(prev.tx, tx) / dt * 0.5
            }
        }
        prevNet = (rx, tx, now)
    }

    private func readBattery(initial: Bool) {
        let wasPlugged = pluggedIn
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                let cap = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                batteryPercent = max > 0 ? Int((Double(cap) / Double(max) * 100).rounded()) : cap
                charging = d[kIOPSIsChargingKey] as? Bool ?? false
                pluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let ttl = charging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
                timeRemaining = (ttl ?? -1) > 0 ? ttl : nil
            }
        }
        // Health and cycles come from the SMC battery service.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            func prop(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            cycleCount = prop("CycleCount")
            if let design = prop("DesignCapacity"), design > 0, let raw = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity") {
                health = min(100, Int((Double(raw) / Double(design) * 100).rounded()))
            }
            if let t = prop("Temperature") { temperature = Double(t) / 100 }
            IOObjectRelease(service)
        }
        if !initial, pluggedIn, !wasPlugged {
            bannerWork?.cancel()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { chargingBanner = true }
            let w = DispatchWorkItem { [weak self] in withAnimation(.easeInOut(duration: 0.3)) { self?.chargingBanner = false } }
            bannerWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
            if AppSettings.shared.playSounds { NSSound(named: "Pop")?.play() }
        }
        if pluggedIn { lowAlerted = nil }
        if !initial, let p = batteryPercent, !pluggedIn, p == 20 || p == 10, lowAlerted != p {
            lowAlerted = p
            PeekCenter.shared.post(Peek(symbol: "battery.25percent", tint: .red, title: "Battery at \(p)%",
                                        subtitle: timeRemaining.map { "About \(Fmt.duration(Double($0) * 60)) left" },
                                        tool: .stats, duration: 5, style: .warning))
        }
    }
}

// MARK: - Screen time (tracked locally from app activations)

@Observable
final class ScreenTime {
    static let shared = ScreenTime()
    struct Day: Codable { var day: Int; var seconds: [String: Double] }   // bundle id → seconds

    var today: [(id: String, seconds: Double)] = []
    var totalToday: Double = 0
    var week: [(day: Int, seconds: Double)] = []

    @ObservationIgnored private var days: [Day] = []
    @ObservationIgnored private var current: (id: String, since: Date)?
    @ObservationIgnored private var timer: Timer?

    func start() {
        days = Store.load([Day].self, from: "screentime.json") ?? []
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { current = (front, Date()) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.switchTo(app?.bundleIdentifier)
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.switchTo(nil) }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.switchTo(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.flush() }
        publish()
    }

    private func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func switchTo(_ id: String?) {
        flush()
        current = id.map { ($0, Date()) }
    }

    private func flush() {
        guard let c = current else { return }
        let now = Date()
        var secs = now.timeIntervalSince(c.since)
        // Don't count time away from the keyboard (> 3 min idle).
        let idle = idleSeconds()
        if idle > 180 { secs = max(0, secs - idle) }
        current = (c.id, now)
        guard secs > 0, secs < 3600 else { return }
        let day = LocalDay.today
        if days.last?.day != day { days.append(Day(day: day, seconds: [:])) }
        days[days.count - 1].seconds[c.id, default: 0] += secs
        if days.count > 30 { days.removeFirst(days.count - 30) }
        Store.save(days, to: "screentime.json")
        publish()
    }

    private func publish() {
        let todayKey = LocalDay.today
        let t = days.first { $0.day == todayKey }?.seconds ?? [:]
        today = t.sorted { $0.value > $1.value }.map { (id: $0.key, seconds: $0.value) }
        totalToday = t.values.reduce(0, +)
        week = (todayKey - 6...todayKey).map { d in (day: d, seconds: days.first { $0.day == d }?.seconds.values.reduce(0, +) ?? 0) }
    }
}
