import AppKit
import SwiftUI
import Observation
import CoreAudio
import AudioToolbox
import ApplicationServices

/// Volume & brightness levels shown in the notch.
/// - observe: listens to CoreAudio and polls DisplayServices; the system HUD still appears.
/// - replace: an event tap swallows the media keys (Accessibility permission), applies the
///   change itself and shows only the notch HUD — the approach boring.notch uses.
@Observable
final class HUDService {
    static let shared = HUDService()

    enum Kind { case volume, brightness }
    struct Event: Equatable {
        var kind: Kind
        var level: Double
        var muted: Bool
        var stamp = Date()
    }

    var current: Event?

    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var device: AudioObjectID = 0
    @ObservationIgnored private var volumeBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var brightnessTimer: Timer?
    @ObservationIgnored private var lastBrightness: Float = -1
    @ObservationIgnored private var armedAt = Date()
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var lastVolume: Float = -1

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    @ObservationIgnored private lazy var displayServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    @ObservationIgnored private lazy var getBrightness: GetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetBrightness.self) }
    @ObservationIgnored private lazy var setBrightnessFn: SetBrightness? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetBrightness.self) }

    func apply(_ mode: HUDMode) {
        teardown()
        guard mode != .off else { return }
        armedAt = Date()
        installVolumeListener()
        startBrightnessPolling(interval: mode == .replace ? 0.6 : 0.25)
        if mode == .replace { installTapWhenTrusted(prompt: true) }
    }

    private func teardown() {
        if let b = volumeBlock { var a = volumeAddress; AudioObjectRemovePropertyListenerBlock(device, &a, .main, b); var m = muteAddress; AudioObjectRemovePropertyListenerBlock(device, &m, .main, b) }
        if let b = deviceBlock { var a = defaultDeviceAddress; AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b) }
        volumeBlock = nil; deviceBlock = nil
        brightnessTimer?.invalidate(); brightnessTimer = nil
        trustTimer?.invalidate(); trustTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }

    func show(_ kind: Kind, level: Double, muted: Bool = false) {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            current = Event(kind: kind, level: min(1, max(0, level)), muted: muted)
        }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeInOut(duration: 0.25)) { self?.current = nil } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    // MARK: Volume

    private var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                           mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                         mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var defaultDeviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = defaultDeviceAddress
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    var volume: Float {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size), a = volumeAddress
        AudioObjectGetPropertyData(device == 0 ? defaultOutputDevice() : device, &a, 0, nil, &size, &v)
        return v
    }

    var muted: Bool {
        var m = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size), a = muteAddress
        AudioObjectGetPropertyData(device == 0 ? defaultOutputDevice() : device, &a, 0, nil, &size, &m)
        return m != 0
    }

    func setVolume(_ v: Float) {
        var value = min(1, max(0, v))
        var a = volumeAddress
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if value > 0, muted { setMuted(false) }
    }

    func setMuted(_ m: Bool) {
        var value: UInt32 = m ? 1 : 0
        var a = muteAddress
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func installVolumeListener() {
        device = defaultOutputDevice()
        lastVolume = volume
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Date().timeIntervalSince(self.armedAt) > 0.8 else { return }
            let v = self.volume
            let m = self.muted
            if abs(v - self.lastVolume) > 0.001 || m != (self.current?.muted ?? !m) {
                self.lastVolume = v
                self.show(.volume, level: Double(v), muted: m)
            }
        }
        volumeBlock = block
        var a = volumeAddress
        AudioObjectAddPropertyListenerBlock(device, &a, .main, block)
        var m = muteAddress
        AudioObjectAddPropertyListenerBlock(device, &m, .main, block)

        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let mode = AppSettings.shared.hudMode
            self.apply(mode)
        }
        deviceBlock = devBlock
        var d = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &d, .main, devBlock)
    }

    // MARK: Brightness

    var brightness: Float {
        var b: Float = 0
        _ = getBrightness?(CGMainDisplayID(), &b)
        return b
    }

    func setBrightness(_ b: Float) {
        _ = setBrightnessFn?(CGMainDisplayID(), min(1, max(0, b)))
    }

    private func startBrightnessPolling(interval: TimeInterval) {
        guard getBrightness != nil else { return }
        lastBrightness = brightness
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let b = self.brightness
            if self.lastBrightness >= 0, abs(b - self.lastBrightness) > 0.005 {
                self.show(.brightness, level: Double(b))
            }
            self.lastBrightness = b
        }
    }

    // MARK: Replace mode (event tap)

    private func installTapWhenTrusted(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            installTap()
        } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.installTap() }
            }
        }
    }

    private func installTap() {
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, ctx in
            guard let ctx else { return Unmanaged.passUnretained(event) }
            let hud = Unmanaged<HUDService>.fromOpaque(ctx).takeUnretainedValue()
            return hud.handleTap(type: type, event: event)
        }, userInfo: me) else { return }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 144 { DispatchQueue.main.async { self.bumpBrightness(step) }; return nil }
            if code == 145 { DispatchQueue.main.async { self.bumpBrightness(-step) }; return nil }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        switch key {
        case 0, 1, 7, 2, 3:
            if down {
                DispatchQueue.main.async {
                    switch key {
                    case 0: self.setVolume(self.volume + step); self.show(.volume, level: Double(self.volume))
                    case 1: self.setVolume(self.volume - step); self.show(.volume, level: Double(self.volume), muted: self.volume <= 0)
                    case 7: let m = !self.muted; self.setMuted(m); self.show(.volume, level: Double(self.volume), muted: m)
                    case 2: self.bumpBrightness(step)
                    default: self.bumpBrightness(-step)
                    }
                    self.lastVolume = self.volume
                }
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func bumpBrightness(_ delta: Float) {
        let b = min(1, max(0, brightness + delta))
        setBrightness(b)
        lastBrightness = b
        show(.brightness, level: Double(b))
    }
}
