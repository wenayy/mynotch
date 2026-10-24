import AVFoundation
import SwiftUI
import Observation

/// Procedurally generated ambient soundscapes — nothing to download and nothing ever loops.
enum AmbientSound: String, CaseIterable, Identifiable {
    case rain, waves, wind, fire, brown, pink
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rain: "Rain"
        case .waves: "Waves"
        case .wind: "Wind"
        case .fire: "Fireplace"
        case .brown: "Deep focus"
        case .pink: "Soft noise"
        }
    }
    var symbol: String {
        switch self {
        case .rain: "cloud.rain.fill"
        case .waves: "water.waves"
        case .wind: "wind"
        case .fire: "flame.fill"
        case .brown: "brain.head.profile"
        case .pink: "waveform"
        }
    }
}

/// Render-thread state. Only plain floats are shared with the UI thread.
private final class Voice {
    var target: Float = 0
    var gain: Float = 0
    var rng: UInt64
    // filter / generator state
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var brown: Float = 0
    var lp: Float = 0
    var lp2: Float = 0
    var prevWhite: Float = 0
    var phase: Double = 0
    var phase2: Double = 0
    var burst: Float = 0
    var burstDecay: Float = 0.99
    var walk: Float = 0.5

    init(seed: UInt64) { rng = seed | 1 }

    @inline(__always) func white() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(Int64(bitPattern: rng) >> 11) / Float(1 << 52)
    }
    @inline(__always) func rand01() -> Float { white() * 0.5 + 0.5 }

    @inline(__always) func pink(_ w: Float) -> Float {
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return p * 0.11
    }

    @inline(__always) func brownStep(_ w: Float) -> Float {
        brown = (brown + 0.02 * w) / 1.02
        return brown * 3.5
    }

    func sample(_ kind: AmbientSound, sr: Double) -> Float {
        let w = white()
        switch kind {
        case .pink:
            return pink(w) * 0.9
        case .brown:
            return brownStep(w) * 0.9
        case .rain:
            // Hiss of steady rain plus randomly spawned droplets.
            let hiss = (w - prevWhite) * 0.18 + pink(w) * 0.35
            prevWhite = w
            if burst < 0.001, rand01() < 0.0009 { burst = 0.25 + rand01() * 0.5; burstDecay = 0.96 + rand01() * 0.03 }
            burst *= burstDecay
            lp += (white() * burst - lp) * 0.5
            return hiss + lp * 0.8
        case .waves:
            // Brown noise swelling on a slow, slightly irregular cycle.
            phase += 1 / (sr * (7.5 + Double(walk) * 3))
            if phase > 1 { phase -= 1; walk = rand01() }
            let swell = Float(0.5 - 0.5 * cos(2 * .pi * phase))
            let env = 0.15 + 0.85 * pow(swell, 1.6)
            lp += (pink(w) - lp) * (0.02 + env * 0.25)
            return (brownStep(w) * 0.55 + lp * 0.9) * env
        case .wind:
            phase += 1 / (sr * 11)
            phase2 += 1 / (sr * 4.3)
            if phase > 1 { phase -= 1 }
            if phase2 > 1 { phase2 -= 1 }
            let gust = Float(0.55 + 0.3 * sin(2 * .pi * phase) + 0.15 * sin(2 * .pi * phase2))
            let cutoff = 0.004 + gust * 0.03
            lp += (w - lp) * cutoff
            lp2 += (lp - lp2) * cutoff
            return lp2 * 9 * gust
        case .fire:
            let rumble = brownStep(w) * 0.45
            if burst < 0.002, rand01() < 0.00035 { burst = 0.4 + rand01() * 0.6; burstDecay = 0.90 + rand01() * 0.06 }
            burst *= burstDecay
            let crackle = (w - prevWhite) * burst
            prevWhite = w
            lp += (pink(w) - lp) * 0.08
            return rumble + crackle * 0.9 + lp * 0.25
        }
    }
}

@Observable
final class AmbientEngine {
    static let shared = AmbientEngine()

    var volumes: [AmbientSound: Double] = [:]
    var master: Double = 0.7 { didSet { masterGain = Float(master) } }
    var playing: Bool { volumes.values.contains { $0 > 0.001 } }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var voices: [AmbientSound: Voice] = [:]
    @ObservationIgnored private var masterGain: Float = 0.7
    @ObservationIgnored private var stopWork: DispatchWorkItem?

    init() {
        for (i, s) in AmbientSound.allCases.enumerated() { voices[s] = Voice(seed: UInt64(0x9E3779B97F4A7C15) &* UInt64(i + 1)) }
    }

    func setVolume(_ v: Double, for sound: AmbientSound) {
        volumes[sound] = v
        voices[sound]?.target = Float(v * v)   // perceptual curve
        if playing { startEngine() } else { scheduleStop() }
    }

    func toggle(_ sound: AmbientSound) {
        setVolume((volumes[sound] ?? 0) > 0.001 ? 0 : 0.6, for: sound)
    }

    func stopAll() { AmbientSound.allCases.forEach { setVolume(0, for: $0) } }

    private func startEngine() {
        stopWork?.cancel()
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let out = e.outputNode.inputFormat(forBus: 0)
        let sr = out.sampleRate > 0 ? out.sampleRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        let list = AmbientSound.allCases.map { ($0, voices[$0]!) }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            let m = self.masterGain
            for f in 0..<n {
                var mix: Float = 0
                for (kind, v) in list {
                    v.gain += (v.target - v.gain) * 0.0004            // smooth fades
                    if v.gain > 0.00005 { mix += v.sample(kind, sr: sr) * v.gain }
                }
                mix = tanhf(mix * m * 0.9)                           // soft clip
                for b in buffers {
                    b.mData?.assumingMemoryBound(to: Float.self)[f] = mix
                }
            }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        do { try e.start(); engine = e } catch { engine = nil }
    }

    private func scheduleStop() {
        stopWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.engine?.stop()
            self.engine = nil
        }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }
}
